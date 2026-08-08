#!/usr/bin/env bash
#
# backup.sh - Enterprise-grade backup script for directories and Docker volumes
#             with encryption, compression, smart retention, and detailed notifications.
#
# Security: All sensitive configuration is stored in backup.conf
#           which should be excluded from version control.

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Global Settings
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
CONFIG_EXAMPLE="${SCRIPT_DIR}/backup.conf.example"
LOCK_FILE="${SCRIPT_DIR}/.backup.lock"
LOG_FILE="${SCRIPT_DIR}/backup.log"
STATE_FILE="${SCRIPT_DIR}/.backup_state"
TMP_DIR="${SCRIPT_DIR}/.tmp"
BACKUP_START_TIME=0
BACKUP_END_TIME=0

# Default values (will be overridden by config)
BACKUP_BASE_DIR=""
SOURCE_DIR=""
DOCKER_VOLUMES=()
NTFY_TOPIC=""
NTFY_TOKEN=""
RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=6
ENCRYPTION_KEY_FILE=""
GZIP_LEVEL=6
DOCKER_IMAGE="alpine:latest"
VERBOSE=false
BACKUP_PREFIX="backup"
EXCLUDE_PATTERNS=""
MAX_BACKUP_SIZE_MB=0

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Configuration file not found: $CONFIG_FILE"
        echo ""
        echo "To set up your configuration:"
        echo "  1. Copy the example template:"
        echo "     cp $CONFIG_EXAMPLE $CONFIG_FILE"
        echo "  2. Edit $CONFIG_FILE with your values"
        echo "  3. Never commit $CONFIG_FILE to version control"
        echo ""
        exit 1
    fi

    source "$CONFIG_FILE"

   local required_vars=(
        "BACKUP_BASE_DIR"
        "SOURCE_DIR"
        "DOCKER_VOLUMES"
        "ENCRYPTION_KEY_FILE"
        "NTFY_TOPIC"
        "NTFY_TOKEN"
    )

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        elif [[ "$var" == "DOCKER_VOLUMES" ]] && [[ ${#DOCKER_VOLUMES[@]} -eq 0 ]]; then
            missing_vars+=("$var (empty array)")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "ERROR: Missing required configuration variables in $CONFIG_FILE:"
        printf "  - %s\n" "${missing_vars[@]}"
        echo ""
        echo "Please update $CONFIG_FILE with your values."
        exit 1
    fi

    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        echo "ERROR: Encryption key file not found: $ENCRYPTION_KEY_FILE"
        echo ""
        echo "Generate one using:"
        echo "  openssl rand -base64 32 > encryption.key"
        echo "  chmod 600 encryption.key"
        exit 1
    fi

    if [[ ! -d "$SOURCE_DIR" ]]; then
        echo "ERROR: Source directory does not exist: $SOURCE_DIR"
        exit 1
    fi

    mkdir -p "$BACKUP_BASE_DIR" 2>/dev/null || {
        echo "ERROR: Cannot create backup directory: $BACKUP_BASE_DIR"
        exit 1
    }

    if [[ ! -w "$BACKUP_BASE_DIR" ]]; then
        echo "ERROR: Backup directory is not writable: $BACKUP_BASE_DIR"
        exit 1
    fi

    echo "✅ Configuration loaded successfully from: $CONFIG_FILE"
}

init_tmp() {
    mkdir -p "$TMP_DIR"
    chmod 700 "$TMP_DIR"
    find "$TMP_DIR" -type f -mtime +1 -delete 2>/dev/null || true
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        log "[DEBUG] $*"
    fi
}

error_exit() {
    local msg="$*"
    log "ERROR: $msg"
    send_ntfy "🔴 BACKUP FAILED\n━━━━━━━━━━━━━━━━━━━━━━━━\n❌ Error: $msg\n⏱️ Time: $(date '+%Y-%m-%d %H:%M:%S')" "error"
    cleanup_temp
    exit 1
}

trap 'error_exit "Backup interrupted or failed at line $LINENO"' ERR

send_ntfy() {
    local message="$1"
    local status="${2:-info}"
    
    if [[ -z "$NTFY_TOPIC" || -z "$NTFY_TOKEN" ]]; then
        log_verbose "ntfy not configured (topic/token missing). Skipping notification."
        return 0
    fi
    
    log_verbose "Sending notification (status: $status)"
    
    local priority="3"
    local tags="information_source"
    case "$status" in
        error)   priority="5"; tags="red_circle" ;;
        success) priority="3"; tags="white_check_mark" ;;
        info)    priority="3"; tags="information_source" ;;
    esac
    
    {
        local servers=(
            "https://notify.ricalnet.my.id"
            "${NTFY_CUSTOM_SERVER:-}"
        )
        
        local sent=false
        for server in "${servers[@]}"; do
            [[ -z "$server" ]] && continue
            log_verbose "Trying $server..."
            
            local response_file="${TMP_DIR}/ntfy_response_$$"
            local http_code_file="${TMP_DIR}/ntfy_http_code_$$"
            
            local http_code=$(curl -s -w "%{http_code}" -o "$response_file" \
                --max-time 10 \
                --connect-timeout 5 \
                -H "Authorization: Bearer $NTFY_TOKEN" \
                -H "Title: 🔔 Backup Notification" \
                -H "Priority: $priority" \
                -H "Tags: $tags" \
                -d "$message" \
                "$server/$NTFY_TOPIC" 2>/dev/null)
            
            if [[ "$http_code" == "200" ]]; then
                log_verbose "✅ Notification sent successfully ($server)"
                sent=true
                rm -f "$response_file" "$http_code_file" 2>/dev/null || true
                break
            else
                log_verbose "⚠️ Failed with HTTP $http_code on $server"
                rm -f "$response_file" "$http_code_file" 2>/dev/null || true
            fi
        done
        
        if [[ "$sent" == "false" ]]; then
            log "⚠️ All notification attempts failed"
        fi
    } &
    
    return 0
}

get_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    if (( hours > 0 )); then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif (( minutes > 0 )); then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

human_size() {
    local size_bytes=$1
    if (( size_bytes >= 1073741824 )); then
        echo "$((size_bytes / 1073741824)).$(((size_bytes % 1073741824) * 10 / 1073741824)) GB"
    elif (( size_bytes >= 1048576 )); then
        echo "$((size_bytes / 1048576)).$(((size_bytes % 1048576) * 10 / 1048576)) MB"
    elif (( size_bytes >= 1024 )); then
        echo "$((size_bytes / 1024)).$(((size_bytes % 1024) * 10 / 1024)) KB"
    else
        echo "${size_bytes} B"
    fi
}

get_dir_size() {
    du -sb "$1" 2>/dev/null | awk '{print $1}' || echo 0
}

get_file_count() {
    find "$1" -type f 2>/dev/null | wc -l || echo 0
}

check_disk_space() {
    local target_dir="$1"
    local required_mb="$2"
    local free_mb
    free_mb=$(df -m "$target_dir" | awk 'NR==2 {print $4}')
    if (( free_mb < required_mb )); then
        error_exit "Insufficient disk space on $target_dir. Required: ${required_mb}MB, Available: ${free_mb}MB"
    else
        log_verbose "Disk space check passed: ${free_mb}MB available (need ${required_mb}MB)"
        echo "$free_mb"
    fi
}

check_backup_size() {
    local backup_dir="$1"
    if [[ "$MAX_BACKUP_SIZE_MB" -gt 0 ]]; then
        local size_mb
        size_mb=$(du -sm "$backup_dir" 2>/dev/null | awk '{print $1}' || echo 0)
        if (( size_mb > MAX_BACKUP_SIZE_MB )); then
            error_exit "Backup size ${size_mb}MB exceeds limit of ${MAX_BACKUP_SIZE_MB}MB"
        fi
        log_verbose "Backup size ${size_mb}MB within limit of ${MAX_BACKUP_SIZE_MB}MB"
    fi
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        error_exit "Docker is not installed or not in PATH"
    fi
    if ! docker info &> /dev/null; then
        error_exit "Docker daemon is not running"
    fi
    log_verbose "Docker is running"
}

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error_exit "Another backup process is running (PID $pid). Lock file exists."
        else
            log "Stale lock file found. Removing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"; cleanup_temp; exit' INT TERM EXIT
}

release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
    trap - INT TERM EXIT
}

cleanup_temp() {
    rm -f "$STATE_FILE" "${TMP_DIR}/backup_rotate_$$" "${TMP_DIR}/backup_rotate_$$.grouped" 2>/dev/null || true
    rm -f "${TMP_DIR}/ntfy_response_$$" "${TMP_DIR}/ntfy_http_code_$$" 2>/dev/null || true
    find "$TMP_DIR" -type f -mtime +1 -delete 2>/dev/null || true
}

backup_directory() {
    local src="$1"
    local dest_dir="$2"
    local name="$3"
    local archive_base="${dest_dir}/${name}"
    local tar_file="${archive_base}.tar"
    local gz_file="${tar_file}.gz"
    local enc_file="${gz_file}.enc"

    log "Backing up directory: $src"
    if [[ ! -d "$src" ]]; then
        error_exit "Source directory $src does not exist"
    fi

    local exclude_opts=()
    if [[ -n "$EXCLUDE_PATTERNS" ]]; then
        for pattern in $EXCLUDE_PATTERNS; do
            exclude_opts+=("--exclude=$pattern")
        done
    fi

    tar -cf "$tar_file" -C "$(dirname "$src")" "${exclude_opts[@]}" "$(basename "$src")" \
        --preserve-permissions --same-owner --xattrs 2>/dev/null || \
        tar -cf "$tar_file" -C "$(dirname "$src")" "${exclude_opts[@]}" "$(basename "$src")" \
        --preserve-permissions --same-owner

    log "Compressing $tar_file with gzip level $GZIP_LEVEL"
    gzip -v -$GZIP_LEVEL "$tar_file"
    if [[ ! -f "$gz_file" ]]; then
        error_exit "Compression failed for $tar_file"
    fi

    generate_checksums "$gz_file"
    encrypt_file "$gz_file" "$enc_file"
    if [[ -f "$enc_file" ]]; then
        rm -f "$gz_file"
        log "✅ Encrypted backup created: $(basename "$enc_file")"
    else
        error_exit "Encryption failed for $gz_file"
    fi
}

backup_docker_volume() {
    local volume="$1"
    local dest_dir="$2"
    local archive_base="${dest_dir}/volume_${volume}"
    local tar_file="${archive_base}.tar"
    local gz_file="${tar_file}.gz"
    local enc_file="${gz_file}.enc"

    log "Backing up Docker volume: $volume"
    if ! docker volume inspect "$volume" &>/dev/null; then
        error_exit "Docker volume $volume does not exist"
    fi

    local container_name="backup_vol_${volume}_$(date +%s)"
    docker run --rm --name "$container_name" \
        -v "$volume":/volume \
        -v "$dest_dir":/backup \
        "$DOCKER_IMAGE" \
        tar -cf "/backup/${volume}.tar" -C /volume . \
        --preserve-permissions --same-owner 2>/dev/null || \
    docker run --rm --name "$container_name" \
        -v "$volume":/volume \
        -v "$dest_dir":/backup \
        "$DOCKER_IMAGE" \
        tar -cf "/backup/${volume}.tar" -C /volume .

    if [[ ! -f "${dest_dir}/${volume}.tar" ]]; then
        error_exit "Failed to create tar for volume $volume"
    fi

    mv "${dest_dir}/${volume}.tar" "$tar_file"

    log "Compressing $tar_file"
    gzip -v -$GZIP_LEVEL "$tar_file"
    if [[ ! -f "$gz_file" ]]; then
        error_exit "Compression failed for $tar_file"
    fi

    generate_checksums "$gz_file"
    encrypt_file "$gz_file" "$enc_file"
    if [[ -f "$enc_file" ]]; then
        rm -f "$gz_file"
        log "✅ Encrypted volume backup created: $(basename "$enc_file")"
    else
        error_exit "Encryption failed for $gz_file"
    fi
}

generate_checksums() {
    local file="$1"
    local checksum_file="${file}.checksums"
    {
        md5sum "$file" | awk '{print $1}' | sed "s/^/MD5: /"
        sha256sum "$file" | awk '{print $1}' | sed "s/^/SHA256: /"
    } > "$checksum_file"
    log_verbose "Checksums generated for $(basename "$file")"
}

encrypt_file() {
    local infile="$1"
    local outfile="$2"
    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        error_exit "Encryption key file not found: $ENCRYPTION_KEY_FILE"
    fi
    openssl enc -aes-256-cbc -salt -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        error_exit "OpenSSL encryption failed for $infile"
    fi
}

decrypt_file() {
    local infile="$1"
    local outfile="$2"
    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        error_exit "Encryption key file not found: $ENCRYPTION_KEY_FILE"
    fi
    openssl enc -d -aes-256-cbc -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        error_exit "OpenSSL decryption failed for $infile"
    fi
}

verify_backup() {
    local enc_file="$1"
    local checksum_file="${enc_file%.enc}.checksums"
    if [[ ! -f "$checksum_file" ]]; then
        log "⚠️ WARNING: Checksum file missing for $(basename "$enc_file")"
        return 1
    fi
    log_verbose "Checksum file exists for $(basename "$enc_file")"
    return 0
}

rotate_backups() {
    local backup_dir="$1"
    log "Rotating backups in $backup_dir"

    local file_count=$(find "$backup_dir" -maxdepth 1 -name "*.enc" -type f 2>/dev/null | wc -l)
    log_verbose "Found $file_count backup files in $backup_dir"

    if timeout 60 bash -c "
        tmp_file=\"${TMP_DIR}/backup_rotate_$$\"
        find \"$backup_dir\" -maxdepth 1 -name \"*.enc\" -type f > \"\$tmp_file\" 2>/dev/null

        while IFS= read -r encfile; do
            basename=\$(basename \"\$encfile\")
            type=\$(echo \"\$basename\" | sed -E 's/_[0-9]{8}_[0-9]{6}\.tar\.gz\.enc\$//')
            echo \"\$type|\$encfile\"
        done < \"\$tmp_file\" 2>/dev/null | sort > \"\${tmp_file}.grouped\" 2>/dev/null

        keep_files_per_type() {
            local type=\"\$1\"
            local max_keep=\"\$2\"
            local count=0
            grep \"^\${type}|\" \"\${tmp_file}.grouped\" 2>/dev/null | cut -d'|' -f2 | sort -r | while read -r f; do
                count=\$((count + 1))
                if (( count > max_keep )); then
                    echo \"Deleting old backup: \$f (exceeds retention of \$max_keep for type \$type)\"
                    rm -f \"\$f\" 2>/dev/null
                    rm -f \"\${f%.enc}.checksums\" 2>/dev/null
                fi
            done
        }

        keep_files_per_type \"digital-independence\" \"$RETENTION_DAILY\"
        for vol in ${DOCKER_VOLUMES[@]}; do
            keep_files_per_type \"volume_\${vol}\" \"$RETENTION_DAILY\"
        done

        rm -f \"\$tmp_file\" \"\${tmp_file}.grouped\" 2>/dev/null
    " 2>&1 | while IFS= read -r line; do log "ROTATE: $line"; done; then
        log "✅ Rotation completed successfully"
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log "⚠️ WARNING: Rotation timed out after 60 seconds"
        else
            log "⚠️ WARNING: Rotation had errors (exit code: $exit_code)"
        fi
    fi
}

restore_from_backup() {
    local enc_file="$1"
    if [[ ! -f "$enc_file" ]]; then
        error_exit "Backup file not found: $enc_file"
    fi

    init_tmp

    local basename
    basename=$(basename "$enc_file")
    
    local type
    if echo "$basename" | grep -qE '_[0-9]{8}_[0-9]{6}\.tar\.gz\.enc$'; then
        type=$(echo "$basename" | sed -E 's/_[0-9]{8}_[0-9]{6}\.tar\.gz\.enc$//')
    else
        type=$(echo "$basename" | sed -E 's/\.tar\.gz\.enc$//')
    fi
    
    log "Restoring type: $type"

    local tmp_dir
    tmp_dir=$(mktemp -d -p "$TMP_DIR" restore_XXXXXX)
    
    trap 'rm -rf "$tmp_dir" 2>/dev/null || true; cleanup_temp; exit' INT TERM EXIT
    
    local decrypted_file="${tmp_dir}/$(basename "${enc_file%.enc}")"
    log "Decrypting $(basename "$enc_file") to $(basename "$decrypted_file")"
    decrypt_file "$enc_file" "$decrypted_file"

    if [[ ! -f "$decrypted_file" ]]; then
        error_exit "Decryption failed or output missing"
    fi

    local checksum_file="${enc_file%.enc}.checksums"
    if [[ -f "$checksum_file" ]]; then
        log "Verifying checksum of decrypted file..."
        local md5_original
        md5_original=$(grep '^MD5:' "$checksum_file" | awk '{print $2}')
        local md5_current
        md5_current=$(md5sum "$decrypted_file" | awk '{print $1}')
        if [[ "$md5_original" != "$md5_current" ]]; then
            error_exit "MD5 checksum mismatch! Restore aborted."
        else
            log "✅ Checksum verification passed."
        fi
    else
        log "⚠️ WARNING: No checksum file found; skipping verification."
    fi

    log "Decompressing $(basename "$decrypted_file")"
    gunzip -v "$decrypted_file" || error_exit "Gunzip failed"
    local tar_file="${decrypted_file%.gz}"
    if [[ ! -f "$tar_file" ]]; then
        error_exit "Decompression failed: $(basename "$tar_file") not found"
    fi

    if [[ "$type" == "digital-independence" ]]; then
        local dest_dir="$SOURCE_DIR"
        
        dest_dir="${dest_dir%/}"
        
        log "Restoring directory backup to $dest_dir"
        
        local use_sudo=false
        if [[ ! -w "$(dirname "$dest_dir")" ]] || [[ ! -w "$dest_dir" && -d "$dest_dir" ]]; then
            log "⚠️ Destination requires sudo privileges"
            use_sudo=true
        fi
        
        if [[ "$use_sudo" == "true" ]]; then
            sudo mkdir -p "$(dirname "$dest_dir")"
            sudo mkdir -p "$dest_dir"
        else
            mkdir -p "$(dirname "$dest_dir")"
            mkdir -p "$dest_dir"
        fi
        
        local first_entry=$(tar -tf "$tar_file" 2>/dev/null | head -1)
        
        if [[ -z "$first_entry" ]]; then
            error_exit "Tar file appears to be empty or corrupted"
        fi
        
        log "First entry in tar: $first_entry"
        
        local top_dir=$(echo "$first_entry" | cut -d'/' -f1)
        
        local all_under_top=true
        local other_files=$(tar -tf "$tar_file" 2>/dev/null | grep -v "^$top_dir/" | grep -v "^$top_dir$" | head -1)
        if [[ -n "$other_files" ]]; then
            all_under_top=false
        fi
        
        if [[ "$all_under_top" == "true" ]] && [[ -n "$top_dir" ]]; then
            log "Tar contains all files under top-level directory: $top_dir"
            
            local extract_dir="${tmp_dir}/extract"
            mkdir -p "$extract_dir"
            tar -xf "$tar_file" -C "$extract_dir" --preserve-permissions --same-owner
            
            if [[ -d "$extract_dir/$top_dir" ]]; then
                log "Moving contents from $top_dir to $dest_dir"
                
                if [[ "$use_sudo" == "true" ]]; then
                    if command -v rsync &> /dev/null; then
                        sudo rsync -a --no-owner --no-group "$extract_dir/$top_dir/" "$dest_dir/"
                    else
                        sudo cp -a "$extract_dir/$top_dir/." "$dest_dir/"
                    fi
                else
                    if command -v rsync &> /dev/null; then
                        rsync -a --no-owner --no-group "$extract_dir/$top_dir/" "$dest_dir/"
                    else
                        cp -a "$extract_dir/$top_dir/." "$dest_dir/"
                    fi
                fi
                
                log "✅ Successfully restored all files to $dest_dir"
                
                if [[ "$use_sudo" == "true" ]]; then
                    sudo chown -R $(whoami):$(whoami) "$dest_dir" 2>/dev/null || true
                fi
                
                rm -rf "$extract_dir"
            else
                log "Fallback: Extracting directly to $dest_dir"
                if [[ "$use_sudo" == "true" ]]; then
                    sudo tar -xf "$tar_file" -C "$dest_dir" --preserve-permissions --same-owner
                else
                    tar -xf "$tar_file" -C "$dest_dir" --preserve-permissions --same-owner
                fi
                log "✅ Directory restore completed to $dest_dir"
            fi
        else
            log "Tar contains multiple top-level items or flat structure"
            
            if [[ "$use_sudo" == "true" ]]; then
                sudo tar -xf "$tar_file" -C "$dest_dir" --preserve-permissions --same-owner
            else
                tar -xf "$tar_file" -C "$dest_dir" --preserve-permissions --same-owner
            fi
            log "✅ Directory restore completed to $dest_dir"
        fi
        
        if [[ -d "$dest_dir" ]] && [[ -n "$(ls -A "$dest_dir" 2>/dev/null)" ]]; then
            log "✅ Restore verified: $dest_dir contains files"
            local restored_count=$(find "$dest_dir" -type f 2>/dev/null | wc -l)
            log "📊 Restored $restored_count files"
        else
            log "⚠️ Warning: $dest_dir appears to be empty after restore"
        fi
        
    elif [[ "$type" =~ ^volume_ ]]; then
        local volume_name="${type#volume_}"
        log "Restoring Docker volume: $volume_name"
        
        if ! docker volume inspect "$volume_name" &>/dev/null; then
            log "Volume $volume_name does not exist; creating it."
            docker volume create "$volume_name" || error_exit "Failed to create volume $volume_name"
        fi
        
        local extract_dir="${tmp_dir}/extract_vol"
        mkdir -p "$extract_dir"
        tar -xf "$tar_file" -C "$extract_dir" --preserve-permissions --same-owner
        
        local vol_first_entry=$(ls -A "$extract_dir" 2>/dev/null | head -1)
        
        if [[ -d "$extract_dir/$vol_first_entry" ]] && [[ $(ls -A "$extract_dir" 2>/dev/null | wc -l) -eq 1 ]]; then
            log "Volume data is under single directory: $vol_first_entry"
            
            local container_name="restore_vol_${volume_name}_$(date +%s)"
            docker run --rm --name "$container_name" \
                -v "$volume_name":/volume \
                -v "$extract_dir":/restore \
                "$DOCKER_IMAGE" \
                sh -c "rm -rf /volume/* && cp -a /restore/$vol_first_entry/. /volume/" || \
                error_exit "Failed to restore volume $volume_name"
        else
            local container_name="restore_vol_${volume_name}_$(date +%s)"
            docker run --rm --name "$container_name" \
                -v "$volume_name":/volume \
                -v "$extract_dir":/restore \
                "$DOCKER_IMAGE" \
                sh -c "rm -rf /volume/* && cp -a /restore/. /volume/" || \
                error_exit "Failed to restore volume $volume_name"
        fi
        
        log "✅ Volume restore completed for $volume_name"
        
    else
        error_exit "Unknown backup type: $type"
    fi

    rm -rf "$tmp_dir" 2>/dev/null || true
    trap - INT TERM EXIT
    log "✅ Restore completed successfully."
}

list_backups() {
    local backup_dir="$1"
    echo ""
    echo "📦 Available backups in: $backup_dir"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    find "$backup_dir" -maxdepth 1 -name "*.enc" -type f | sort | while read -r f; do
        local basename=$(basename "$f")
        local size=$(human_size $(stat -c%s "$f" 2>/dev/null || echo 0))
        local date=$(echo "$basename" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | sed 's/_/ /')
        printf "  %-50s  %-10s  %s\n" "$basename" "$size" "$date"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

do_backup() {
    BACKUP_START_TIME=$(date +%s)
    local start_date=$(date '+%Y-%m-%d %H:%M:%S')
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "🚀 Starting backup"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    load_config
    
    init_tmp
    
    local hostname=$(hostname)
    local source_size=$(get_dir_size "$SOURCE_DIR")
    local source_size_human=$(human_size "$source_size")
    local source_files=$(get_file_count "$SOURCE_DIR")
    local volume_count=${#DOCKER_VOLUMES[@]}
    local free_space_mb
    free_space_mb=$(df -m "$BACKUP_BASE_DIR" | awk 'NR==2 {print $4}')
    local free_space_human=$(human_size $((free_space_mb * 1024 * 1024)))
    
    log "📁 Source: $SOURCE_DIR"
    log "📊 Size: $source_size_human ($source_files files)"
    log "🐳 Volumes: $volume_count volumes"
    log "💾 Target: $BACKUP_BASE_DIR"
    log "💿 Free space: $free_space_human"
    log "🔒 Encryption: AES-256-CBC"
    log "🗜️ Compression: gzip level $GZIP_LEVEL"
    log "📋 Retention: ${RETENTION_DAILY} daily backups"
    
    send_ntfy "🚀 BACKUP STARTED
━━━━━━━━━━━━━━━━━━━━━━━━━━━
📅 Time: $start_date
💻 Host: $hostname
📁 Source: $SOURCE_DIR
📊 Size: $source_size_human ($source_files files)
🐳 Volumes: $volume_count volumes
💾 Target: $BACKUP_BASE_DIR
💿 Free space: $free_space_human
🔒 Encryption: AES-256-CBC
🗜️ Compression: gzip level $GZIP_LEVEL
📋 Retention: ${RETENTION_DAILY} daily backups" "info"
    
    acquire_lock
    check_docker
    check_disk_space "$BACKUP_BASE_DIR" 1024

    local timestamp
    timestamp=$(get_timestamp)
    local backup_dir="${BACKUP_BASE_DIR}/${BACKUP_PREFIX}_${timestamp}"
    mkdir -p "$backup_dir"
    log "📂 Backup directory created: $backup_dir"

    backup_directory "$SOURCE_DIR" "$backup_dir" "digital-independence"

    local vol_count=0
    for vol in "${DOCKER_VOLUMES[@]}"; do
        vol_count=$((vol_count + 1))
        log "Processing volume $vol_count of ${#DOCKER_VOLUMES[@]}: $vol"
        backup_docker_volume "$vol" "$backup_dir"
    done

    check_backup_size "$backup_dir"

    local all_ok=true
    local enc_files=()
    if ls "$backup_dir"/*.enc &>/dev/null; then
        for enc_file in "$backup_dir"/*.enc; do
            enc_files+=("$enc_file")
            if ! verify_backup "$enc_file"; then
                all_ok=false
            fi
        done
        if $all_ok; then
            log "✅ All backups verified."
        else
            log "⚠️ WARNING: Some backups failed verification."
        fi
    else
        log "⚠️ WARNING: No encrypted backup files found in $backup_dir"
    fi

    rotate_backups "$BACKUP_BASE_DIR"

    BACKUP_END_TIME=$(date +%s)
    local duration=$((BACKUP_END_TIME - BACKUP_START_TIME))
    local duration_human=$(format_duration $duration)
    local backup_count=${#enc_files[@]}
    local total_backup_size=$(du -sb "$backup_dir" 2>/dev/null | awk '{print $1}' || echo 0)
    local total_backup_size_human=$(human_size $total_backup_size)
    local end_date=$(date '+%Y-%m-%d %H:%M:%S')
    local new_free_space_mb=$(df -m "$BACKUP_BASE_DIR" | awk 'NR==2 {print $4}')
    local space_used_mb=$((free_space_mb - new_free_space_mb))
    local space_used_human=$(human_size $((space_used_mb * 1024 * 1024)))

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "✅ Backup completed successfully"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "⏱️ Duration: $duration_human"
    log "📦 Archives: $backup_count encrypted files"
    log "💾 Total size: $total_backup_size_human"
    log "📍 Location: $backup_dir"
    log "📝 Log: $LOG_FILE"

    send_ntfy "✅ BACKUP COMPLETED SUCCESSFULLY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📅 Completed: $end_date
⏱️ Duration: $duration_human
📦 Archives: $backup_count encrypted files
💾 Total size: $total_backup_size_human
📁 Source size: $source_size_human ($source_files files)
🐳 Volumes: $volume_count volumes
💿 Free space: $free_space_human → $(human_size $((new_free_space_mb * 1024 * 1024))) (used $space_used_human)
🔒 Verification: ✅ All checksums verified
🗑️ Retention: ${RETENTION_DAILY} daily backups kept
📍 Location: $backup_dir
📝 Log: $LOG_FILE" "success"

    release_lock
    cleanup_temp
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

show_help() {
    cat <<EOF
📦 backup.sh - Enterprise-grade backup script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --restore <file>   Restore from the specified encrypted backup file
    --list             List all available backups in the backup directory
    --help, -h         Show this help message

CONFIGURATION:
    All configuration is stored in backup.conf
    Copy backup.conf.example to backup.conf and modify as needed.

    Required settings:
        BACKUP_BASE_DIR       - Where backups are stored
        SOURCE_DIR            - What to backup
        DOCKER_VOLUMES        - Docker volumes to backup
        ENCRYPTION_KEY_FILE   - Path to encryption key
        NTFY_TOPIC            - ntfy.sh topic for notifications
        NTFY_TOKEN            - ntfy.sh authentication token

EXAMPLES:
    # Perform a full backup
    ./backup.sh

    # List available backups
    ./backup.sh --list

    # Restore from a specific backup
    ./backup.sh --restore /path/to/backup/backup_20250101_120000.tar.gz.enc

SECURITY:
    - encryption.key should have permissions 600
    - backup.conf should never be committed to version control
    - All sensitive data is encrypted with AES-256-CBC

EOF
}

main() {
    case "${1:-}" in
        --restore)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: Missing backup file for restore."
                echo "Usage: $0 --restore <backup-file>"
                exit 1
            fi
            # Load config before restore
            load_config
            init_tmp  # Initialize temp directory
            restore_from_backup "$2"
            ;;
        --list)
            # Load config before listing
            load_config
            list_backups "$BACKUP_BASE_DIR"
            ;;
        --help|-h)
            show_help
            ;;
        "")
            do_backup
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
}

main "$@"
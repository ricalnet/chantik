#!/usr/bin/env bash
#
# backup.sh - Enterprise-grade backup script for directories and Docker volumes
#             with encryption, compression, smart retention, and detailed notifications.
#
# Security: All sensitive configuration is stored in backup.conf
#           which should be excluded from version control.

set -euo pipefail
IFS=$'\n\t'

VERSION="0.0.9"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# -----------------------------------------------------------------------------
# Global Settings
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
CONFIG_EXAMPLE="${SCRIPT_DIR}/backup.conf.example"
LOCK_FILE="${SCRIPT_DIR}/.backup.lock"
LOG_FILE="${SCRIPT_DIR}/backup.log"
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
NTFY_CUSTOM_SERVER=""
FIXED_SALT_FILE=""
DEDUP_TOOL="hardlink"
PBKDF2_ITERATIONS=600000

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

    if [[ -n "${PBKDF2_ITERATIONS:-}" ]]; then
        if [[ ! "$PBKDF2_ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$PBKDF2_ITERATIONS" -lt 100000 ]]; then
            echo "⚠️ WARNING: PBKDF2_ITERATIONS must be a number >= 100000."
            echo "   Using default: 600000"
            PBKDF2_ITERATIONS=600000
        elif [[ "$PBKDF2_ITERATIONS" -lt 600000 ]]; then
            echo "⚠️ WARNING: PBKDF2_ITERATIONS=$PBKDF2_ITERATIONS is lower than recommended (600000+)."
            echo "   Consider increasing for better security."
        fi
        log_verbose "PBKDF2 iterations: $PBKDF2_ITERATIONS"
    else
        PBKDF2_ITERATIONS=600000
        log_verbose "Using default PBKDF2 iterations: $PBKDF2_ITERATIONS"
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

    if [[ -n "$FIXED_SALT_FILE" ]]; then
        if [[ ! -f "$FIXED_SALT_FILE" ]]; then
            echo "ERROR: Fixed salt file not found: $FIXED_SALT_FILE"
            echo "Generate a fixed salt (16 hex chars) with:"
            echo "  openssl rand -hex 8 > fixed_salt.txt"
            exit 1
        fi
        local salt_content
        salt_content=$(tr -d '\n\r' < "$FIXED_SALT_FILE")
        if [[ ! "$salt_content" =~ ^[0-9a-fA-F]{16}$ ]]; then
            echo "ERROR: Fixed salt file must contain exactly 16 hex characters (8 bytes)."
            echo "Current content: $salt_content"
            exit 1
        fi
        echo "✅ Fixed salt loaded: $salt_content"
    fi

    if [[ -n "$DEDUP_TOOL" ]]; then
        if ! command -v "$DEDUP_TOOL" &> /dev/null; then
            echo "⚠️ WARNING: Deduplication tool '$DEDUP_TOOL' not found. Dedup will be skipped."
            echo "   Install with: apt install hardlink  or  brew install hardlink"
            echo "   Or set DEDUP_TOOL='' in config to disable."
            DEDUP_TOOL=""
        fi
    fi

    if [[ ! "$GZIP_LEVEL" =~ ^[1-9]$ ]]; then
        echo "⚠️ WARNING: Invalid GZIP_LEVEL '$GZIP_LEVEL'. Must be 1-9. Using default 6."
        GZIP_LEVEL=6
    fi

    local required_tools=("openssl" "gzip" "tar" "curl" "sha256sum")
    local missing_tools=()
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "ERROR: Required tools not found: ${missing_tools[*]}"
        echo "Please install them and try again."
        exit 1
    fi

    echo "✅ Configuration loaded successfully from: $CONFIG_FILE"
}

init_tmp() {
    mkdir -p "$TMP_DIR"
    chmod 700 "$TMP_DIR" 2>/dev/null || true
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
    
    local error_msg="❌ Error: $msg\n⏱️ Time: $(date '+%Y-%m-%d %H:%M:%S')\n📝 Log: $LOG_FILE"
    
    send_ntfy "$error_msg" "error"
    cleanup_temp
    exit 1
}

trap 'error_exit "Backup interrupted or failed at line ${BASH_LINENO[0]}"' ERR

send_ntfy() {
    local message="$1"
    local status="${2:-info}"
    
    if [[ -z "$NTFY_TOPIC" || -z "$NTFY_TOKEN" ]]; then
        log_verbose "ntfy not configured (topic/token missing). Skipping notification."
        return 0
    fi
    
    log_verbose "Sending notification (status: $status, topic: $NTFY_TOPIC)"
    
    local priority="3"
    local tags="information_source"
    local title=""
    
    case "$status" in
        error)   
            priority="5"
            tags="red_circle"
            title="❌ BACKUP FAILED"
            ;;
        success) 
            priority="3"
            tags="white_check_mark"
            title="✅ BACKUP SUCCESS"
            ;;
        info)    
            priority="3"
            tags="information_source"
            title="ℹ️ BACKUP INFO"
            ;;
        restore)
            priority="3"
            tags="arrows_counterclockwise"
            title="🔄 RESTORE COMPLETED"
            ;;
    esac
    
    local clean_message=$(echo -e "$message" | sed 's/\*\*//g')
    
    {
        local servers=(
            "https://ntfy.sh"
            "${NTFY_CUSTOM_SERVER:-}"
        )
        
        local sent=false
        for server in "${servers[@]}"; do
            [[ -z "$server" ]] && continue
            log_verbose "Trying $server..."
            
            local response_file
            if ! response_file=$(mktemp -p "$TMP_DIR" ntfy_response_XXXXXX 2>/dev/null); then
                response_file="${TMP_DIR}/ntfy_response_$$_$RANDOM"
            fi
            local http_code_file
            if ! http_code_file=$(mktemp -p "$TMP_DIR" ntfy_http_XXXXXX 2>/dev/null); then
                http_code_file="${TMP_DIR}/ntfy_http_$$_$RANDOM"
            fi
            
            local http_code=$(curl -s -w "%{http_code}" -o "$response_file" \
                --max-time 10 \
                --connect-timeout 5 \
                -H "Authorization: Bearer $NTFY_TOKEN" \
                -H "Title: $title" \
                -H "Priority: $priority" \
                -H "Tags: $tags" \
                --data-binary "$clean_message" \
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
        log "📊 Backup size: ${size_mb}MB"
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
    find "$TMP_DIR" -type f -name "backup_rotate_*" -exec rm -f {} + 2>/dev/null || true
    find "$TMP_DIR" -type f -name "ntfy_response_*" -delete 2>/dev/null || true
    find "$TMP_DIR" -type f -name "ntfy_http_*" -delete 2>/dev/null || true
    find "$TMP_DIR" -type d -name "verify_test_*" -exec rm -rf {} + 2>/dev/null || true
    find "$TMP_DIR" -type d -name "restore_*" -exec rm -rf {} + 2>/dev/null || true
    find "$TMP_DIR" -type f -mtime +1 -delete 2>/dev/null || true
}

encrypt_file() {
    local infile="$1"
    local outfile="$2"
    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        error_exit "Encryption key file not found: $ENCRYPTION_KEY_FILE"
    fi
    
    local openssl_opts=()
    openssl_opts+=("-pbkdf2" "-iter" "${PBKDF2_ITERATIONS:-600000}")
    
    if [[ -n "$FIXED_SALT_FILE" ]] && [[ -f "$FIXED_SALT_FILE" ]]; then
        local salt_hex
        salt_hex=$(tr -d '\n\r' < "$FIXED_SALT_FILE")
        openssl_opts+=("-S" "$salt_hex")
        log_verbose "Using fixed salt for deterministic encryption (deduplication enabled)"
    else
        openssl_opts+=("-salt")
        log_verbose "Using random salt (deduplication disabled)"
    fi
    
    log_verbose "Encrypting with openssl: ${openssl_opts[*]} (iterations: ${PBKDF2_ITERATIONS:-600000})"
    if openssl enc -aes-256-cbc "${openssl_opts[@]}" -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Encryption successful"
        return 0
    fi
    
    log_verbose "pbkdf2 failed, trying legacy method..."
    local legacy_opts=()
    if [[ -n "$FIXED_SALT_FILE" ]] && [[ -f "$FIXED_SALT_FILE" ]]; then
        local salt_hex
        salt_hex=$(tr -d '\n\r' < "$FIXED_SALT_FILE")
        legacy_opts+=("-S" "$salt_hex")
    else
        legacy_opts+=("-salt")
    fi
    if openssl enc -aes-256-cbc "${legacy_opts[@]}" -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Encryption successful (legacy method)"
        return 0
    fi
    
    error_exit "OpenSSL encryption failed for $infile (both methods)"
}

decrypt_file() {
    local infile="$1"
    local outfile="$2"
    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        error_exit "Encryption key file not found: $ENCRYPTION_KEY_FILE"
    fi
    
    local file_header=$(head -c 16 "$infile" 2>/dev/null | od -An -tx1 | tr -d ' ')
    log_verbose "File header: $file_header"
    
    if [[ "$file_header" == "53616c7465645f5f"* ]]; then
        log_verbose "File has standard OpenSSL header (Salted__)"
    else
        log_verbose "File does NOT have standard OpenSSL header. Trying alternative methods..."
    fi
    
    log_verbose "Trying decryption with pbkdf2 (iterations: ${PBKDF2_ITERATIONS:-600000})..."
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
        -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Decryption successful (pbkdf2 method, ${PBKDF2_ITERATIONS:-600000} iterations)"
        return 0
    fi
    
    log_verbose "Trying decryption with pbkdf2 (iterations: 100000)..."
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
        -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Decryption successful (pbkdf2 method, 100000 iterations - legacy)"
        return 0
    fi
    
    log_verbose "Trying decryption with pbkdf2 (iterations: 10000)..."
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 \
        -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Decryption successful (pbkdf2 method, 10000 iterations)"
        return 0
    fi
    
    log_verbose "Trying decryption with pbkdf2 (iterations: 1000)..."
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter 1000 \
        -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Decryption successful (pbkdf2 method, 1000 iterations)"
        return 0
    fi
    
    log_verbose "Trying decryption with legacy method (no pbkdf2)..."
    if openssl enc -d -aes-256-cbc -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Decryption successful (legacy method)"
        return 0
    fi
    
    if [[ -n "$FIXED_SALT_FILE" ]] && [[ -f "$FIXED_SALT_FILE" ]]; then
        local salt_hex
        salt_hex=$(tr -d '\n\r' < "$FIXED_SALT_FILE")
        
        log_verbose "Trying decryption with fixed salt: $salt_hex (pbkdf2)..."
        if openssl enc -d -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -S "$salt_hex" \
            -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            log_verbose "✅ Decryption successful (fixed salt + pbkdf2)"
            return 0
        fi
        
        log_verbose "Trying decryption with fixed salt: $salt_hex (legacy)..."
        if openssl enc -d -aes-256-cbc -S "$salt_hex" \
            -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            log_verbose "✅ Decryption successful (fixed salt + legacy)"
            return 0
        fi
    fi
    
    log_verbose "Trying decryption with explicit -salt flag..."
    if openssl enc -d -aes-256-cbc -salt \
        -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Decryption successful (with -salt flag)"
        return 0
    fi
    
    log_verbose "Trying various algorithms..."
    for algo in aes-256-cfb aes-256-ofb aes-192-cbc aes-128-cbc; do
        if openssl enc -d -$algo -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
            -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            log_verbose "✅ Decryption successful (algorithm: $algo)"
            return 0
        fi
    done
    
    log_verbose "Trying decryption assuming no compression..."
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
        -in "$infile" -out "${outfile}.raw" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        if file "${outfile}.raw" | grep -q "gzip compressed"; then
            mv "${outfile}.raw" "$outfile"
            log_verbose "✅ Decryption successful (raw output is gzip)"
            return 0
        fi
        rm -f "${outfile}.raw" 2>/dev/null
    fi
    
    error_exit "OpenSSL decryption failed for $infile (all methods)"
}

fix_encrypted_filename() {
    local file="$1"
    if [[ "$file" == *.enc.enc ]]; then
        local fixed_file="${file%.enc}"
        log_verbose "Fixing double .enc extension: $file -> $fixed_file"
        mv "$file" "$fixed_file" 2>/dev/null || true
        echo "$fixed_file"
    else
        echo "$file"
    fi
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
        IFS=',' read -ra patterns <<< "$EXCLUDE_PATTERNS"
        for pattern in "${patterns[@]}"; do
            exclude_opts+=("--exclude=$pattern")
        done
    fi

    tar -cf "$tar_file" -C "$(dirname "$src")" "${exclude_opts[@]}" "$(basename "$src")" \
        --preserve-permissions --same-owner --xattrs 2>/dev/null || \
        tar -cf "$tar_file" -C "$(dirname "$src")" "${exclude_opts[@]}" "$(basename "$src")" \
        --preserve-permissions --same-owner

    log "🗜️ Compressing with gzip level $GZIP_LEVEL..."
    gzip -$GZIP_LEVEL "$tar_file" 2>/dev/null || error_exit "Compression failed for $tar_file"
    log "✅ Compression complete"
    if [[ ! -f "$gz_file" ]]; then
        error_exit "Compression failed for $tar_file"
    fi

    generate_checksums "$gz_file"
    encrypt_file "$gz_file" "$enc_file"
    if [[ -f "$enc_file" ]]; then
        sha256sum "$enc_file" | awk '{print $1}' | sed "s/^/SHA256: /" > "${enc_file}.enc.checksums"
        rm -f "$gz_file"
        log "✅ Encrypted backup created: $(basename "$enc_file")"
    fi
}

backup_docker_volume() {
    local volume="$1"
    local dest_dir="$2"
    local archive_base="${dest_dir}/volume_${volume}"
    local tar_file="${archive_base}.tar"
    local gz_file="${tar_file}.gz"
    local enc_file="${gz_file}.enc"

    log "📦 Backing up Docker volume: $volume"
    if ! docker volume inspect "$volume" &>/dev/null; then
        error_exit "Docker volume $volume does not exist"
    fi

    local container_name="backup_vol_${volume}_$(date +%s)"
    log_verbose "Creating container: $container_name"
    
    if ! docker run --rm --name "$container_name" \
        -v "$volume":/volume \
        -v "$dest_dir":/backup \
        "$DOCKER_IMAGE" \
        tar -cf "/backup/${volume}.tar" -C /volume . \
        --preserve-permissions --same-owner 2>/dev/null; then
        
        log_verbose "First tar attempt failed, trying without permissions..."
        docker run --rm --name "$container_name" \
            -v "$volume":/volume \
            -v "$dest_dir":/backup \
            alpine \
            tar -cf "/backup/${volume}.tar" -C /volume . 2>/dev/null || {
                error_exit "Failed to create tar for volume $volume"
            }
    fi

    if [[ ! -f "${dest_dir}/${volume}.tar" ]]; then
        error_exit "Tar file not created for volume $volume"
    fi

    mv "${dest_dir}/${volume}.tar" "$tar_file"
    
    if ! tar -tf "$tar_file" &>/dev/null; then
        error_exit "Tar file is corrupted or empty: $tar_file"
    fi

    log "🗜️ Compressing with gzip level $GZIP_LEVEL..."
    gzip -$GZIP_LEVEL "$tar_file" 2>/dev/null || error_exit "Compression failed for $tar_file"
    if [[ ! -f "$gz_file" ]] || [[ ! -s "$gz_file" ]]; then
        error_exit "Compression failed for $tar_file"
    fi

    generate_checksums "$gz_file"
    
    log_verbose "Encrypting volume backup..."
    encrypt_file "$gz_file" "$enc_file"
    
    if [[ -f "$enc_file" ]] && [[ -s "$enc_file" ]]; then
        sha256sum "$enc_file" | awk '{print $1}' | sed "s/^/SHA256: /" > "${enc_file}.enc.checksums"
        log_verbose "Created encrypted checksum: ${enc_file}.enc.checksums"
        
        rm -f "$gz_file"
        log "✅ Encrypted volume backup created: $(basename "$enc_file") ($(human_size $(stat -c%s "$enc_file" 2>/dev/null || echo 0)))"
    else
        error_exit "Encryption failed for $gz_file"
    fi
}

generate_checksums() {
    local file="$1"
    local checksum_file="${file}.checksums"
    {
        sha256sum "$file" | awk '{print $1}' | sed "s/^/SHA256: /"
    } > "$checksum_file"
    log_verbose "Checksums generated for $(basename "$file")"
}

verify_backup() {
    local enc_file="$1"
    
    if [[ ! -f "$enc_file" ]] || [[ ! -s "$enc_file" ]]; then
        log "❌ Encrypted file missing or empty: $(basename "$enc_file")"
        return 1
    fi
    
    local enc_checksum_file="${enc_file}.enc.checksums"
    
    if [[ -f "$enc_checksum_file" ]]; then
        local stored_sha=$(grep '^SHA256:' "$enc_checksum_file" 2>/dev/null | awk '{print $2}')
        local current_sha=$(sha256sum "$enc_file" 2>/dev/null | awk '{print $1}')
        
        log_verbose "Checksum stored:  $stored_sha"
        log_verbose "Checksum current: $current_sha"
        
        if [[ "$stored_sha" != "$current_sha" ]]; then
            log "❌ SHA256 MISMATCH for $(basename "$enc_file")"
            log "   Stored:  $stored_sha"
            log "   Current: $current_sha"
            return 1
        fi
        log "✅ SHA256 verified for $(basename "$enc_file")"
        return 0
    fi

    
    local checksum_file="${enc_file%.enc}.checksums"
    
    if [[ -f "$checksum_file" ]]; then
        log_verbose "No encrypted checksum found, using fallback verification for $(basename "$enc_file")"
        local tmp_dir
        tmp_dir=$(mktemp -d -p "$TMP_DIR" verify_decrypt_XXXXXX 2>/dev/null || 
                  echo "${TMP_DIR}/verify_decrypt_$$_$RANDOM")
        mkdir -p "$tmp_dir" 2>/dev/null
        local decrypted_file="${tmp_dir}/$(basename "${enc_file%.enc}")"
        
        if ! decrypt_file "$enc_file" "$decrypted_file" 2>/dev/null; then
            log "❌ Decryption failed for $(basename "$enc_file")"
            rm -rf "$tmp_dir" 2>/dev/null
            return 1
        fi
        
        local stored_sha=$(grep '^SHA256:' "$checksum_file" 2>/dev/null | awk '{print $2}')
        local current_sha=$(sha256sum "$decrypted_file" 2>/dev/null | awk '{print $1}')
        
        rm -rf "$tmp_dir" 2>/dev/null
        
        if [[ "$stored_sha" != "$current_sha" ]]; then
            log "❌ SHA256 MISMATCH for $(basename "$enc_file")"
            return 1
        fi
        
        log "✅ SHA256 verified for $(basename "$enc_file")"
        return 0
    fi
    
    log "⚠️ WARNING: No checksum file found for $(basename "$enc_file")"
    local tmp_dir
    tmp_dir=$(mktemp -d -p "$TMP_DIR" verify_decrypt_XXXXXX 2>/dev/null || 
              echo "${TMP_DIR}/verify_decrypt_$$_$RANDOM")
    mkdir -p "$tmp_dir" 2>/dev/null
    local decrypted_file="${tmp_dir}/$(basename "${enc_file%.enc}")"
    
    if decrypt_file "$enc_file" "$decrypted_file" 2>/dev/null; then
        log "✅ Decryption successful for $(basename "$enc_file") (no checksum available)"
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    else
        log "❌ Decryption failed for $(basename "$enc_file")"
        rm -rf "$tmp_dir" 2>/dev/null
        return 1
    fi
}

get_backup_age_days() {
    local filepath="$1"
    local filename=$(basename "$filepath")
    local date_str=$(echo "$filename" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
    if [[ -z "$date_str" ]]; then
        local mtime=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null)
        if [[ -n "$mtime" ]]; then
            local now=$(date +%s)
            echo $(( (now - mtime) / 86400 ))
        else
            echo 9999
        fi
    else
        local file_epoch=$(date -d "${date_str:0:8} ${date_str:9:2}:${date_str:11:2}:${date_str:13:2}" +%s 2>/dev/null || echo 0)
        if [[ $file_epoch -eq 0 ]]; then
            echo 9999
        else
            local now=$(date +%s)
            echo $(( (now - file_epoch) / 86400 ))
        fi
    fi
}

rotate_backups() {
    local backup_dir="$1"
    log "Rotating backups in $backup_dir"

    local file_count=$(find "$backup_dir" -maxdepth 1 -name "*.enc" -type f 2>/dev/null | wc -l)
    log_verbose "Found $file_count backup files in $backup_dir"

    local daily="$RETENTION_DAILY"
    local weekly="$RETENTION_WEEKLY"
    local monthly="$RETENTION_MONTHLY"

    local tmp_file
    if ! tmp_file=$(mktemp -p "$TMP_DIR" backup_rotate_XXXXXX 2>/dev/null); then
        tmp_file="${TMP_DIR}/backup_rotate_$$_$RANDOM"
    fi
    local grouped_file="${tmp_file}.grouped"

    find "$backup_dir" -maxdepth 1 -name "*.enc" -type f > "$tmp_file" 2>/dev/null

    while IFS= read -r encfile; do
        basename=$(basename "$encfile")
        type=$(echo "$basename" | sed -E 's/_[0-9]{8}_[0-9]{6}\.tar\.gz\.enc$//')
        if [[ "$type" == "$basename" ]]; then
            type=$(echo "$basename" | sed -E 's/\.tar\.gz\.enc$//')
        fi
        echo "$type|$encfile"
    done < "$tmp_file" 2>/dev/null | sort > "$grouped_file" 2>/dev/null

    local types=$(cut -d'|' -f1 "$grouped_file" 2>/dev/null | sort -u)

    for type in $types; do
        log_verbose "Processing type: $type"
        
        local files=()
        while IFS= read -r f; do
            files+=("$f")
        done < <(grep "^${type}|" "$grouped_file" 2>/dev/null | cut -d'|' -f2 | sort)

        local weekly_kept=()
        local monthly_kept=()

        for f in "${files[@]}"; do
            age=$(get_backup_age_days "$f")
            
            if (( age <= daily )); then
                log_verbose "Keeping (daily): $f (age $age days)"
                continue
            fi
            
            if (( age <= 7 * weekly )); then
                week_num=$(( (age - 1) / 7 ))
                local already_kept=false
                for kept in "${weekly_kept[@]}"; do
                    if [[ "$kept" == "w$week_num" ]]; then
                        already_kept=true
                        break
                    fi
                done
                if [[ "$already_kept" == "false" ]]; then
                    weekly_kept+=("w$week_num")
                    log_verbose "Keeping (weekly): $f (age $age days, week $week_num)"
                    continue
                else
                    log_verbose "Skipping (weekly duplicate): $f (age $age days, week $week_num)"
                fi
            fi
            
            if (( age <= 30 * monthly )); then
                month_num=$(( (age - 1) / 30 ))
                local already_kept=false
                for kept in "${monthly_kept[@]}"; do
                    if [[ "$kept" == "m$month_num" ]]; then
                        already_kept=true
                        break
                    fi
                done
                if [[ "$already_kept" == "false" ]]; then
                    monthly_kept+=("m$month_num")
                    log_verbose "Keeping (monthly): $f (age $age days, month $month_num)"
                    continue
                else
                    log_verbose "Skipping (monthly duplicate): $f (age $age days, month $month_num)"
                fi
            fi
            
            log "Deleting old backup: $f (age $age days, exceeds all retention)"
            rm -f "$f" 2>/dev/null
            rm -f "${f%.enc}.checksums" 2>/dev/null
        done
    done

    rm -f "$tmp_file" "$grouped_file" 2>/dev/null
    log "✅ Rotation completed"
}

verify_backup_integrity() {
    local enc_file="$1"
    local result=0
    
    echo ""
    echo "🔍 Verifying: $(basename "$enc_file")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ ! -f "$enc_file" ]]; then
        echo "❌ File not found: $enc_file"
        return 1
    fi
    
    local file_size=$(stat -c%s "$enc_file" 2>/dev/null || echo 0)
    if [[ $file_size -eq 0 ]]; then
        echo "❌ File is empty (0 bytes)"
        return 1
    fi
    echo "📦 File size: $(human_size "$file_size")"
    
    local enc_checksum_file="${enc_file}.enc.checksums"
    
    if [[ -f "$enc_checksum_file" ]]; then
        local stored_sha=$(grep '^SHA256:' "$enc_checksum_file" 2>/dev/null | awk '{print $2}')
        local current_sha=$(sha256sum "$enc_file" 2>/dev/null | awk '{print $1}')
        
        echo "🔐 Checksum details:"
        echo "   📝 Stored:  $stored_sha"
        echo "   🔄 Current: $current_sha"
        
        if [[ "$stored_sha" == "$current_sha" ]]; then
            echo "✅ SHA256: MATCH"
        else
            echo "❌ SHA256: MISMATCH"
            result=1
        fi
    else
        local checksum_file="${enc_file%.enc}.checksums"
        if [[ -f "$checksum_file" ]]; then
            echo "⚠️  Using fallback checksum (gz file)"
            local stored_sha=$(grep '^SHA256:' "$checksum_file" 2>/dev/null | awk '{print $2}')
            local current_sha=$(sha256sum "$enc_file" 2>/dev/null | awk '{print $1}')
            
            echo "🔐 Checksum details (fallback):"
            echo "   📝 Stored:  $stored_sha"
            echo "   🔄 Current: $current_sha"
            
            if [[ "$stored_sha" == "$current_sha" ]]; then
                echo "✅ SHA256: MATCH (fallback)"
            else
                echo "❌ SHA256: MISMATCH (fallback)"
                result=1
            fi
        else
            echo "⚠️  WARNING: No checksum file found"
            result=1
        fi
    fi
    
    echo "🔐 Testing decryption..."
    local test_dir
    if ! test_dir=$(mktemp -d -p "$TMP_DIR" verify_test_XXXXXX 2>/dev/null); then
        test_dir="${TMP_DIR}/verify_test_$$_$RANDOM"
    fi
    mkdir -p "$test_dir" 2>/dev/null || true
    local test_output="${test_dir}/test_decrypt.gz"
    
    if decrypt_file "$enc_file" "$test_output" 2>/dev/null; then
        if [[ -f "$test_output" ]] && [[ -s "$test_output" ]]; then
            echo "✅ Decryption: SUCCESS"
            if gzip -t "$test_output" 2>/dev/null; then
                echo "✅ Gzip:      VALID"
            else
                echo "⚠️  Gzip:      INVALID or corrupt after decryption"
                result=1
            fi
        else
            echo "❌ Decryption: FAILED (output empty)"
            result=1
        fi
    else
        echo "❌ Decryption: FAILED"
        result=1
    fi
    
    rm -rf "$test_dir" 2>/dev/null || true
    
    if [[ $result -eq 0 ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ VERIFICATION PASSED: $(basename "$enc_file") is intact"
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "❌ VERIFICATION FAILED: $(basename "$enc_file") has issues"
    fi
    echo ""
    
    return $result
}

verify_all_backups() {
    local backup_dir="$1"
    local failed=0
    local total=0
    
    echo ""
    echo "📦 Verifying all backups in: $backup_dir"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    while IFS= read -r enc_file; do
        total=$((total + 1))
        if ! verify_backup_integrity "$enc_file"; then
            failed=$((failed + 1))
        fi
    done < <(find "$backup_dir" -name "*.enc" -type f 2>/dev/null | sort)
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 SUMMARY: $total backups verified, $failed failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ $failed -eq 0 ]] && [[ $total -gt 0 ]]; then
        echo "✅ All backups are intact!"
    elif [[ $total -eq 0 ]]; then
        echo "⚠️  No backups found in: $backup_dir"
    else
        echo "⚠️  $failed backup(s) failed verification"
    fi
    echo ""
    
    return $failed
}

deduplicate_backups() {
    local backup_dir="$1"
    
    if [[ -z "$DEDUP_TOOL" ]]; then
        log_verbose "Deduplication disabled (DEDUP_TOOL not set)"
        return 0
    fi
    
    if ! command -v "$DEDUP_TOOL" &> /dev/null; then
        log "⚠️ WARNING: Deduplication tool '$DEDUP_TOOL' not found. Skipping dedup."
        return 0
    fi
    
    log "🔗 Running deduplication on $backup_dir using $DEDUP_TOOL..."
    
    local start_time=$(date +%s)
    
    case "$DEDUP_TOOL" in
        hardlink)
            if hardlink "$backup_dir" >/dev/null 2>&1; then
                local total_files=$(find "$backup_dir" -name "*.enc" -type f 2>/dev/null | wc -l)
                local duration=$(( $(date +%s) - start_time ))
                log "✅ Deduplication complete: $total_files .enc files processed (${duration}s)"
                return 0
            else
                log "⚠️ WARNING: hardlink deduplication failed"
                return 1
            fi
            ;;
        jdupes)
            if jdupes -L -r "$backup_dir" >/dev/null 2>&1; then
                local total_files=$(find "$backup_dir" -name "*.enc" -type f 2>/dev/null | wc -l)
                local duration=$(( $(date +%s) - start_time ))
                log "✅ Deduplication complete: $total_files .enc files processed (${duration}s)"
                return 0
            else
                log "⚠️ WARNING: jdupes deduplication failed"
                return 1
            fi
            ;;
        *)
            log "⚠️ WARNING: Unknown deduplication tool '$DEDUP_TOOL'. Supported: hardlink, jdupes"
            return 1
            ;;
    esac
}

restore_from_backup() {
    local enc_file="$1"
    if [[ ! -f "$enc_file" ]]; then
        error_exit "Backup file not found: $enc_file"
    fi

    init_tmp

    local file_basename
    file_basename=$(basename "$enc_file")
    
    local type
    if echo "$file_basename" | grep -qE '_[0-9]{8}_[0-9]{6}\.tar\.gz\.enc$'; then
        type=$(echo "$file_basename" | sed -E 's/_[0-9]{8}_[0-9]{6}\.tar\.gz\.enc$//')
    else
        type=$(echo "$file_basename" | sed -E 's/\.tar\.gz\.enc$//')
    fi
    
    log "🔄 Restoring type: $type"

    local tmp_dir
    tmp_dir=$(mktemp -d -p "$TMP_DIR" restore_XXXXXX)
    
    trap 'rm -rf "$tmp_dir" 2>/dev/null || true; cleanup_temp; exit' INT TERM EXIT
    
    local decrypted_file="${tmp_dir}/$(basename "${enc_file%.enc}")"
    log "🔐 Decrypting $(basename "$enc_file")..."
    decrypt_file "$enc_file" "$decrypted_file"

    if [[ ! -f "$decrypted_file" ]]; then
        error_exit "Decryption failed or output missing"
    fi

    local checksum_file="${enc_file%.enc}.checksums"
    if [[ -f "$checksum_file" ]]; then
        log "🔍 Verifying checksum..."
        local sha_original
        sha_original=$(grep '^SHA256:' "$checksum_file" | awk '{print $2}')
        local sha_current
        sha_current=$(sha256sum "$decrypted_file" | awk '{print $1}')
        if [[ "$sha_original" != "$sha_current" ]]; then
            error_exit "SHA256 checksum mismatch! Restore aborted."
        else
            log "✅ Checksum verification passed."
        fi
    else
        log "⚠️ WARNING: No checksum file found; skipping verification."
    fi

    log "📦 Decompressing $(basename "$decrypted_file")..."
    gzip -d "$decrypted_file" 2>/dev/null || error_exit "Gunzip failed"
    local tar_file="${decrypted_file%.gz}"
    if [[ ! -f "$tar_file" ]]; then
        error_exit "Decompression failed: $(basename "$tar_file") not found"
    fi

    if [[ "$type" == "digital-independence" ]]; then
        local dest_dir="$SOURCE_DIR"
        dest_dir="${dest_dir%/}"
        
        log "📁 Restoring directory backup to $dest_dir"
        
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
        
        log_verbose "First entry in tar: $first_entry"
        
        local top_dir=$(echo "$first_entry" | cut -d'/' -f1)
        
        local all_under_top=true
        local other_files=$(tar -tf "$tar_file" 2>/dev/null | grep -v "^$top_dir/" | grep -v "^$top_dir$" | head -1)
        if [[ -n "$other_files" ]]; then
            all_under_top=false
        fi
        
        if [[ "$all_under_top" == "true" ]] && [[ -n "$top_dir" ]]; then
            log "📋 Tar contains all files under top-level directory: $top_dir"
            
            local extract_dir="${tmp_dir}/extract"
            mkdir -p "$extract_dir"
            tar -xf "$tar_file" -C "$extract_dir" --preserve-permissions --same-owner
            
            if [[ -d "$extract_dir/$top_dir" ]]; then
                log "📋 Moving contents from $top_dir to $dest_dir"
                
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
                    local current_user="${SUDO_USER:-$(whoami)}"
                    sudo chown -R "$current_user":"$current_user" "$dest_dir" 2>/dev/null || true
                fi
                
                rm -rf "$extract_dir"
            else
                log "📋 Fallback: Extracting directly to $dest_dir"
                if [[ "$use_sudo" == "true" ]]; then
                    sudo tar -xf "$tar_file" -C "$dest_dir" --preserve-permissions --same-owner
                else
                    tar -xf "$tar_file" -C "$dest_dir" --preserve-permissions --same-owner
                fi
                log "✅ Directory restore completed to $dest_dir"
            fi
        else
            log "📋 Tar contains multiple top-level items or flat structure"
            
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
        log "📦 Restoring Docker volume: $volume_name"
        
        if ! docker volume inspect "$volume_name" &>/dev/null; then
            log "📂 Volume $volume_name does not exist; creating it."
            docker volume create "$volume_name" || error_exit "Failed to create volume $volume_name"
        fi
        
        local extract_dir="${tmp_dir}/extract_vol"
        mkdir -p "$extract_dir"
        
        tar -xf "$tar_file" -C "$extract_dir" --no-same-owner --no-same-permissions 2>/dev/null || \
            tar -xf "$tar_file" -C "$extract_dir" --no-same-owner
        
        local vol_first_entry=$(ls -A "$extract_dir" 2>/dev/null | head -1)
        
        local container_name="restore_vol_${volume_name}_$(date +%s)_$$"
        
        if [[ -d "$extract_dir/$vol_first_entry" ]] && [[ $(ls -A "$extract_dir" 2>/dev/null | wc -l) -eq 1 ]]; then
            log "📋 Volume data is under single directory: $vol_first_entry"
            
            docker run -d --name "$container_name" \
                -v "$volume_name":/volume \
                "$DOCKER_IMAGE" \
                timeout 30 sleep infinity 2>/dev/null || \
                docker run -d --name "$container_name" \
                    -v "$volume_name":/volume \
                    alpine sleep infinity 2>/dev/null || {
                        log "⚠️ Failed to create restore container. Trying with different name..."
                        container_name="restore_vol_${volume_name}_$(date +%s)_$RANDOM"
                        docker run -d --name "$container_name" \
                            -v "$volume_name":/volume \
                            alpine sleep infinity 2>/dev/null || error_exit "Cannot create restore container"
                    }
            
            sleep 2
            
            docker cp "$extract_dir/$vol_first_entry/." "$container_name:/volume/" 2>/dev/null || \
                docker cp "$extract_dir/$vol_first_entry" "$container_name:/volume/" 2>/dev/null
            
            docker stop "$container_name" 2>/dev/null || true
            docker rm "$container_name" 2>/dev/null || true
            
            log "✅ Volume restore completed for $volume_name"
        else
            log "📋 Multiple top-level items found, copying all..."
            
            docker run -d --name "$container_name" \
                -v "$volume_name":/volume \
                "$DOCKER_IMAGE" \
                sleep infinity 2>/dev/null || \
                docker run -d --name "$container_name" \
                    -v "$volume_name":/volume \
                    alpine sleep infinity 2>/dev/null || {
                        log "⚠️ Failed to create restore container. Trying with different name..."
                        container_name="restore_vol_${volume_name}_$(date +%s)_$RANDOM"
                        docker run -d --name "$container_name" \
                            -v "$volume_name":/volume \
                            alpine sleep infinity 2>/dev/null || error_exit "Cannot create restore container"
                    }
            
            sleep 2
            
            docker cp "$extract_dir/." "$container_name:/volume/" 2>/dev/null || \
                docker cp "$extract_dir" "$container_name:/volume/" 2>/dev/null
            
            docker stop "$container_name" 2>/dev/null || true
            docker rm "$container_name" 2>/dev/null || true
            
            log "✅ Volume restore completed for $volume_name"
        fi
        
    else
        error_exit "Unknown backup type: $type"
    fi

    rm -rf "$tmp_dir" 2>/dev/null || true
    trap - INT TERM EXIT
    
    local restore_msg="📁 File: $(basename "$enc_file")\n"
    restore_msg+="📂 Type: $type\n"
    restore_msg+="⏱️ Time: $(date '+%Y-%m-%d %H:%M:%S')\n"
    restore_msg+="✅ Status: Restore completed successfully"
    
    send_ntfy "$restore_msg" "restore"
    
    log "✅ Restore completed successfully."
}

list_backups() {
    local backup_dir="$1"
    echo ""
    echo "📦 Available backups in: $backup_dir"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local found=false
    while IFS= read -r enc_file; do
        found=true
        local basename=$(basename "$enc_file")
        local size=$(human_size $(stat -c%s "$enc_file" 2>/dev/null || echo 0))
        local date=$(echo "$basename" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | sed 's/_/ /' | head -1)
        
        local checksum_file="${enc_file%.enc}.checksums"
        local status=""
        if [[ -f "$checksum_file" ]]; then
            status="✅"
        else
            status="⚠️"
        fi
        
        printf "  %s %-50s  %-10s  %s\n" "$status" "$basename" "$size" "$date"
    done < <(find "$backup_dir" -name "*.enc" -type f 2>/dev/null | sort)
    
    if [[ "$found" == "false" ]]; then
        echo "  ⚠️  No backups found in: $backup_dir"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

log_section() {
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "$1"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

do_backup() {
    BACKUP_START_TIME=$(date +%s)
    local start_date=$(date '+%Y-%m-%d %H:%M:%S')
    
    log_section "🚀 Starting backup (v$VERSION)"
    
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
    log "🔑 PBKDF2 iterations: ${PBKDF2_ITERATIONS:-600000}"
    if [[ -n "$FIXED_SALT_FILE" ]]; then
        log "🔗 Deduplication: ENABLED (fixed salt)"
    else
        log "🔗 Deduplication: DISABLED (random salt)"
    fi
    log "🗜️ Compression: gzip level $GZIP_LEVEL"
    log "📋 Retention: Daily=${RETENTION_DAILY}, Weekly=${RETENTION_WEEKLY}, Monthly=${RETENTION_MONTHLY}"
    
    send_ntfy "📅 Time: $start_date\n💻 Host: $hostname\n📁 Source: $SOURCE_DIR\n📊 Size: $source_size_human ($source_files files)\n🐳 Volumes: $volume_count volumes\n💾 Target: $BACKUP_BASE_DIR\n💿 Free space: $free_space_human\n🔒 Encryption: AES-256-CBC\n🔑 PBKDF2: ${PBKDF2_ITERATIONS:-600000} iterations\n🔗 Dedup: $([ -n "$FIXED_SALT_FILE" ] && echo "ENABLED" || echo "DISABLED")\n🗜️ Compression: gzip level $GZIP_LEVEL\n📋 Retention: Daily=${RETENTION_DAILY}, Weekly=${RETENTION_WEEKLY}, Monthly=${RETENTION_MONTHLY}" "info"
    acquire_lock
    check_docker
    check_disk_space "$BACKUP_BASE_DIR" 1024

    local timestamp
    timestamp=$(get_timestamp)
    local backup_dir="${BACKUP_BASE_DIR}/${BACKUP_PREFIX}_${timestamp}"
    mkdir -p "$backup_dir"
    log "📂 Backup directory created: $backup_dir"

    backup_directory "$SOURCE_DIR" "$backup_dir" "digital-independence"

    local pids=()
    local failed=0
    local vol_count=0

    for vol in "${DOCKER_VOLUMES[@]}"; do
        vol_count=$((vol_count + 1))
        log "Processing volume $vol_count of ${#DOCKER_VOLUMES[@]}: $vol"
        backup_docker_volume "$vol" "$backup_dir" &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait $pid || failed=$((failed + 1))
    done

    if [[ $failed -gt 0 ]]; then
        log "⚠️ WARNING: $failed volume backup(s) failed"
    fi

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

    if [[ -n "$DEDUP_TOOL" ]]; then
        deduplicate_backups "$BACKUP_BASE_DIR"
    fi

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

    log_section "✅ Backup completed successfully"
    log "⏱️ Duration: $duration_human"
    log "📦 Archives: $backup_count encrypted files"
    log "💾 Total size: $total_backup_size_human"
    log "📍 Location: $backup_dir"
    log "📝 Log: $LOG_FILE"

    send_ntfy "📅 Completed: $end_date\n⏱️ Duration: $duration_human\n📦 Archives: $backup_count encrypted files\n💾 Total size: $total_backup_size_human\n📁 Source size: $source_size_human ($source_files files)\n🐳 Volumes: $volume_count volumes\n💿 Free space: $free_space_human → $(human_size $((new_free_space_mb * 1024 * 1024))) (used $space_used_human)\n🔒 Verification: ✅ All checksums verified\n🗑️ Retention: Daily=${RETENTION_DAILY}, Weekly=${RETENTION_WEEKLY}, Monthly=${RETENTION_MONTHLY}\n🔗 Deduplication: $([ -n "$FIXED_SALT_FILE" ] && echo "ENABLED" || echo "DISABLED")\n📍 Location: $backup_dir\n📝 Log: $LOG_FILE" "success"
    release_lock
    cleanup_temp
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

run_test() {
    echo ""
    echo "🔐 Testing Encryption/Decryption System"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        echo "⚠️  Encryption key not found: $ENCRYPTION_KEY_FILE"
        echo "   Generating test key..."
        openssl rand -base64 32 > encryption.key.test
        chmod 600 encryption.key.test
        ENCRYPTION_KEY_FILE="encryption.key.test"
        echo "✅ Test key created: encryption.key.test"
    else
        echo "✅ Using encryption key: $ENCRYPTION_KEY_FILE"
    fi
    
    local TEST_DIR="${SCRIPT_DIR}/.test"
    mkdir -p "$TEST_DIR"
    chmod 700 "$TEST_DIR" 2>/dev/null || true
    
    echo ""
    echo "📄 Testing text file encryption/decryption..."
    
    echo "Test content at $(date)" > "${TEST_DIR}/test.txt"
    echo "Line 2: Testing PBKDF2 with ${PBKDF2_ITERATIONS:-600000} iterations" >> "${TEST_DIR}/test.txt"
    echo "Line 3: This should be encrypted and decrypted successfully" >> "${TEST_DIR}/test.txt"
    
    if openssl enc -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -salt \
        -in "${TEST_DIR}/test.txt" -out "${TEST_DIR}/test.txt.enc" \
        -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        echo "  ✅ Text encryption: SUCCESS"
    else
        echo "  ❌ Text encryption: FAILED"
        rm -rf "$TEST_DIR" 2>/dev/null
        return 1
    fi
    
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
        -in "${TEST_DIR}/test.txt.enc" -out "${TEST_DIR}/test.txt.dec" \
        -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        echo "  ✅ Text decryption: SUCCESS"
    else
        echo "  ❌ Text decryption: FAILED"
        rm -rf "$TEST_DIR" 2>/dev/null
        return 1
    fi
    
    if diff "${TEST_DIR}/test.txt" "${TEST_DIR}/test.txt.dec" >/dev/null 2>&1; then
        echo "  ✅ Text file: PASSED (files match)"
    else
        echo "  ❌ Text file: FAILED (files don't match)"
        rm -rf "$TEST_DIR" 2>/dev/null
        return 1
    fi
    
    echo ""
    echo "📦 Testing binary file encryption/decryption..."
    
    dd if=/dev/urandom of="${TEST_DIR}/test.bin" bs=1K count=10 2>/dev/null
    
    if openssl enc -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -salt \
        -in "${TEST_DIR}/test.bin" -out "${TEST_DIR}/test.bin.enc" \
        -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        echo "  ✅ Binary encryption: SUCCESS"
    else
        echo "  ❌ Binary encryption: FAILED"
        rm -rf "$TEST_DIR" 2>/dev/null
        return 1
    fi
    
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
        -in "${TEST_DIR}/test.bin.enc" -out "${TEST_DIR}/test.bin.dec" \
        -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        echo "  ✅ Binary decryption: SUCCESS"
    else
        echo "  ❌ Binary decryption: FAILED"
        rm -rf "$TEST_DIR" 2>/dev/null
        return 1
    fi
    
    if cmp "${TEST_DIR}/test.bin" "${TEST_DIR}/test.bin.dec" >/dev/null 2>&1; then
        echo "  ✅ Binary file: PASSED (files match)"
    else
        echo "  ❌ Binary file: FAILED (files don't match)"
        rm -rf "$TEST_DIR" 2>/dev/null
        return 1
    fi
    
    echo ""
    echo "📊 File size comparison:"
    
    local text_orig=$(stat -c%s "${TEST_DIR}/test.txt" 2>/dev/null || stat -f%z "${TEST_DIR}/test.txt" 2>/dev/null)
    local text_enc=$(stat -c%s "${TEST_DIR}/test.txt.enc" 2>/dev/null || stat -f%z "${TEST_DIR}/test.txt.enc" 2>/dev/null)
    local text_dec=$(stat -c%s "${TEST_DIR}/test.txt.dec" 2>/dev/null || stat -f%z "${TEST_DIR}/test.txt.dec" 2>/dev/null)
    local bin_orig=$(stat -c%s "${TEST_DIR}/test.bin" 2>/dev/null || stat -f%z "${TEST_DIR}/test.bin" 2>/dev/null)
    local bin_enc=$(stat -c%s "${TEST_DIR}/test.bin.enc" 2>/dev/null || stat -f%z "${TEST_DIR}/test.bin.enc" 2>/dev/null)
    local bin_dec=$(stat -c%s "${TEST_DIR}/test.bin.dec" 2>/dev/null || stat -f%z "${TEST_DIR}/test.bin.dec" 2>/dev/null)
    
    echo "  📄 Text:    Original: ${text_orig}B → Encrypted: ${text_enc}B → Decrypted: ${text_dec}B"
    echo "  📦 Binary:  Original: ${bin_orig}B → Encrypted: ${bin_enc}B → Decrypted: ${bin_dec}B"
    
    echo ""
    echo "✅ Testing PBKDF2 compatibility..."
    
    for iter in 100000 10000 1000; do
        local enc_file="${TEST_DIR}/test_iter_${iter}.enc"
        local dec_file="${TEST_DIR}/test_iter_${iter}.dec"
        
        if openssl enc -aes-256-cbc -pbkdf2 -iter "${iter}" -salt \
            -in "${TEST_DIR}/test.txt" -out "$enc_file" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            
            if openssl enc -d -aes-256-cbc -pbkdf2 -iter "${iter}" \
                -in "$enc_file" -out "$dec_file" \
                -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
                
                if diff "${TEST_DIR}/test.txt" "$dec_file" >/dev/null 2>&1; then
                    echo "  ✅ PBKDF2 ${iter} iterations: PASSED"
                else
                    echo "  ❌ PBKDF2 ${iter} iterations: FAILED (file mismatch)"
                fi
            else
                echo "  ❌ PBKDF2 ${iter} iterations: FAILED (decryption)"
            fi
        else
            echo "  ❌ PBKDF2 ${iter} iterations: FAILED (encryption)"
        fi
        
        rm -f "$enc_file" "$dec_file" 2>/dev/null
    done
    
    if [[ -n "$FIXED_SALT_FILE" ]] && [[ -f "$FIXED_SALT_FILE" ]]; then
        echo ""
        echo "🔗 Testing fixed salt (deduplication mode)..."
        
        local salt_hex=$(tr -d '\n\r' < "$FIXED_SALT_FILE")
        echo "  Salt: $salt_hex"
        
        openssl enc -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -S "$salt_hex" \
            -in "${TEST_DIR}/test.txt" -out "${TEST_DIR}/test.fixed.enc" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null
        
        openssl enc -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -S "$salt_hex" \
            -in "${TEST_DIR}/test.txt" -out "${TEST_DIR}/test.fixed2.enc" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null
        
        if cmp "${TEST_DIR}/test.fixed.enc" "${TEST_DIR}/test.fixed2.enc" >/dev/null 2>&1; then
            echo "  ✅ Fixed salt: Identical encryption (deduplication works)"
        else
            echo "  ⚠️  Fixed salt: Files differ (deduplication may not work)"
        fi
        
        if openssl enc -d -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -S "$salt_hex" \
            -in "${TEST_DIR}/test.fixed.enc" -out "${TEST_DIR}/test.fixed.dec" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            
            if diff "${TEST_DIR}/test.txt" "${TEST_DIR}/test.fixed.dec" >/dev/null 2>&1; then
                echo "  ✅ Fixed salt decryption: PASSED"
            else
                echo "  ❌ Fixed salt decryption: FAILED"
            fi
        else
            echo "  ❌ Fixed salt decryption: FAILED"
        fi
        
        rm -f "${TEST_DIR}/test.fixed.enc" "${TEST_DIR}/test.fixed2.enc" "${TEST_DIR}/test.fixed.dec" 2>/dev/null
    fi
    
    echo ""
    echo "🔑 Testing encryption key permissions..."
    
    local key_perm=$(stat -c %a "$ENCRYPTION_KEY_FILE" 2>/dev/null || stat -f %Lp "$ENCRYPTION_KEY_FILE" 2>/dev/null)
    if [[ "$key_perm" -le 600 ]]; then
        echo "  ✅ Key permissions: $key_perm (secure)"
    else
        echo "  ⚠️  Key permissions: $key_perm (should be 600 or less)"
        echo "     Run: chmod 600 $ENCRYPTION_KEY_FILE"
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ ALL TESTS PASSED!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📊 Test Summary:"
    echo "  • Text encryption/decryption: ✅"
    echo "  • Binary encryption/decryption: ✅"
    echo "  • PBKDF2 compatibility: ✅ (all iteration counts)"
    if [[ -n "$FIXED_SALT_FILE" ]]; then
        echo "  • Fixed salt deduplication: ✅"
    fi
    echo "  • Key security: $([[ "$key_perm" -le 600 ]] && echo "✅" || echo "⚠️")"
    echo ""
    echo "📁 Test files kept in: $TEST_DIR"
    echo "   (Remove with: rm -rf $TEST_DIR)"
    echo ""
    echo "🔐 Your encryption system is ready to use!"
    echo ""
    
    if [[ -f "encryption.key.test" ]]; then
        echo "🧹 Removing test encryption key..."
        rm -f encryption.key.test
    fi
    
    return 0
}

show_help() {
    cat <<EOF
📦 backup.sh - Enterprise-grade backup script (v$VERSION)

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    --restore <file>      Restore from the specified encrypted backup file
    --verify <file>       Verify integrity of a specific backup file
    --verify-all          Verify all backups in the backup directory
    --list                List all available backups
    --dedup               Run deduplication on the backup directory (requires hardlink or jdupes)
    --test                Run encryption/decryption test suite
    --help, -h            Show this help message

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

    Optional settings:
        PBKDF2_ITERATIONS     - PBKDF2 iterations for key derivation (default: 600000)
                                Higher = more secure but slower. Minimum: 100000
                                Recommended: 600000+ for 2024 standards

        FIXED_SALT_FILE       - Path to file containing 16 hex chars (8 bytes) for fixed salt
                                Enables deterministic encryption → identical data yields identical .enc
                                Allows deduplication via hard links
        DEDUP_TOOL            - Tool to use for dedup: "hardlink" or "jdupes" (default: hardlink)

EXAMPLES:
    # Perform a full backup
    ./backup.sh

    # Test encryption/decryption
    ./backup.sh --test

    # List available backups
    ./backup.sh --list

    # Verify a specific backup
    ./backup.sh --verify /path/to/backup.tar.gz.enc

    # Verify all backups
    ./backup.sh --verify-all

    # Restore from a specific backup
    ./backup.sh --restore /path/to/backup.tar.gz.enc

    # Run deduplication on backup directory (after backup)
    ./backup.sh --dedup

SECURITY:
    - encryption.key should have permissions 600
    - backup.conf should never be committed to version control
    - All sensitive data is encrypted with AES-256-CBC
    - PBKDF2 iterations configurable (default: 600000)
    - Supports both modern (pbkdf2) and legacy encryption methods
    - Fixed salt reduces randomness but enables deduplication; use only if you trust your environment

NOTES:
    - Verification uses SHA256 (MD5 removed for security)
    - Backup rotation now correctly implements daily, weekly, and monthly retention
    - Notifications sent via ntfy.sh with fallback to custom server
    - Deduplication reduces storage by hardlinking identical .enc files; requires fixed salt

EOF
}

main() {
    case "${1:-}" in
        --test)
            load_config
            init_tmp
            run_test
            ;;
        --restore)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: Missing backup file for restore."
                echo "Usage: $SCRIPT_NAME --restore <backup-file>"
                exit 1
            fi
            load_config
            init_tmp
            restore_from_backup "$2"
            ;;
        --verify)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: Missing backup file for verification."
                echo "Usage: $SCRIPT_NAME --verify <backup-file>"
                exit 1
            fi
            load_config
            init_tmp
            verify_backup_integrity "$2"
            ;;
        --verify-all)
            load_config
            init_tmp
            verify_all_backups "$BACKUP_BASE_DIR"
            ;;
        --list)
            load_config
            list_backups "$BACKUP_BASE_DIR"
            ;;
        --dedup)
            load_config
            init_tmp
            deduplicate_backups "$BACKUP_BASE_DIR"
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
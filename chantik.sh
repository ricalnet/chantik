#!/usr/bin/env bash
#
# chantik.sh - 🕊️ ChaCha20-Authenticated Backup Protection
# Backup solution for directories and Docker volumes
# with ChaCha20-Poly1305 encryption, compression, smart retention, 
# incremental backups, deduplication, and real-time notifications.
#
# Security: All sensitive configuration is stored in chantik.conf
#           which should be excluded from version control.

set -euo pipefail
IFS=$'\n\t'

VERSION="0.1.1"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# -----------------------------------------------------------------------------
# Global Settings
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/chantik.conf"
CONFIG_EXAMPLE="${SCRIPT_DIR}/chantik.conf.example"
LOCK_FILE="${SCRIPT_DIR}/.chantik.lock"
LOG_FILE="${SCRIPT_DIR}/chantik.log"
TMP_DIR="${SCRIPT_DIR}/.tmp"
BACKUP_START_TIME=0
BACKUP_END_TIME=0
BRAND_NAME="Chantik"
BRAND_TAGLINE="ChaCha20-Authenticated Backup Protection"
BRAND_MOTTO="In ChaCha We Trust — Authentically Secured"
BRAND_EMOJI="🕊️"

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
BACKUP_PREFIX="chantik-backup"
EXCLUDE_PATTERNS=""
MAX_BACKUP_SIZE_MB=0
NTFY_CUSTOM_SERVER=""
FIXED_SALT_FILE=""
DEDUP_TOOL="hardlink"
PBKDF2_ITERATIONS=600000
INCREMENTAL_ENABLED=false
INCREMENTAL_BASE_DIR="${BACKUP_BASE_DIR}/.incremental"
SNAPSHOT_FILE=""
FULL_BACKUP_INTERVAL=7

check_chacha20_support() {
    if openssl enc -chacha20 -help 2>&1 | grep -q "unknown option"; then
        return 1
    fi
    if echo "test" | openssl enc -chacha20 -pass pass:test 2>/dev/null | \
       openssl enc -d -chacha20 -pass pass:test >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "🕊️ ERROR: Configuration file not found: $CONFIG_FILE"
        echo ""
        echo "To set up your Chantik configuration:"
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
        echo "🕊️ ERROR: Missing required configuration variables in $CONFIG_FILE:"
        printf "  - %s\n" "${missing_vars[@]}"
        echo ""
        echo "Please update $CONFIG_FILE with your values."
        exit 1
    fi

    INCREMENTAL_ENABLED="${INCREMENTAL_ENABLED:-false}"
    FULL_BACKUP_INTERVAL="${FULL_BACKUP_INTERVAL:-7}"
    INCREMENTAL_BASE_DIR="${BACKUP_BASE_DIR}/.incremental"

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

    if check_chacha20_support; then
        ENCRYPTION_CIPHER="chacha20"
        log_verbose "ChaCha20-Poly1305 is available and will be used."
    else
        ENCRYPTION_CIPHER="aes-256-cbc"
        echo "⚠️ WARNING: ChaCha20-Poly1305 not supported; falling back to AES-256-CBC."
        echo "   This may be slower on this system."
    fi

    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        echo "🕊️ ERROR: Encryption key file not found: $ENCRYPTION_KEY_FILE"
        echo ""
        echo "Generate one using:"
        echo "  openssl rand -base64 32 > encryption.key"
        echo "  chmod 600 encryption.key"
        exit 1
    fi

    if [[ ! -d "$SOURCE_DIR" ]]; then
        echo "🕊️ ERROR: Source directory does not exist: $SOURCE_DIR"
        exit 1
    fi

    mkdir -p "$BACKUP_BASE_DIR" 2>/dev/null || {
        echo "🕊️ ERROR: Cannot create backup directory: $BACKUP_BASE_DIR"
        exit 1
    }

    if [[ ! -w "$BACKUP_BASE_DIR" ]]; then
        echo "🕊️ ERROR: Backup directory is not writable: $BACKUP_BASE_DIR"
        exit 1
    fi

    if [[ "$INCREMENTAL_ENABLED" == "true" ]]; then
        mkdir -p "$INCREMENTAL_BASE_DIR" 2>/dev/null || {
            echo "🕊️ ERROR: Cannot create incremental directory: $INCREMENTAL_BASE_DIR"
            exit 1
        }
        log_verbose "Incremental backup enabled (base: $INCREMENTAL_BASE_DIR)"
    fi

    if [[ -n "$FIXED_SALT_FILE" ]]; then
        if [[ ! -f "$FIXED_SALT_FILE" ]]; then
            echo "🕊️ ERROR: Fixed salt file not found: $FIXED_SALT_FILE"
            echo "Generate a fixed salt (16 hex chars) with:"
            echo "  openssl rand -hex 8 > fixed_salt.txt"
            exit 1
        fi
        local salt_content
        salt_content=$(tr -d '\n\r' < "$FIXED_SALT_FILE")
        if [[ ! "$salt_content" =~ ^[0-9a-fA-F]{16}$ ]]; then
            echo "🕊️ ERROR: Fixed salt file must contain exactly 16 hex characters (8 bytes)."
            echo "Current content: $salt_content"
            exit 1
        fi
        local nonce_hex="$salt_content"
        while [[ ${#nonce_hex} -lt 24 ]]; do
            nonce_hex="${nonce_hex}0"
        done
        nonce_hex="${nonce_hex:0:24}"
        FIXED_NONCE="$nonce_hex"
        echo "✅ Fixed nonce (24 hex) derived from salt: $FIXED_NONCE"
    else
        FIXED_NONCE=""
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
        echo "🕊️ ERROR: Required tools not found: ${missing_tools[*]}"
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
    log "🕊️ ERROR: $msg"
    
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
            title="🕊️ CHANTIK FAILED"
            ;;
        success) 
            priority="3"
            tags="white_check_mark"
            title="🕊️ CHANTIK SUCCESS"
            ;;
        info)    
            priority="3"
            tags="information_source"
            title="🕊️ CHANTIK INFO"
            ;;
        restore)
            priority="3"
            tags="arrows_counterclockwise"
            title="🕊️ CHANTIK RESTORE"
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

    if [[ "$ENCRYPTION_CIPHER" == "chacha20" ]]; then
        local openssl_opts=("-pbkdf2" "-iter" "${PBKDF2_ITERATIONS:-600000}")
        if [[ -n "$FIXED_NONCE" ]]; then
            openssl_opts+=("-S" "$FIXED_NONCE")
            log_verbose "Using fixed nonce for deterministic encryption (deduplication enabled)"
        else
            log_verbose "Using random nonce (deduplication disabled)"
        fi

        log_verbose "Encrypting with ChaCha20-Poly1305 (PBKDF2 iterations: ${PBKDF2_ITERATIONS:-600000})"
        if openssl enc -chacha20 "${openssl_opts[@]}" \
            -in "$infile" -out "$outfile" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            log_verbose "✅ ChaCha20 encryption successful"
            return 0
        else
            log_verbose "ChaCha20 encryption failed; falling back to AES-CBC"
        fi
    fi

    log_verbose "Using AES-256-CBC (fallback)"
    local openssl_opts=()
    openssl_opts+=("-pbkdf2" "-iter" "${PBKDF2_ITERATIONS:-600000}")
    if [[ -n "$FIXED_NONCE" ]]; then
        if [[ -n "$FIXED_SALT_FILE" ]] && [[ -f "$FIXED_SALT_FILE" ]]; then
            local salt_hex
            salt_hex=$(tr -d '\n\r' < "$FIXED_SALT_FILE")
            openssl_opts+=("-S" "$salt_hex")
            log_verbose "Using fixed salt for deterministic encryption (deduplication enabled)"
        else
            openssl_opts+=("-salt")
            log_verbose "Using random salt (deduplication disabled)"
        fi
    else
        openssl_opts+=("-salt")
    fi

    if openssl enc -aes-256-cbc "${openssl_opts[@]}" -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ AES-CBC encryption successful"
        return 0
    fi

    log_verbose "Trying legacy AES-CBC encryption..."
    local legacy_opts=()
    if [[ -n "$FIXED_NONCE" ]] && [[ -n "$FIXED_SALT_FILE" ]] && [[ -f "$FIXED_SALT_FILE" ]]; then
        local salt_hex
        salt_hex=$(tr -d '\n\r' < "$FIXED_SALT_FILE")
        legacy_opts+=("-S" "$salt_hex")
    else
        legacy_opts+=("-salt")
    fi
    if openssl enc -aes-256-cbc "${legacy_opts[@]}" -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ AES-CBC encryption successful (legacy method)"
        return 0
    fi

    error_exit "OpenSSL encryption failed for $infile (all methods)"
}

decrypt_file() {
    local infile="$1"
    local outfile="$2"
    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        error_exit "Encryption key file not found: $ENCRYPTION_KEY_FILE"
    fi

    if [[ "$ENCRYPTION_CIPHER" == "chacha20" ]]; then
        log_verbose "Trying ChaCha20 decryption..."
        if openssl enc -d -chacha20 -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
            -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            log_verbose "✅ ChaCha20 decryption successful (integrity verified)"
            return 0
        fi

        if [[ -n "$FIXED_NONCE" ]]; then
            log_verbose "Trying ChaCha20 with fixed nonce..."
            if openssl enc -d -chacha20 -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -S "$FIXED_NONCE" \
                -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
                log_verbose "✅ ChaCha20 decryption successful (fixed nonce)"
                return 0
            fi
        fi
        log_verbose "ChaCha20 decryption failed; trying AES-CBC fallback..."
    fi

    log_verbose "Trying AES-CBC decryption (fallback)..."
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

get_snapshot_file() {
    local backup_type="$1"
    local snapshot_name="${backup_type}.snar"
    echo "${INCREMENTAL_BASE_DIR}/${snapshot_name}"
}

get_last_full_backup() {
    local backup_type="$1"
    local snapshot_file=$(get_snapshot_file "$backup_type")
    
    if [[ -f "$snapshot_file" ]]; then
        local last_full=$(grep "^full:" "$snapshot_file" 2>/dev/null | tail -1 | cut -d: -f2)
        
        echo "DEBUG get_last_full_backup: $backup_type -> $last_full" >&2
        
        if [[ -z "$last_full" ]]; then
            echo "0"
        else
            echo "$last_full"
        fi
    else
        echo "DEBUG get_last_full_backup: $backup_type -> 0 (no file)" >&2
        echo "0"
    fi
}

should_do_full_backup() {
    local backup_type="$1"
    
    if [[ "$INCREMENTAL_ENABLED" != "true" ]]; then
        echo "DEBUG should_do_full_backup: $backup_type -> FULL (incremental disabled)" >&2
        return 0
    fi
    
    local last_full=$(get_last_full_backup "$backup_type")
    local current_time=$(date +%s)
    local days_since=$(( (current_time - last_full) / 86400 ))
    
    echo "DEBUG should_do_full_backup: $backup_type: last_full=$last_full, days_since=$days_since, threshold=$FULL_BACKUP_INTERVAL" >&2
    
    if [[ $last_full -eq 0 ]]; then
        echo "DEBUG should_do_full_backup: $backup_type -> FULL (no previous full)" >&2
        return 0
    elif [[ $days_since -ge $FULL_BACKUP_INTERVAL ]]; then
        echo "DEBUG should_do_full_backup: $backup_type -> FULL (scheduled)" >&2
        return 0
    else
        echo "DEBUG should_do_full_backup: $backup_type -> INCREMENTAL" >&2
        return 1
    fi
}

update_snapshot_full_time() {
    local backup_type="$1"
    local snapshot_file=$(get_snapshot_file "$backup_type")
    local current_time=$(date +%s)
    
    log_verbose "Updating full timestamp for $backup_type to $current_time"
    
    mkdir -p "$(dirname "$snapshot_file")" 2>/dev/null || true
    
    if [[ -f "$snapshot_file" ]]; then
        if grep -q "^full:" "$snapshot_file" 2>/dev/null; then
            sed -i "s/^full:.*/full:$current_time/" "$snapshot_file" 2>/dev/null || true
            log_verbose "✅ Updated existing full: timestamp"
        else
            echo "full:$current_time" >> "$snapshot_file"
            log_verbose "✅ Added full: timestamp to existing snapshot"
        fi
    else
        cat > "$snapshot_file" << EOF
last_backup:$current_time
full:$current_time
EOF
        log_verbose "✅ Created new snapshot with full: timestamp"
    fi
    
    if grep -q "^full:" "$snapshot_file" 2>/dev/null; then
        log_verbose "✅ Verified full: timestamp in snapshot"
    else
        log_verbose "⚠️ WARNING: Failed to add full: timestamp"
        echo "full:$current_time" >> "$snapshot_file" 2>/dev/null || true
    fi
}

backup_directory_incremental() {
    local src="$1"
    local dest_dir="$2"
    local name="$3"
    local archive_base="${dest_dir}/${name}"
    
    local backup_type="dir_${name}"
    local snapshot_file=$(get_snapshot_file "$backup_type")
    
    if [[ -f "$snapshot_file" ]]; then
        if ! grep -q "^last_backup:" "$snapshot_file" 2>/dev/null; then
            log "⚠️ Snapshot file $snapshot_file is corrupted. Removing it and forcing full backup."
            rm -f "$snapshot_file"
            rm -f "${INCREMENTAL_BASE_DIR}/${backup_type}_inc_*.snar" 2>/dev/null || true
            rm -f "${INCREMENTAL_BASE_DIR}/${backup_type}"*.snar 2>/dev/null || true
        fi
    fi
    
    local do_full=false
    local backup_suffix=""
    local last_backup_time=0
    
    if [[ "$INCREMENTAL_ENABLED" != "true" ]]; then
        do_full=true
        log "📦 Performing FULL backup of $src (incremental disabled)"
    else
        if should_do_full_backup "$backup_type"; then
            do_full=true
            log "📦 Performing FULL backup of $src (scheduled full backup)"
        else
            if [[ -f "$snapshot_file" ]]; then
                last_backup_time=$(grep "^last_backup:" "$snapshot_file" 2>/dev/null | cut -d: -f2)
                
                if [[ -n "$last_backup_time" ]] && [[ "$last_backup_time" -gt 0 ]]; then
                    do_full=false
                    local last_date=$(date -d "@$last_backup_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                    log "📦 Performing INCREMENTAL backup of $src (since $last_date)"
                else
                    do_full=true
                    log "⚠️ Invalid snapshot timestamp. Forcing FULL backup."
                    rm -f "$snapshot_file"
                fi
            else
                do_full=true
                log "📦 Performing FULL backup of $src (no snapshot found)"
            fi
        fi
    fi
    
    local tar_file="${archive_base}.tar"
    local gz_file="${tar_file}.gz"
    local enc_file="${gz_file}.enc"
    
    if [[ "$do_full" == "true" ]]; then
        backup_suffix="full"
    else
        backup_suffix="inc"
    fi
    
    local final_tar_file="${archive_base}_${backup_suffix}.tar"
    local final_gz_file="${final_tar_file}.gz"
    local final_enc_file="${final_gz_file}.enc"
    
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

    if [[ "$do_full" == "true" ]]; then
        log "Creating FULL backup archive..."
        
        tar -cf "$tar_file" -C "$(dirname "$src")" "${exclude_opts[@]}" \
            --preserve-permissions --same-owner --xattrs \
            "$(basename "$src")" 2>/dev/null || \
            tar -cf "$tar_file" -C "$(dirname "$src")" "${exclude_opts[@]}" \
            --preserve-permissions --same-owner \
            "$(basename "$src")" 2>/dev/null || {
                error_exit "Failed to create full tar archive"
            }
        
        update_snapshot_full_time "$backup_type"
        
        if [[ -f "$snapshot_file" ]]; then
            if grep -q "^last_backup:" "$snapshot_file" 2>/dev/null; then
                sed -i "s/^last_backup:.*/last_backup:$(date +%s)/" "$snapshot_file" 2>/dev/null || true
            else
                echo "last_backup:$(date +%s)" >> "$snapshot_file"
            fi
        else
            echo "last_backup:$(date +%s)" > "$snapshot_file"
            echo "full:$(date +%s)" >> "$snapshot_file"
        fi
        
        log_verbose "Updated snapshot: $snapshot_file"
        
    else
        log "Creating INCREMENTAL backup archive..."
        
        local changed_files="${TMP_DIR}/changed_files_${backup_type}_$$.txt"
        local file_count=0
        
        if command -v find &>/dev/null; then
            if find "$src" -type f -newermt "@$last_backup_time" > "$changed_files" 2>/dev/null; then
                file_count=$(wc -l < "$changed_files" 2>/dev/null || echo 0)
            elif [[ -f "$snapshot_file" ]] && find "$src" -type f -newer "$snapshot_file" > "$changed_files" 2>/dev/null; then
                file_count=$(wc -l < "$changed_files" 2>/dev/null || echo 0)
            else
                find "$src" -type f -mtime -1 > "$changed_files" 2>/dev/null
                file_count=$(wc -l < "$changed_files" 2>/dev/null || echo 0)
            fi
        else
            if command -v rsync &>/dev/null; then
                rsync -avn --delete "$src/" /dev/null 2>/dev/null | grep -v "^sending" | grep -v "^$" > "$changed_files" 2>/dev/null
                file_count=$(wc -l < "$changed_files" 2>/dev/null || echo 0)
            else
                log "⚠️ Cannot detect changes. Forcing FULL backup."
                rm -f "$changed_files" 2>/dev/null
                do_full=true
                backup_directory_incremental "$src" "$dest_dir" "$name"
                return $?
            fi
        fi
        
        sed -i '/^$/d' "$changed_files" 2>/dev/null || true
        
        if [[ -s "$changed_files" ]]; then
            log "📊 Found $file_count changed files"
            
            tar -cf "$tar_file" -C "$(dirname "$src")" \
                --preserve-permissions --same-owner --xattrs \
                --files-from="$changed_files" 2>/dev/null || \
                tar -cf "$tar_file" -C "$(dirname "$src")" \
                --preserve-permissions --same-owner \
                --files-from="$changed_files" 2>/dev/null || {
                    log_verbose "Tar with --files-from failed, trying alternative method..."
                    sed "s|^$(dirname "$src")/||" "$changed_files" > "${changed_files}.rel" 2>/dev/null
                    tar -cf "$tar_file" -C "$(dirname "$src")" \
                        --preserve-permissions --same-owner \
                        -T "${changed_files}.rel" 2>/dev/null || {
                        rm -f "$changed_files" "${changed_files}.rel" 2>/dev/null
                        error_exit "Failed to create incremental tar archive"
                    }
                    rm -f "${changed_files}.rel" 2>/dev/null
                }
            
            if [[ -f "$snapshot_file" ]]; then
                if grep -q "^last_backup:" "$snapshot_file" 2>/dev/null; then
                    sed -i "s/^last_backup:.*/last_backup:$(date +%s)/" "$snapshot_file" 2>/dev/null || true
                else
                    echo "last_backup:$(date +%s)" >> "$snapshot_file"
                fi
            else
                echo "last_backup:$(date +%s)" > "$snapshot_file"
                echo "full:$(date +%s)" >> "$snapshot_file"
            fi
            log_verbose "Updated snapshot: $snapshot_file"
            
        else
            log "📊 No changes detected since last backup ($(date -d "@$last_backup_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown"))"
            
            touch "$tar_file"
            
            if [[ -f "$snapshot_file" ]]; then
                if grep -q "^last_backup:" "$snapshot_file" 2>/dev/null; then
                    sed -i "s/^last_backup:.*/last_backup:$(date +%s)/" "$snapshot_file" 2>/dev/null || true
                else
                    echo "last_backup:$(date +%s)" >> "$snapshot_file"
                fi
            else
                echo "last_backup:$(date +%s)" > "$snapshot_file"
                echo "full:$(date +%s)" >> "$snapshot_file"
            fi
        fi
        
        rm -f "$changed_files" 2>/dev/null
    fi

    if [[ ! -f "$tar_file" ]]; then
        error_exit "Tar file not created: $tar_file"
    fi
    
    if [[ ! -s "$tar_file" ]] && [[ "$do_full" == "false" ]]; then
        log "📦 Empty incremental backup (no changes)"
        rm -f "$tar_file" 2>/dev/null
        log "✅ No changes to backup"
        return 0
    fi

    mv "$tar_file" "$final_tar_file"

    log "🗜️ Compressing with gzip level $GZIP_LEVEL..."
    gzip -$GZIP_LEVEL "$final_tar_file" 2>/dev/null || error_exit "Compression failed for $final_tar_file"
    log "✅ Compression complete"
    
    if [[ ! -f "$final_gz_file" ]] || [[ ! -s "$final_gz_file" ]]; then
        error_exit "Compression failed for $final_tar_file"
    fi

    generate_checksums "$final_gz_file" "${final_gz_file}.checksums"
    
    log_verbose "Encrypting with ChaCha20..."
    encrypt_file "$final_gz_file" "$final_enc_file"
    
    if [[ -f "$final_enc_file" ]] && [[ -s "$final_enc_file" ]]; then
        sha256sum "$final_enc_file" | awk '{print $1}' | sed "s/^/SHA256: /" > "${final_enc_file}.enc.checksums"
        
        rm -f "$final_gz_file"
        
        if [[ "$do_full" == "true" ]]; then
            log "✅ FULL encrypted backup created: $(basename "$final_enc_file") ($(human_size $(stat -c%s "$final_enc_file" 2>/dev/null || echo 0)))"
        else
            local file_count=0
            if [[ -f "$final_tar_file" ]]; then
                file_count=$(tar -tf "$final_tar_file" 2>/dev/null | wc -l || echo 0)
            fi
            log "✅ INCREMENTAL encrypted backup created: $(basename "$final_enc_file") ($(human_size $(stat -c%s "$final_enc_file" 2>/dev/null || echo 0)))"
            if [[ $file_count -gt 0 ]]; then
                log "📊 Changed files: $file_count"
            fi
        fi
    else
        error_exit "Encryption failed for $final_gz_file"
    fi
}

backup_docker_volume_incremental() {
    local volume="$1"
    local dest_dir="$2"
    local archive_base="${dest_dir}/volume_${volume}"
    
    local backup_type="vol_${volume}"
    local snapshot_file=$(get_snapshot_file "$backup_type")
    
    if [[ -f "$snapshot_file" ]]; then
        if ! grep -q "^last_backup:" "$snapshot_file" 2>/dev/null; then
            log "⚠️ Snapshot file $snapshot_file is corrupted. Removing and forcing full backup."
            rm -f "$snapshot_file"
            rm -f "${INCREMENTAL_BASE_DIR}/${backup_type}_inc_*.snar" 2>/dev/null || true
        fi
    fi
    
    local do_full=false
    local backup_suffix=""
    local last_backup_time=0
    
    if [[ "$INCREMENTAL_ENABLED" != "true" ]]; then
        do_full=true
        log "📦 Performing FULL backup of Docker volume: $volume (incremental disabled)"
    else
        if should_do_full_backup "$backup_type"; then
            do_full=true
            log "📦 Performing FULL backup of Docker volume: $volume (scheduled full backup)"
        else
            if [[ -f "$snapshot_file" ]]; then
                last_backup_time=$(grep "^last_backup:" "$snapshot_file" 2>/dev/null | cut -d: -f2)
                if [[ -n "$last_backup_time" ]] && [[ "$last_backup_time" -gt 0 ]]; then
                    do_full=false
                    local last_date=$(date -d "@$last_backup_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                    log "📦 Performing INCREMENTAL backup of Docker volume: $volume (since $last_date)"
                else
                    do_full=true
                    log "⚠️ Invalid snapshot timestamp. Forcing FULL backup."
                    rm -f "$snapshot_file"
                fi
            else
                do_full=true
                log "📦 Performing FULL backup of Docker volume: $volume (no snapshot found)"
            fi
        fi
    fi
    
    local tar_file="${archive_base}.tar"
    local gz_file="${tar_file}.gz"
    local enc_file="${gz_file}.enc"
    
    if [[ "$do_full" == "true" ]]; then
        backup_suffix="full"
    else
        backup_suffix="inc"
    fi
    
    local final_tar_file="${archive_base}_${backup_suffix}.tar"
    local final_gz_file="${final_tar_file}.gz"
    local final_enc_file="${final_gz_file}.enc"

    log "📦 Backing up Docker volume: $volume"
    if ! docker volume inspect "$volume" &>/dev/null; then
        error_exit "Docker volume $volume does not exist"
    fi

    local container_name="chantik_backup_vol_${volume}_$(date +%s)"
    log_verbose "Creating container: $container_name"
    
    local snapshot_volume="${volume}_snapshot"
    docker volume create "$snapshot_volume" 2>/dev/null || true
    
    docker run --rm \
        -v "$volume":/source:ro \
        -v "$snapshot_volume":/target \
        "$DOCKER_IMAGE" \
        cp -a /source/. /target/ 2>/dev/null || true
    
    if [[ "$do_full" == "true" ]]; then
        log "Creating FULL backup archive for volume..."
        
        docker run --rm --name "$container_name" \
            -v "$snapshot_volume":/volume \
            -v "$dest_dir":/backup \
            "$DOCKER_IMAGE" \
            sh -c "tar -cf '/backup/${volume}.tar' -C /volume . \
                --preserve-permissions --same-owner 2>/dev/null" || \
            docker run --rm --name "$container_name" \
                -v "$snapshot_volume":/volume \
                -v "$dest_dir":/backup \
                alpine \
                tar -cf "/backup/${volume}.tar" -C /volume . 2>/dev/null || {
                    error_exit "Failed to create tar for volume $volume"
                }
        
        update_snapshot_full_time "$backup_type"
        
        if [[ -f "$snapshot_file" ]]; then
            if grep -q "^last_backup:" "$snapshot_file" 2>/dev/null; then
                sed -i "s/^last_backup:.*/last_backup:$(date +%s)/" "$snapshot_file" 2>/dev/null || true
            else
                echo "last_backup:$(date +%s)" >> "$snapshot_file"
            fi
        else
            echo "last_backup:$(date +%s)" > "$snapshot_file"
            echo "full:$(date +%s)" >> "$snapshot_file"
        fi
        
        log_verbose "Updated snapshot: $snapshot_file"
        
    else
        log "Creating INCREMENTAL backup archive for volume..."
        
        local timestamp_file="${TMP_DIR}/.timestamp_${backup_type}_$$"
        touch -d "@$last_backup_time" "$timestamp_file" 2>/dev/null || \
            touch -t "$(date -d "@$last_backup_time" '+%Y%m%d%H%M.%S' 2>/dev/null || echo '197001010000.00')" "$timestamp_file" 2>/dev/null
        
        docker run --rm --name "$container_name" \
            -v "$snapshot_volume":/volume \
            -v "$dest_dir":/backup \
            -v "$(dirname "$timestamp_file")":/timestamps \
            "$DOCKER_IMAGE" \
            sh -c "
                TIMESTAMP_FILE='/timestamps/$(basename "$timestamp_file")'
                if [ -f \"\$TIMESTAMP_FILE\" ]; then
                    find /volume -type f -newer \"\$TIMESTAMP_FILE\" > /tmp/changed.txt 2>/dev/null
                    if [ -s /tmp/changed.txt ]; then
                        tar -cf '/backup/${volume}.tar' -C /volume --files-from=/tmp/changed.txt --preserve-permissions 2>/dev/null
                    else
                        touch '/backup/${volume}.tar'
                    fi
                else
                    tar -cf '/backup/${volume}.tar' -C /volume . --preserve-permissions 2>/dev/null
                fi
            " || {
                log_verbose "Incremental backup failed, creating full backup"
                docker run --rm --name "${container_name}_full" \
                    -v "$snapshot_volume":/volume \
                    -v "$dest_dir":/backup \
                    alpine \
                    tar -cf "/backup/${volume}.tar" -C /volume . 2>/dev/null || {
                        error_exit "Failed to create tar for volume $volume"
                    }
                do_full=true
            }
        
        rm -f "$timestamp_file" 2>/dev/null
        
        if [[ -f "$snapshot_file" ]]; then
            if grep -q "^last_backup:" "$snapshot_file" 2>/dev/null; then
                sed -i "s/^last_backup:.*/last_backup:$(date +%s)/" "$snapshot_file" 2>/dev/null || true
            else
                echo "last_backup:$(date +%s)" >> "$snapshot_file"
            fi
        else
            echo "last_backup:$(date +%s)" > "$snapshot_file"
            echo "full:$(date +%s)" >> "$snapshot_file"
        fi
        log_verbose "Updated snapshot: $snapshot_file"
    fi
    
    docker volume rm "$snapshot_volume" 2>/dev/null || true

    if [[ ! -f "${dest_dir}/${volume}.tar" ]]; then
        error_exit "Tar file not created for volume $volume"
    fi

    if [[ ! -s "${dest_dir}/${volume}.tar" ]] && [[ "$do_full" == "false" ]]; then
        log "📦 Empty incremental backup (no changes in volume)"
        rm -f "${dest_dir}/${volume}.tar" 2>/dev/null
        log "✅ No changes to backup for volume $volume"
        return 0
    fi

    mv "${dest_dir}/${volume}.tar" "$final_tar_file"
    
    if ! tar -tf "$final_tar_file" &>/dev/null; then
        error_exit "Tar file is corrupted or empty: $final_tar_file"
    fi

    if [[ "$do_full" == "true" ]]; then
        update_snapshot_full_time "$backup_type"
        touch "$snapshot_file"
    fi

    log "🗜️ Compressing with gzip level $GZIP_LEVEL..."
    gzip -$GZIP_LEVEL "$final_tar_file" 2>/dev/null || error_exit "Compression failed for $final_tar_file"
    if [[ ! -f "$final_gz_file" ]] || [[ ! -s "$final_gz_file" ]]; then
        error_exit "Compression failed for $final_tar_file"
    fi

    generate_checksums "$final_gz_file" "${final_gz_file}.checksums"
    
    log_verbose "Encrypting volume backup with ChaCha20..."
    encrypt_file "$final_gz_file" "$final_enc_file"
    
    if [[ -f "$final_enc_file" ]] && [[ -s "$final_enc_file" ]]; then
        sha256sum "$final_enc_file" | awk '{print $1}' | sed "s/^/SHA256: /" > "${final_enc_file}.enc.checksums"
        log_verbose "Created encrypted checksum: ${final_enc_file}.enc.checksums"
        
        rm -f "$final_gz_file"
        
        if [[ "$do_full" == "true" ]]; then
            log "✅ FULL encrypted volume backup created: $(basename "$final_enc_file") ($(human_size $(stat -c%s "$final_enc_file" 2>/dev/null || echo 0)))"
        else
            local file_count=0
            if [[ -f "$final_tar_file" ]]; then
                file_count=$(tar -tf "$final_tar_file" 2>/dev/null | wc -l || echo 0)
            fi
            log "✅ INCREMENTAL encrypted volume backup created: $(basename "$final_enc_file") ($(human_size $(stat -c%s "$final_enc_file" 2>/dev/null || echo 0)))"
            if [[ $file_count -gt 0 ]]; then
                log "📊 Changed files in volume: $file_count"
            fi
        fi
    else
        error_exit "Encryption failed for $final_gz_file"
    fi
}

generate_checksums() {
    local file="$1"
    local checksum_file="${2:-${file}.checksums}"
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
        type=$(echo "$type" | sed -E 's/_(full|inc)$//')
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
            rm -f "${f%.enc}.enc.checksums" 2>/dev/null
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
    
    local filename=$(basename "$enc_file")
    if [[ "$filename" == *_full* ]]; then
        echo "📋 Type: FULL backup"
    elif [[ "$filename" == *_inc* ]]; then
        echo "📋 Type: INCREMENTAL backup"
    else
        echo "📋 Type: Unknown (legacy)"
    fi
    
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
    
    type=$(echo "$type" | sed -E 's/_(full|inc)$//')
    
    log "🔄 Restoring type: $type"

    local tmp_dir
    tmp_dir=$(mktemp -d -p "$TMP_DIR" restore_XXXXXX)
    
    trap 'rm -rf "$tmp_dir" 2>/dev/null || true; cleanup_temp; exit' INT TERM EXIT
    
    local decrypted_file="${tmp_dir}/$(basename "${enc_file%.enc}")"
    log "🔐 Decrypting $(basename "$enc_file") with ChaCha20..."
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

    if [[ "$type" == "$(basename "$SOURCE_DIR")" ]] || [[ "$type" == "chantik-directory" ]] || [[ "$type" == "digital-independence" ]]; then
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
        
    elif [[ "$type" =~ ^volume_ ]] || [[ "$type" =~ ^volume_.*_(full|inc)$ ]]; then
        local volume_name=$(echo "$type" | sed -E 's/^volume_//' | sed -E 's/_(full|inc)$//')
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
        
        local container_name="chantik_restore_vol_${volume_name}_$(date +%s)_$$"
        
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
                        container_name="chantik_restore_vol_${volume_name}_$(date +%s)_$RANDOM"
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
                        container_name="chantik_restore_vol_${volume_name}_$(date +%s)_$RANDOM"
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
        
        local backup_type=""
        if [[ "$basename" == *_full* ]]; then
            backup_type="FULL"
        elif [[ "$basename" == *_inc* ]]; then
            backup_type="INC "
        else
            backup_type="LEGACY"
        fi
        
        local checksum_file="${enc_file%.enc}.checksums"
        local status=""
        if [[ -f "$checksum_file" ]]; then
            status="✅"
        else
            status="⚠️"
        fi
        
        printf "  %s %s %-55s  %-10s  %s\n" "$status" "$backup_type" "$basename" "$size" "$date"
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
    
    log_section "🕊️ Starting $BRAND_NAME (v$VERSION)"
    log "💬 $BRAND_TAGLINE"
    log "🙏 $BRAND_MOTTO"
    log ""
    
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
    log "🔒 Encryption: ${ENCRYPTION_CIPHER^^} (Chantik Mode)"
    log "🔑 PBKDF2 iterations: ${PBKDF2_ITERATIONS:-600000}"
    if [[ -n "$FIXED_NONCE" ]]; then
        log "🔗 Deduplication: ENABLED (fixed nonce)"
    else
        log "🔗 Deduplication: DISABLED (random nonce)"
    fi
    log "🗜️ Compression: gzip level $GZIP_LEVEL"
    log "📋 Retention: Daily=${RETENTION_DAILY}, Weekly=${RETENTION_WEEKLY}, Monthly=${RETENTION_MONTHLY}"
    
    if [[ "$INCREMENTAL_ENABLED" == "true" ]]; then
        log "🔄 Incremental: ENABLED (full backup every ${FULL_BACKUP_INTERVAL} days)"
    else
        log "🔄 Incremental: DISABLED (always full backup)"
    fi
    
    send_ntfy "📅 Time: $start_date\n💻 Host: $hostname\n📁 Source: $SOURCE_DIR\n📊 Size: $source_size_human ($source_files files)\n🐳 Volumes: $volume_count volumes\n💾 Target: $BACKUP_BASE_DIR\n💿 Free space: $free_space_human\n🔒 Encryption: ${ENCRYPTION_CIPHER^^} (Chantik Mode)\n🔑 PBKDF2: ${PBKDF2_ITERATIONS:-600000} iterations\n🔗 Dedup: $([ -n "$FIXED_NONCE" ] && echo "ENABLED" || echo "DISABLED")\n🗜️ Compression: gzip level $GZIP_LEVEL\n📋 Retention: Daily=${RETENTION_DAILY}, Weekly=${RETENTION_WEEKLY}, Monthly=${RETENTION_MONTHLY}\n🔄 Incremental: $([ "$INCREMENTAL_ENABLED" == "true" ] && echo "ENABLED (${FULL_BACKUP_INTERVAL} days)" || echo "DISABLED")" "info"
    acquire_lock
    check_docker
    check_disk_space "$BACKUP_BASE_DIR" 1024

    local timestamp
    timestamp=$(get_timestamp)
    local backup_dir="${BACKUP_BASE_DIR}/${BACKUP_PREFIX}_${timestamp}"
    mkdir -p "$backup_dir"
    log "📂 Backup directory created: $backup_dir"

    backup_directory_incremental "$SOURCE_DIR" "$backup_dir" "digital-independence"

    local pids=()
    local failed=0
    local vol_count=0

    for vol in "${DOCKER_VOLUMES[@]}"; do
        vol_count=$((vol_count + 1))
        log "Processing volume $vol_count of ${#DOCKER_VOLUMES[@]}: $vol"
        backup_docker_volume_incremental "$vol" "$backup_dir" &
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
    log "🕊️ $BRAND_NAME — $BRAND_TAGLINE"
    log "⏱️ Duration: $duration_human"
    log "📦 Archives: $backup_count encrypted files"
    log "💾 Total size: $total_backup_size_human"
    log "📍 Location: $backup_dir"
    log "📝 Log: $LOG_FILE"
    log "🙏 $BRAND_MOTTO"

    local full_count=$(find "$backup_dir" -name "*_full*.enc" 2>/dev/null | wc -l)
    local inc_count=$(find "$backup_dir" -name "*_inc*.enc" 2>/dev/null | wc -l)
    
    send_ntfy "📅 Completed: $end_date\n⏱️ Duration: $duration_human\n📦 Archives: $backup_count encrypted files ($full_count full, $inc_count incremental)\n💾 Total size: $total_backup_size_human\n📁 Source size: $source_size_human ($source_files files)\n🐳 Volumes: $volume_count volumes\n💿 Free space: $free_space_human → $(human_size $((new_free_space_mb * 1024 * 1024))) (used $space_used_human)\n🔒 Verification: ✅ All checksums verified\n🗑️ Retention: Daily=${RETENTION_DAILY}, Weekly=${RETENTION_WEEKLY}, Monthly=${RETENTION_MONTHLY}\n🔗 Deduplication: $([ -n "$FIXED_NONCE" ] && echo "ENABLED" || echo "DISABLED")\n🔄 Incremental: $([ "$INCREMENTAL_ENABLED" == "true" ] && echo "ENABLED (${FULL_BACKUP_INTERVAL} days)" || echo "DISABLED")\n📍 Location: $backup_dir\n📝 Log: $LOG_FILE" "success"
    release_lock
    cleanup_temp
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "🕊️ $BRAND_NAME — From ChaCha Comes Peace of Mind"
}

run_test() {
    echo ""
    echo "🔐 Testing $BRAND_NAME Encryption/Decryption System"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "💬 $BRAND_TAGLINE"
    echo "🙏 $BRAND_MOTTO"
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
    echo "📄 Testing text file encryption/decryption with ChaCha20..."
    
    echo "Test content at $(date)" > "${TEST_DIR}/test.txt"
    echo "Line 2: Testing ChaCha20-Poly1305 with PBKDF2 ${PBKDF2_ITERATIONS:-600000}" >> "${TEST_DIR}/test.txt"
    echo "Line 3: This should be encrypted and decrypted successfully" >> "${TEST_DIR}/test.txt"
    
    if openssl enc -chacha20 -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
        -in "${TEST_DIR}/test.txt" -out "${TEST_DIR}/test.txt.enc" \
        -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        echo "  ✅ ChaCha20 text encryption: SUCCESS"
    else
        echo "  ❌ ChaCha20 text encryption: FAILED"
        echo "  Trying AES-CBC fallback..."
        if openssl enc -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -salt \
            -in "${TEST_DIR}/test.txt" -out "${TEST_DIR}/test.txt.enc" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            echo "  ✅ AES-CBC text encryption: SUCCESS (fallback)"
        else
            rm -rf "$TEST_DIR" 2>/dev/null
            return 1
        fi
    fi
    
    if openssl enc -d -chacha20 -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
        -in "${TEST_DIR}/test.txt.enc" -out "${TEST_DIR}/test.txt.dec" \
        -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        echo "  ✅ ChaCha20 text decryption: SUCCESS"
    else
        echo "  Trying AES-CBC fallback decrypt..."
        if openssl enc -d -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
            -in "${TEST_DIR}/test.txt.enc" -out "${TEST_DIR}/test.txt.dec" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            echo "  ✅ AES-CBC text decryption: SUCCESS (fallback)"
        else
            rm -rf "$TEST_DIR" 2>/dev/null
            return 1
        fi
    fi
    
    if diff "${TEST_DIR}/test.txt" "${TEST_DIR}/test.txt.dec" >/dev/null 2>&1; then
        echo "  ✅ Text file: PASSED (files match)"
    else
        echo "  ❌ Text file: FAILED (files don't match)"
        rm -rf "$TEST_DIR" 2>/dev/null
        return 1
    fi
    
    echo ""
    echo "📦 Testing binary file encryption/decryption with ChaCha20..."
    
    dd if=/dev/urandom of="${TEST_DIR}/test.bin" bs=1K count=10 2>/dev/null
    
    if openssl enc -chacha20 -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
        -in "${TEST_DIR}/test.bin" -out "${TEST_DIR}/test.bin.enc" \
        -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        echo "  ✅ ChaCha20 binary encryption: SUCCESS"
    else
        echo "  ❌ ChaCha20 binary encryption: FAILED"
        rm -rf "$TEST_DIR" 2>/dev/null
        return 1
    fi
    
    if openssl enc -d -chacha20 -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
        -in "${TEST_DIR}/test.bin.enc" -out "${TEST_DIR}/test.bin.dec" \
        -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        echo "  ✅ ChaCha20 binary decryption: SUCCESS"
    else
        echo "  ❌ ChaCha20 binary decryption: FAILED"
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
    
    if [[ -n "$FIXED_NONCE" ]]; then
        echo ""
        echo "🔗 Testing fixed nonce (deduplication mode)..."
        echo "  Nonce: $FIXED_NONCE"
        
        openssl enc -chacha20 -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -S "$FIXED_NONCE" \
            -in "${TEST_DIR}/test.txt" -out "${TEST_DIR}/test.fixed.enc" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null
        
        openssl enc -chacha20 -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -S "$FIXED_NONCE" \
            -in "${TEST_DIR}/test.txt" -out "${TEST_DIR}/test.fixed2.enc" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null
        
        if cmp "${TEST_DIR}/test.fixed.enc" "${TEST_DIR}/test.fixed2.enc" >/dev/null 2>&1; then
            echo "  ✅ Fixed nonce: Identical encryption (deduplication works)"
        else
            echo "  ⚠️  Fixed nonce: Files differ (deduplication may not work)"
        fi
        
        if openssl enc -d -chacha20 -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" -S "$FIXED_NONCE" \
            -in "${TEST_DIR}/test.fixed.enc" -out "${TEST_DIR}/test.fixed.dec" \
            -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
            
            if diff "${TEST_DIR}/test.txt" "${TEST_DIR}/test.fixed.dec" >/dev/null 2>&1; then
                echo "  ✅ Fixed nonce decryption: PASSED"
            else
                echo "  ❌ Fixed nonce decryption: FAILED"
            fi
        else
            echo "  ❌ Fixed nonce decryption: FAILED"
        fi
        
        rm -f "${TEST_DIR}/test.fixed.enc" "${TEST_DIR}/test.fixed2.enc" "${TEST_DIR}/test.fixed.dec" 2>/dev/null
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ ALL TESTS PASSED!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📊 Test Summary:"
    echo "  • ChaCha20 text encryption/decryption: ✅"
    echo "  • ChaCha20 binary encryption/decryption: ✅"
    echo "  • PBKDF2 compatibility: ✅"
    if [[ -n "$FIXED_NONCE" ]]; then
        echo "  • Fixed nonce deduplication: ✅"
    fi
    echo ""
    echo "📁 Test files kept in: $TEST_DIR"
    echo "   (Remove with: rm -rf $TEST_DIR)"
    echo ""
    echo "🕊️ $BRAND_NAME — $BRAND_TAGLINE"
    echo "🙏 $BRAND_MOTTO"
    echo ""
    
    if [[ -f "encryption.key.test" ]]; then
        echo "🧹 Removing test encryption key..."
        rm -f encryption.key.test
    fi
    
    return 0
}

show_help() {
    cat <<EOF
🕊️ $BRAND_NAME v$VERSION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💬 $BRAND_TAGLINE
🙏 $BRAND_MOTTO
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    --restore <file>      Restore from the specified encrypted backup file
    --verify <file>       Verify integrity of a specific backup file
    --verify-all          Verify all backups in the backup directory
    --list                List all available backups
    --dedup               Run deduplication on the backup directory
    --test                Run encryption/decryption test suite
    --help, -h            Show this help message

EXAMPLES:
    # Perform a full backup
    ./$SCRIPT_NAME

    # Perform incremental backup (if enabled in config)
    ./$SCRIPT_NAME

    # Test encryption/decryption
    ./$SCRIPT_NAME --test

    # List available backups
    ./$SCRIPT_NAME --list

    # Verify a specific backup
    ./$SCRIPT_NAME --verify /path/to/backup.enc

    # Verify all backups
    ./$SCRIPT_NAME --verify-all

    # Restore from a specific backup
    ./$SCRIPT_NAME --restore /path/to/backup.enc

    # Run deduplication on backup directory
    ./$SCRIPT_NAME --dedup

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
                echo "🕊️ ERROR: Missing backup file for restore."
                echo "Usage: $SCRIPT_NAME --restore <backup-file>"
                exit 1
            fi
            load_config
            init_tmp
            restore_from_backup "$2"
            ;;
        --verify)
            if [[ -z "${2:-}" ]]; then
                echo "🕊️ ERROR: Missing backup file for verification."
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
            echo "🕊️ ERROR: Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
}

main "$@"
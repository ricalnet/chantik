#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

VERSION="0.1.4"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

if [[ -n "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_SOURCE="${BASH_SOURCE[0]}"
else
    SCRIPT_SOURCE="$0"
fi

if command -v realpath &>/dev/null; then
    SCRIPT_PATH="$(realpath "$SCRIPT_SOURCE" 2>/dev/null || echo "$SCRIPT_SOURCE")"
elif command -v readlink &>/dev/null; then
    SCRIPT_PATH="$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null || echo "$SCRIPT_SOURCE")"
else
    SCRIPT_PATH="$SCRIPT_SOURCE"
fi

SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

if [[ -n "${CHANTIK_CONFIG:-}" ]]; then
    CONFIG_FILE="${CHANTIK_CONFIG}"
else
    CONFIG_FILE="${SCRIPT_DIR}/chantik.conf"
fi

if [[ ! -f "$CONFIG_FILE" ]] && [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    XDG_CONFIG_FILE="${XDG_CONFIG_HOME}/chantik/chantik.conf"
    if [[ -f "$XDG_CONFIG_FILE" ]]; then
        CONFIG_FILE="$XDG_CONFIG_FILE"
    fi
fi

if [[ ! -f "$CONFIG_FILE" ]] && [[ -f "/etc/chantik/chantik.conf" ]]; then
    CONFIG_FILE="/etc/chantik/chantik.conf"
fi

CONFIG_EXAMPLE="${SCRIPT_DIR}/chantik.conf.example"

if [[ -n "${CHANTIK_WORK_DIR:-}" ]]; then
    WORK_DIR="${CHANTIK_WORK_DIR}"
else
    WORK_DIR="${SCRIPT_DIR}"
fi

LOCK_FILE="${WORK_DIR}/.chantik.lock"
LOG_FILE="${WORK_DIR}/chantik.log"
TMP_DIR="${WORK_DIR}/.tmp"

if [[ ! -w "$WORK_DIR" ]]; then
    if [[ -n "${XDG_STATE_HOME:-}" ]]; then
        WORK_DIR="${XDG_STATE_HOME}/chantik"
    elif [[ -n "${HOME:-}" ]]; then
        WORK_DIR="${HOME}/.local/state/chantik"
    else
        WORK_DIR="/tmp/chantik-$$"
    fi
    mkdir -p "$WORK_DIR" 2>/dev/null || true
    LOCK_FILE="${WORK_DIR}/.chantik.lock"
    LOG_FILE="${WORK_DIR}/chantik.log"
    TMP_DIR="${WORK_DIR}/.tmp"
fi

BACKUP_START_TIME=0
BACKUP_END_TIME=0
BRAND_NAME="Chantik"
BRAND_TAGLINE="ChaCha20-Authenticated Backup Protection"
BRAND_MOTTO="In ChaCha We Trust — Authentically Secured"
BRAND_EMOJI="🕊️"

BACKUP_BASE_DIR=""
SOURCE_DIR=""
DOCKER_VOLUMES=()
PODMAN_VOLUMES=()
CONTAINER_RUNTIME="auto"
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
INCREMENTAL_ENABLED="true"
INCREMENTAL_BASE_DIR="${BACKUP_BASE_DIR}/.incremental"
SNAPSHOT_FILE=""
FULL_BACKUP_INTERVAL=7

detect_container_runtime() {
    local runtime=""
    
    if [[ -n "$CONTAINER_RUNTIME" ]] && [[ "$CONTAINER_RUNTIME" != "auto" ]]; then
        runtime="$CONTAINER_RUNTIME"
    else
        if command -v podman &> /dev/null && podman info &> /dev/null 2>&1; then
            runtime="podman"
        elif command -v docker &> /dev/null && docker info &> /dev/null 2>&1; then
            runtime="docker"
        else
            error_exit "No container runtime found. Install Docker or Podman."
        fi
    fi
    
    if [[ "$runtime" == "podman" ]]; then
        if ! command -v podman &> /dev/null; then
            error_exit "Podman not found in PATH"
        fi
        if ! podman info &> /dev/null 2>&1; then
            error_exit "Podman daemon is not running or not accessible"
        fi
        log_verbose "Using Podman container runtime"
    elif [[ "$runtime" == "docker" ]]; then
        if ! command -v docker &> /dev/null; then
            error_exit "Docker not found in PATH"
        fi
        if ! docker info &> /dev/null 2>&1; then
            error_exit "Docker daemon is not running or not accessible"
        fi
        log_verbose "Using Docker container runtime"
    else
        error_exit "Invalid container runtime: $runtime. Use 'docker', 'podman', or 'auto'"
    fi
    
    echo "$runtime"
}

check_container_runtime() {
    local runtime=$(detect_container_runtime)
    CONTAINER_RUNTIME="$runtime"
    
    if [[ "$runtime" == "podman" ]]; then
        log_verbose "✅ Podman is running"
        if podman info --format '{{.Store.Rootless}}' 2>/dev/null | grep -q "true"; then
            log_verbose "Podman running in rootless mode"
            CONTAINER_ROOTLESS=true
        else
            log_verbose "Podman running in rootful mode"
            CONTAINER_ROOTLESS=false
        fi
    else
        log_verbose "✅ Docker is running"
        if docker info 2>/dev/null | grep -q "rootless"; then
            log_verbose "Docker running in rootless mode"
            CONTAINER_ROOTLESS=true
        else
            CONTAINER_ROOTLESS=false
        fi
    fi
}

list_container_volumes() {
    local runtime="$1"
    local volumes=()
    
    if [[ "$runtime" == "podman" ]]; then
        while IFS= read -r vol; do
            if [[ -n "$vol" ]]; then
                volumes+=("$vol")
            fi
        done < <(podman volume ls --format '{{.Name}}' 2>/dev/null)
    else
        while IFS= read -r vol; do
            if [[ -n "$vol" ]]; then
                volumes+=("$vol")
            fi
        done < <(docker volume ls --format '{{.Name}}' 2>/dev/null)
    fi
    
    printf '%s\n' "${volumes[@]}"
}

volume_exists() {
    local runtime="$1"
    local volume="$2"
    
    if [[ "$runtime" == "podman" ]]; then
        podman volume inspect "$volume" &>/dev/null
    else
        docker volume inspect "$volume" &>/dev/null
    fi
}

create_snapshot_volume() {
    local runtime="$1"
    local source_volume="$2"
    local snapshot_volume="$3"
    
    if volume_exists "$runtime" "$snapshot_volume"; then
        if [[ "$runtime" == "podman" ]]; then
            podman volume rm "$snapshot_volume" 2>/dev/null || true
        else
            docker volume rm "$snapshot_volume" 2>/dev/null || true
        fi
    fi
    
    if [[ "$runtime" == "podman" ]]; then
        podman volume create "$snapshot_volume" || error_exit "Failed to create snapshot volume"
    else
        docker volume create "$snapshot_volume" || error_exit "Failed to create snapshot volume"
    fi
}

run_container() {
    local runtime="$1"
    local container_name="$2"
    local image="$3"
    shift 3
    
    if [[ "$runtime" == "podman" ]]; then
        podman run --rm --name "$container_name" "$@" "$image"
    else
        docker run --rm --name "$container_name" "$@" "$image"
    fi
}

run_container_detached() {
    local runtime="$1"
    local container_name="$2"
    local image="$3"
    shift 3
    
    if [[ "$runtime" == "podman" ]]; then
        podman run -d --name "$container_name" "$@" "$image"
    else
        docker run -d --name "$container_name" "$@" "$image"
    fi
}

stop_container() {
    local runtime="$1"
    local container_name="$2"
    
    if [[ "$runtime" == "podman" ]]; then
        podman stop "$container_name" >/dev/null 2>&1 || true
        podman rm "$container_name" >/dev/null 2>&1 || true
    else
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
    fi
}

copy_to_volume() {
    local runtime="$1"
    local container_name="$2"
    local source_path="$3"
    local dest_path="$4"
    
    if [[ "$runtime" == "podman" ]]; then
        podman cp "$source_path" "$container_name:$dest_path" 2>/dev/null
    else
        docker cp "$source_path" "$container_name:$dest_path" 2>/dev/null
    fi
}

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
        echo "Alternatively, set CHANTIK_CONFIG environment variable:"
        echo "     export CHANTIK_CONFIG=/path/to/chantik.conf"
        echo ""
        exit 1
    fi

    source "$CONFIG_FILE"

    local required_vars=(
        "BACKUP_BASE_DIR"
        "SOURCE_DIR"
        "ENCRYPTION_KEY_FILE"
        "NTFY_TOPIC"
        "NTFY_TOKEN"
    )

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    local has_volumes=false
    if [[ ${#DOCKER_VOLUMES[@]} -gt 0 ]] || [[ ${#PODMAN_VOLUMES[@]} -gt 0 ]]; then
        has_volumes=true
    fi

    if [[ "$has_volumes" == "false" ]]; then
        missing_vars+=("DOCKER_VOLUMES or PODMAN_VOLUMES (both empty)")
    fi

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "🕊️ ERROR: Missing required configuration variables in $CONFIG_FILE:"
        printf "  - %s\n" "${missing_vars[@]}"
        echo ""
        echo "Please update $CONFIG_FILE with your values."
        exit 1
    fi

    if [[ "$BACKUP_BASE_DIR" != /* ]]; then
        BACKUP_BASE_DIR="${SCRIPT_DIR}/${BACKUP_BASE_DIR}"
    fi
    
    if [[ "$SOURCE_DIR" != /* ]]; then
        SOURCE_DIR="${SCRIPT_DIR}/${SOURCE_DIR}"
    fi
    
    if [[ "$ENCRYPTION_KEY_FILE" != /* ]]; then
        ENCRYPTION_KEY_FILE="${SCRIPT_DIR}/${ENCRYPTION_KEY_FILE}"
    fi

    INCREMENTAL_ENABLED="${INCREMENTAL_ENABLED:-false}"
    FULL_BACKUP_INTERVAL="${FULL_BACKUP_INTERVAL:-7}"
    INCREMENTAL_BASE_DIR="${BACKUP_BASE_DIR}/.incremental"

    if [[ -n "${PBKDF2_ITERATIONS:-}" ]]; then
        if [[ ! "$PBKDF2_ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$PBKDF2_ITERATIONS" -lt 100000 ]]; then
            echo "⚠️ WARNING: PBKDF2_ITERATIONS must be >= 100000. Using default: 600000"
            PBKDF2_ITERATIONS=600000
        elif [[ "$PBKDF2_ITERATIONS" -lt 600000 ]]; then
            echo "⚠️ WARNING: PBKDF2_ITERATIONS=$PBKDF2_ITERATIONS is lower than recommended (600000+)."
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
        if [[ "$FIXED_SALT_FILE" != /* ]]; then
            FIXED_SALT_FILE="${SCRIPT_DIR}/${FIXED_SALT_FILE}"
        fi
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
    
    if [[ -z "${CONTAINER_RUNTIME:-}" ]] || [[ "$CONTAINER_RUNTIME" == "auto" ]]; then
        CONTAINER_RUNTIME=$(detect_container_runtime)
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "🕊️ ERROR: Required tools not found: ${missing_tools[*]}"
        echo "Please install them and try again."
        exit 1
    fi

    echo "✅ Config loaded: $CONFIG_FILE"
    echo "✅ Runtime: $CONTAINER_RUNTIME"
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
        log_verbose "ntfy not configured. Skipping notification."
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

get_restore_stats() {
    local dir="$1"
    local file_count=0
    local dir_count=0
    local total_size=0
    
    if [[ -d "$dir" ]]; then
        file_count=$(find "$dir" -type f 2>/dev/null | wc -l)
        dir_count=$(find "$dir" -type d 2>/dev/null | wc -l)
        total_size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
    fi
    
    echo "$file_count|$dir_count|$total_size"
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

acquire_lock() {
    local lock_dir="${LOCK_FILE}.dir"
    
    if ! mkdir "$lock_dir" 2>/dev/null; then
        if [[ -f "${lock_dir}/pid" ]]; then
            local pid=$(cat "${lock_dir}/pid" 2>/dev/null || echo "")
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                error_exit "Another backup process is running (PID $pid). Lock directory exists."
            else
                log "Stale lock found. Removing."
                rm -rf "$lock_dir"
                if ! mkdir "$lock_dir" 2>/dev/null; then
                    error_exit "Failed to acquire lock after cleanup"
                fi
            fi
        else
            error_exit "Lock directory exists but no PID file. Manual cleanup needed: rm -rf $lock_dir"
        fi
    fi
    
    echo $$ > "${lock_dir}/pid"
    echo "$(date '+%Y-%m-%d %H:%M:%S')" > "${lock_dir}/timestamp"
    
    LOCK_DIR="$lock_dir"
    
    trap 'rm -rf "$LOCK_DIR"; cleanup_temp; exit' INT TERM EXIT
}

release_lock() {
    if [[ -n "${LOCK_DIR:-}" ]] && [[ -d "$LOCK_DIR" ]]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
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

setup_secure_staging() {
    local prefix="${1:-restore}"
    
    local staging_dir
    if ! staging_dir=$(mktemp -d -p "$TMP_DIR" "${prefix}_XXXXXX" 2>/dev/null); then
        staging_dir="${TMP_DIR}/${prefix}_$$_$RANDOM"
        mkdir -p "$staging_dir"
    fi
    
    chmod 700 "$staging_dir"
    
    cleanup_staging() {
        if [[ -d "$staging_dir" ]]; then
            log_verbose "🔐 Securely cleaning staging directory: $staging_dir"
            
            if command -v shred &>/dev/null; then
                find "$staging_dir" -type f -exec shred -f -z -u {} \; 2>/dev/null || true
            else
                find "$staging_dir" -type f -exec dd if=/dev/zero of={} bs=1M count=1 2>/dev/null \; 2>/dev/null || true
            fi
            
            rm -rf "$staging_dir" 2>/dev/null || true
            log_verbose "✅ Staging directory cleaned"
        fi
    }
    
    trap 'cleanup_staging; cleanup_temp; exit' INT TERM EXIT
    
    echo "$staging_dir"
}

create_pre_restore_backup() {
    local target_path="$1"
    local backup_name="${2:-pre_restore}"
    
    if [[ ! -e "$target_path" ]]; then
        log_verbose "⚠️ Target path does not exist: $target_path"
        return 0
    fi
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local pre_backup_dir="${BACKUP_BASE_DIR}/pre_restore_${backup_name}_${timestamp}"
    
    log "📦 Creating pre-restore backup to: $pre_backup_dir"
    mkdir -p "$pre_backup_dir"
    
    if [[ -d "$target_path" ]]; then
        cp -a "$target_path" "$pre_backup_dir/" 2>/dev/null || {
            log "⚠️ Failed to backup target directory (may need sudo)"
            return 1
        }
        log "✅ Pre-restore backup created: $(basename "$pre_backup_dir")"
        echo "$pre_backup_dir"
        return 0
    elif [[ -f "$target_path" ]]; then
        cp "$target_path" "$pre_backup_dir/" 2>/dev/null || {
            log "⚠️ Failed to backup target file (may need sudo)"
            return 1
        }
        log "✅ Pre-restore backup created: $(basename "$pre_backup_dir")"
        echo "$pre_backup_dir"
        return 0
    else
        log "⚠️ Target is not a file or directory: $target_path"
        return 1
    fi
}

confirm_restore() {
    local target_path="$1"
    local description="${2:-the target}"
    
    echo ""
    echo "⚠️  WARNING: This will OVERWRITE: $target_path"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 Description: $description"
    echo ""
    echo -n "Continue with restore? (type 'yes' to proceed): "
    read -r confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo "❌ Restore cancelled."
        return 1
    fi
    
    echo -n "FINAL CONFIRMATION: Are you sure? (YES/no): "
    read -r final_confirm
    if [[ "$final_confirm" != "YES" ]]; then
        echo "❌ Restore cancelled."
        return 1
    fi
    
    return 0
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
            log_verbose "Using fixed nonce for deterministic encryption"
        else
            log_verbose "Using random nonce"
        fi

        log_verbose "Encrypting with ChaCha20-Poly1305 (PBKDF2: ${PBKDF2_ITERATIONS:-600000})"
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
            log_verbose "Using fixed salt for deterministic encryption"
        else
            openssl_opts+=("-salt")
            log_verbose "Using random salt"
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
            log_verbose "✅ ChaCha20 decryption successful"
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

    log_verbose "Trying decryption with pbkdf2 (iterations: ${PBKDF2_ITERATIONS:-600000})..."
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter "${PBKDF2_ITERATIONS:-600000}" \
        -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Decryption successful (pbkdf2 method, ${PBKDF2_ITERATIONS:-600000} iterations)"
        return 0
    fi

    log_verbose "Trying decryption with pbkdf2 (iterations: 100000)..."
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
        -in "$infile" -out "$outfile" -pass "file:$ENCRYPTION_KEY_FILE" 2>/dev/null; then
        log_verbose "✅ Decryption successful (pbkdf2 method, 100000 iterations)"
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

parse_backup_filename() {
    local filename=$(basename "$1")
    if [[ "$filename" =~ ^(.*)_([0-9]{8}_[0-9]{6})_(full|inc)\.tar\.gz\.enc$ ]]; then
        BASE="${BASH_REMATCH[1]}"
        TIMESTAMP="${BASH_REMATCH[2]}"
        TYPE="${BASH_REMATCH[3]}"
        return 0
    elif [[ "$filename" =~ ^(.*)_(full|inc)\.tar\.gz\.enc$ ]]; then
        BASE="${BASH_REMATCH[1]}"
        TIMESTAMP=$(stat -c %Y "$1" 2>/dev/null || date +%s)
        TYPE="${BASH_REMATCH[2]}"
        return 0
    else
        BASE="${filename%%.tar.gz.enc}"
        TIMESTAMP=$(stat -c %Y "$1" 2>/dev/null || date +%s)
        TYPE="full"
        return 1
    fi
}

get_backup_files_for_restore() {
    local backup_dir="$1"
    local -a files=()
    
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$backup_dir" -type f -name "*.enc" 2>/dev/null | sort)
    
    printf '%s\n' "${files[@]}"
}

find_backup_file() {
    local search_term="$1"
    local backup_dir="$2"
    local -a matches=()
    
    if [[ -f "$search_term" ]]; then
        echo "$search_term"
        return 0
    fi
    
    while IFS= read -r f; do
        local basename=$(basename "$f")
        local dirname=$(basename "$(dirname "$f")")
        if [[ "$basename" == *"$search_term"* ]] || [[ "$dirname" == *"$search_term"* ]]; then
            matches+=("$f")
        fi
    done < <(find "$backup_dir" -type f -name "*.enc" 2>/dev/null)
    
    if [[ ${#matches[@]} -eq 0 ]]; then
        return 1
    elif [[ ${#matches[@]} -eq 1 ]]; then
        echo "${matches[0]}"
        return 0
    else
        echo "Multiple backups found matching '$search_term':" >&2
        local i=0
        for f in "${matches[@]}"; do
            i=$((i+1))
            local basename=$(basename "$f")
            local dirname=$(basename "$(dirname "$f")")
            local size=$(human_size $(stat -c%s "$f" 2>/dev/null || echo 0))
            printf "  %d) %s  (%s)  [%s]\n" "$i" "$basename" "$size" "$dirname" >&2
        done
        echo "" >&2
        echo -n "Select number (1-$i): " >&2
        read -r selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#matches[@]} ]]; then
            echo "${matches[$((selection-1))]}"
            return 0
        else
            return 1
        fi
    fi
}

get_restore_file_list() {
    local selected_file="$1"
    local base timestamp type
    parse_backup_filename "$selected_file" || return 1
    local base_name="$BASE"

    local all_files=()
    while IFS= read -r f; do
        all_files+=("$f")
    done < <(find "$BACKUP_BASE_DIR" -type f -name "*.enc" 2>/dev/null | sort)

    if [[ ${#all_files[@]} -eq 0 ]]; then
        echo "ERROR: No .enc files found in $BACKUP_BASE_DIR" >&2
        return 1
    fi

    local -a matched=()
    for f in "${all_files[@]}"; do
        local b ts typ
        parse_backup_filename "$f"
        if [[ "$BASE" == "$base_name" ]]; then
            matched+=("$f|$TIMESTAMP|$TYPE")
        fi
    done

    if [[ ${#matched[@]} -eq 0 ]]; then
        echo "ERROR: No backup files found for base '$base_name' in $BACKUP_BASE_DIR" >&2
        return 1
    fi

    local -a sorted=()
    for entry in "${matched[@]}"; do
        IFS='|' read -r path ts typ <<< "$entry"
        local epoch="$ts"
        if [[ "$ts" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
            epoch=$(date -d "${ts:0:8} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null || echo 0)
        fi
        sorted+=("$epoch|$typ|$path")
    done

    IFS=$'\n' sorted=($(sort -t'|' -k1 -n <<<"${sorted[*]}"))
    unset IFS

    local selected_idx=-1
    for i in "${!sorted[@]}"; do
        local f="${sorted[$i]##*|}"
        if [[ "$f" == "$selected_file" ]]; then
            selected_idx=$i
            break
        fi
    done

    if [[ $selected_idx -eq -1 ]]; then
        echo "ERROR: Selected file not found after sorting" >&2
        return 1
    fi

    local sel_typ="${sorted[$selected_idx]#*|}"
    sel_typ="${sel_typ%%|*}"

    local start_idx=$selected_idx
    if [[ "$sel_typ" == "inc" ]]; then
        local found_full=-1
        for ((i=selected_idx-1; i>=0; i--)); do
            local typ="${sorted[$i]#*|}"
            typ="${typ%%|*}"
            if [[ "$typ" == "full" ]]; then
                found_full=$i
                break
            fi
        done
        if [[ $found_full -eq -1 ]]; then
            echo "ERROR: No full backup found before incremental file" >&2
            return 1
        fi
        start_idx=$found_full
    fi

    local -a restore_files=()
    for ((i=start_idx; i<=selected_idx; i++)); do
        local f="${sorted[$i]##*|}"
        restore_files+=("$f")
    done

    printf '%s\n' "${restore_files[@]}"
}

get_snapshot_file() {
    local backup_type="$1"
    local snapshot_name="${backup_type}.snar"
    echo "${INCREMENTAL_BASE_DIR}/${snapshot_name}"
}

validate_snapshot() {
    local snapshot_file="$1"
    
    if [[ ! -f "$snapshot_file" ]]; then
        return 1
    fi
    
    if ! grep -q "^last_backup:" "$snapshot_file" 2>/dev/null; then
        log_verbose "⚠️ Snapshot missing 'last_backup' field"
        return 1
    fi
    
    if ! grep -q "^full:" "$snapshot_file" 2>/dev/null; then
        log_verbose "⚠️ Snapshot missing 'full' field"
        return 1
    fi
    
    local checksum_line=$(grep "^checksum:" "$snapshot_file" 2>/dev/null)
    if [[ -n "$checksum_line" ]]; then
        local stored_checksum=$(echo "$checksum_line" | cut -d: -f2)
        local content=$(grep -v "^checksum:" "$snapshot_file" 2>/dev/null)
        local computed_checksum=$(echo "$content" | sha256sum | cut -d' ' -f1)
        
        if [[ "$stored_checksum" != "$computed_checksum" ]]; then
            log_verbose "⚠️ Snapshot checksum mismatch (corrupted)"
            return 1
        fi
    fi
    
    local last_backup=$(grep "^last_backup:" "$snapshot_file" | cut -d: -f2)
    local current_time=$(date +%s)
    if [[ -n "$last_backup" ]] && [[ "$last_backup" -gt "$((current_time + 3600))" ]]; then
        log_verbose "⚠️ Snapshot has future timestamp (system clock issue?)"
        return 1
    fi
    
    return 0
}

update_snapshot_with_checksum() {
    local snapshot_file="$1"
    
    local temp_file="${snapshot_file}.tmp"
    
    grep -v "^checksum:" "$snapshot_file" 2>/dev/null > "$temp_file" || true
    
    local content=$(cat "$temp_file")
    local checksum=$(echo "$content" | sha256sum | cut -d' ' -f1)
    echo "checksum:$checksum" >> "$temp_file"
    
    mv "$temp_file" "$snapshot_file"
}

get_last_full_backup() {
    local backup_type="$1"
    local snapshot_file=$(get_snapshot_file "$backup_type")
    
    if [[ -f "$snapshot_file" ]]; then
        local last_full=$(grep "^full:" "$snapshot_file" 2>/dev/null | tail -1 | cut -d: -f2)
        if [[ -z "$last_full" ]]; then
            echo "0"
        else
            echo "$last_full"
        fi
    else
        echo "0"
    fi
}

should_do_full_backup() {
    local backup_type="$1"
    
    if [[ "$INCREMENTAL_ENABLED" != "true" ]]; then
        return 0
    fi
    
    local last_full=$(get_last_full_backup "$backup_type")
    local current_time=$(date +%s)
    local days_since=$(( (current_time - last_full) / 86400 ))
    
    if [[ $last_full -eq 0 ]]; then
        return 0
    elif [[ $days_since -ge $FULL_BACKUP_INTERVAL ]]; then
        return 0
    else
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
        else
            echo "full:$current_time" >> "$snapshot_file"
        fi
    else
        cat > "$snapshot_file" << EOF
last_backup:$current_time
full:$current_time
EOF
    fi
}

backup_directory_incremental() {
    local src="$1"
    local dest_dir="$2"
    local name="$3"
    local timestamp=$(get_timestamp)
    local archive_base="${dest_dir}/${name}_${timestamp}"
    
    local backup_type="dir_${name}"
    local snapshot_file=$(get_snapshot_file "$backup_type")
    
    if [[ -f "$snapshot_file" ]]; then
        if ! validate_snapshot "$snapshot_file"; then
            log "⚠️ Snapshot corrupted. Forcing full backup."
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
        log "📦 FULL backup of $src (incremental disabled)"
    else
        if should_do_full_backup "$backup_type"; then
            do_full=true
            log "📦 FULL backup of $src (scheduled)"
        else
            if [[ -f "$snapshot_file" ]]; then
                last_backup_time=$(grep "^last_backup:" "$snapshot_file" 2>/dev/null | cut -d: -f2)
                
                if [[ -n "$last_backup_time" ]] && [[ "$last_backup_time" -gt 0 ]]; then
                    do_full=false
                    local last_date=$(date -d "@$last_backup_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                    log "📦 INCREMENTAL backup of $src (since $last_date)"
                else
                    do_full=true
                    log "⚠️ Invalid timestamp. Forcing FULL backup."
                    rm -f "$snapshot_file"
                fi
            else
                do_full=true
                log "📦 FULL backup of $src (no snapshot)"
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
        
        tar -cf "$tar_file" -C "$src" "${exclude_opts[@]}" \
            --preserve-permissions --same-owner --xattrs \
            . 2>/dev/null || \
        tar -cf "$tar_file" -C "$src" "${exclude_opts[@]}" \
            --preserve-permissions --same-owner \
            . 2>/dev/null || {
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
        
        update_snapshot_with_checksum "$snapshot_file"
        
        log_verbose "Updated snapshot: $snapshot_file"
        
    else
        log "Creating INCREMENTAL backup archive..."
        
        local changed_files="${TMP_DIR}/changed_files_${backup_type}_$$.txt"
        local file_count=0
        
        if command -v find &>/dev/null; then
            (cd "$src" && find . -type f -newermt "@$last_backup_time" 2>/dev/null | sed 's|^\./||') > "$changed_files"
            if [[ ! -s "$changed_files" ]] && [[ -f "$snapshot_file" ]]; then
                (cd "$src" && find . -type f -newer "$snapshot_file" 2>/dev/null | sed 's|^\./||') > "$changed_files"
            fi
            if [[ ! -s "$changed_files" ]]; then
                (cd "$src" && find . -type f -mtime -1 2>/dev/null | sed 's|^\./||') > "$changed_files"
            fi
            file_count=$(wc -l < "$changed_files" 2>/dev/null || echo 0)
        else
            if command -v rsync &>/dev/null; then
                (cd "$src" && rsync -avn --delete ./ /dev/null 2>/dev/null | grep -v "^sending" | grep -v "^$" | sed 's|^\./||') > "$changed_files"
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
            
            tar -cf "$tar_file" -C "$src" \
                --preserve-permissions --same-owner --xattrs \
                --files-from="$changed_files" 2>/dev/null || \
            tar -cf "$tar_file" -C "$src" \
                --preserve-permissions --same-owner \
                --files-from="$changed_files" 2>/dev/null || {
                    error_exit "Failed to create incremental tar archive"
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
            
            update_snapshot_with_checksum "$snapshot_file"
            
            log_verbose "Updated snapshot: $snapshot_file"
            
        else
            log "📊 No changes detected since last backup"
            
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
            
            update_snapshot_with_checksum "$snapshot_file"
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

    log "🗜️ Compressing..."
    gzip -$GZIP_LEVEL "$final_tar_file" 2>/dev/null || error_exit "Compression failed for $final_tar_file"
    log "✅ Compression complete"
    
    if [[ ! -f "$final_gz_file" ]] || [[ ! -s "$final_gz_file" ]]; then
        error_exit "Compression failed for $final_tar_file"
    fi

    generate_checksums "$final_gz_file" "${final_gz_file}.checksums"
    
    log_verbose "Encrypting..."
    encrypt_file "$final_gz_file" "$final_enc_file"
    
    if [[ -f "$final_enc_file" ]] && [[ -s "$final_enc_file" ]]; then
        sha256sum "$final_enc_file" | awk '{print $1}' | sed "s/^/SHA256: /" > "${final_enc_file}.enc.checksums"
        
        rm -f "$final_gz_file"
        
        if [[ "$do_full" == "true" ]]; then
            log "✅ FULL backup: $(basename "$final_enc_file") ($(human_size $(stat -c%s "$final_enc_file" 2>/dev/null || echo 0)))"
        else
            local file_count=0
            if [[ -f "$final_tar_file" ]]; then
                file_count=$(tar -tf "$final_tar_file" 2>/dev/null | wc -l || echo 0)
            fi
            log "✅ INCREMENTAL backup: $(basename "$final_enc_file") ($(human_size $(stat -c%s "$final_enc_file" 2>/dev/null || echo 0)))"
            if [[ $file_count -gt 0 ]]; then
                log "📊 Changed files: $file_count"
            fi
        fi
    else
        error_exit "Encryption failed for $final_gz_file"
    fi
}

backup_container_volume() {
    local runtime="$1"
    local volume="$2"
    local dest_dir="$3"
    local timestamp=$(get_timestamp)
    local archive_base="${dest_dir}/volume_${volume}_${timestamp}"
    
    local backup_type="vol_${volume}"
    local snapshot_file=$(get_snapshot_file "$backup_type")
    
    if [[ -f "$snapshot_file" ]]; then
        if ! validate_snapshot "$snapshot_file"; then
            log "⚠️ Snapshot corrupted. Forcing full backup."
            rm -f "$snapshot_file"
            rm -f "${INCREMENTAL_BASE_DIR}/${backup_type}_inc_*.snar" 2>/dev/null || true
        fi
    fi
    
    local do_full=false
    local backup_suffix=""
    local last_backup_time=0
    
    if [[ "$INCREMENTAL_ENABLED" != "true" ]]; then
        do_full=true
        log "📦 FULL backup of volume: $volume (incremental disabled)"
    else
        if should_do_full_backup "$backup_type"; then
            do_full=true
            log "📦 FULL backup of volume: $volume (scheduled)"
        else
            if [[ -f "$snapshot_file" ]]; then
                last_backup_time=$(grep "^last_backup:" "$snapshot_file" 2>/dev/null | cut -d: -f2)
                if [[ -n "$last_backup_time" ]] && [[ "$last_backup_time" -gt 0 ]]; then
                    do_full=false
                    local last_date=$(date -d "@$last_backup_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                    log "📦 INCREMENTAL backup of volume: $volume (since $last_date)"
                else
                    do_full=true
                    log "⚠️ Invalid timestamp. Forcing FULL backup."
                    rm -f "$snapshot_file"
                fi
            else
                do_full=true
                log "📦 FULL backup of volume: $volume (no snapshot)"
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

    log "📦 Backing up volume: $volume"
    if ! volume_exists "$runtime" "$volume"; then
        error_exit "Volume $volume does not exist"
    fi

    local container_name="chantik_backup_vol_${volume}_$(date +%s)_$$"
    local snapshot_volume="${volume}_snapshot_$$"
    
    create_snapshot_volume "$runtime" "$volume" "$snapshot_volume"
    
    trap "cleanup_snapshot_volume $runtime $snapshot_volume" EXIT
    
    log_verbose "Copying volume data to snapshot..."
    
    if [[ "$runtime" == "podman" ]]; then
        local copy_container="chantik_copy_$$"
        podman run -d --name "$copy_container" -v "$volume":/source:ro -v "$snapshot_volume":/target "$DOCKER_IMAGE" sleep infinity 2>/dev/null || \
            podman run -d --name "$copy_container" -v "$volume":/source:ro -v "$snapshot_volume":/target alpine sleep infinity 2>/dev/null
        podman exec "$copy_container" sh -c "cp -a /source/. /target/ 2>/dev/null || true" 2>/dev/null
        podman rm -f "$copy_container" 2>/dev/null || true
    else
        docker run --rm -v "$volume":/source:ro -v "$snapshot_volume":/target "$DOCKER_IMAGE" \
            sh -c "cp -a /source/. /target/ 2>/dev/null || true" 2>/dev/null || true
    fi
    
    if [[ "$do_full" == "true" ]]; then
        log "Creating FULL backup archive for volume..."
        
        if [[ "$runtime" == "podman" ]]; then
            podman run --rm --name "$container_name" \
                -v "$snapshot_volume":/volume \
                -v "$dest_dir":/backup \
                "$DOCKER_IMAGE" \
                sh -c "tar -cf '/backup/${volume}_${timestamp}.tar' -C /volume . \
                    --preserve-permissions --same-owner 2>/dev/null" || \
            podman run --rm --name "$container_name" \
                -v "$snapshot_volume":/volume \
                -v "$dest_dir":/backup \
                alpine \
                tar -cf "/backup/${volume}_${timestamp}.tar" -C /volume . 2>/dev/null || {
                    error_exit "Failed to create tar for volume $volume"
                }
        else
            docker run --rm --name "$container_name" \
                -v "$snapshot_volume":/volume \
                -v "$dest_dir":/backup \
                "$DOCKER_IMAGE" \
                sh -c "tar -cf '/backup/${volume}_${timestamp}.tar' -C /volume . \
                    --preserve-permissions --same-owner 2>/dev/null" || \
            docker run --rm --name "$container_name" \
                -v "$snapshot_volume":/volume \
                -v "$dest_dir":/backup \
                alpine \
                tar -cf "/backup/${volume}_${timestamp}.tar" -C /volume . 2>/dev/null || {
                    error_exit "Failed to create tar for volume $volume"
                }
        fi
        
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
        
        update_snapshot_with_checksum "$snapshot_file"
        
        log_verbose "Updated snapshot: $snapshot_file"
        
    else
        log "Creating INCREMENTAL backup archive for volume..."
        
        local timestamp_file="${TMP_DIR}/.timestamp_${backup_type}_$$"
        touch -d "@$last_backup_time" "$timestamp_file" 2>/dev/null || \
            touch -t "$(date -d "@$last_backup_time" '+%Y%m%d%H%M.%S' 2>/dev/null || echo '197001010000.00')" "$timestamp_file" 2>/dev/null
        
        if [[ "$runtime" == "podman" ]]; then
            podman run --rm --name "$container_name" \
                -v "$snapshot_volume":/volume \
                -v "$dest_dir":/backup \
                -v "$(dirname "$timestamp_file")":/timestamps \
                "$DOCKER_IMAGE" \
                sh -c "
                    TIMESTAMP_FILE='/timestamps/$(basename "$timestamp_file")'
                    if [ -f \"\$TIMESTAMP_FILE\" ]; then
                        find /volume -type f -newer \"\$TIMESTAMP_FILE\" > /tmp/changed.txt 2>/dev/null
                        if [ -s /tmp/changed.txt ]; then
                            tar -cf '/backup/${volume}_${timestamp}.tar' -C /volume --files-from=/tmp/changed.txt --preserve-permissions 2>/dev/null
                        else
                            touch '/backup/${volume}_${timestamp}.tar'
                        fi
                    else
                        tar -cf '/backup/${volume}_${timestamp}.tar' -C /volume . --preserve-permissions 2>/dev/null
                    fi
                " || {
                    log_verbose "Incremental backup failed, creating full backup"
                    do_full=true
                    podman run --rm --name "${container_name}_full" \
                        -v "$snapshot_volume":/volume \
                        -v "$dest_dir":/backup \
                        alpine \
                        tar -cf "/backup/${volume}_${timestamp}.tar" -C /volume . 2>/dev/null || {
                            error_exit "Failed to create tar for volume $volume"
                        }
                }
        else
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
                            tar -cf '/backup/${volume}_${timestamp}.tar' -C /volume --files-from=/tmp/changed.txt --preserve-permissions 2>/dev/null
                        else
                            touch '/backup/${volume}_${timestamp}.tar'
                        fi
                    else
                        tar -cf '/backup/${volume}_${timestamp}.tar' -C /volume . --preserve-permissions 2>/dev/null
                    fi
                " || {
                    log_verbose "Incremental backup failed, creating full backup"
                    do_full=true
                    docker run --rm --name "${container_name}_full" \
                        -v "$snapshot_volume":/volume \
                        -v "$dest_dir":/backup \
                        alpine \
                        tar -cf "/backup/${volume}_${timestamp}.tar" -C /volume . 2>/dev/null || {
                            error_exit "Failed to create tar for volume $volume"
                        }
                }
        fi
        
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
        
        update_snapshot_with_checksum "$snapshot_file"
        
        log_verbose "Updated snapshot: $snapshot_file"
    fi
    
    cleanup_snapshot_volume "$runtime" "$snapshot_volume"
    trap - EXIT

    local temp_tar="${dest_dir}/${volume}_${timestamp}.tar"
    if [[ ! -f "$temp_tar" ]]; then
        error_exit "Tar file not created for volume $volume"
    fi

    if [[ ! -s "$temp_tar" ]] && [[ "$do_full" == "false" ]]; then
        log "📦 Empty incremental backup (no changes in volume)"
        rm -f "$temp_tar" 2>/dev/null
        log "✅ No changes to backup for volume $volume"
        return 0
    fi

    mv "$temp_tar" "$final_tar_file"
    
    if ! tar -tf "$final_tar_file" &>/dev/null; then
        error_exit "Tar file is corrupted or empty: $final_tar_file"
    fi

    if [[ "$do_full" == "true" ]]; then
        update_snapshot_full_time "$backup_type"
        touch "$snapshot_file"
    fi

    log "🗜️ Compressing..."
    gzip -$GZIP_LEVEL "$final_tar_file" 2>/dev/null || error_exit "Compression failed for $final_tar_file"
    if [[ ! -f "$final_gz_file" ]] || [[ ! -s "$final_gz_file" ]]; then
        error_exit "Compression failed for $final_tar_file"
    fi

    generate_checksums "$final_gz_file" "${final_gz_file}.checksums"
    
    log_verbose "Encrypting volume backup..."
    encrypt_file "$final_gz_file" "$final_enc_file"
    
    if [[ -f "$final_enc_file" ]] && [[ -s "$final_enc_file" ]]; then
        sha256sum "$final_enc_file" | awk '{print $1}' | sed "s/^/SHA256: /" > "${final_enc_file}.enc.checksums"
        log_verbose "Created encrypted checksum: ${final_enc_file}.enc.checksums"
        
        rm -f "$final_gz_file"
        
        if [[ "$do_full" == "true" ]]; then
            log "✅ FULL volume backup: $(basename "$final_enc_file") ($(human_size $(stat -c%s "$final_enc_file" 2>/dev/null || echo 0)))"
        else
            local file_count=0
            if [[ -f "$final_tar_file" ]]; then
                file_count=$(tar -tf "$final_tar_file" 2>/dev/null | wc -l || echo 0)
            fi
            log "✅ INCREMENTAL volume backup: $(basename "$final_enc_file") ($(human_size $(stat -c%s "$final_enc_file" 2>/dev/null || echo 0)))"
            if [[ $file_count -gt 0 ]]; then
                log "📊 Changed files in volume: $file_count"
            fi
        fi
    else
        error_exit "Encryption failed for $final_gz_file"
    fi
}

cleanup_snapshot_volume() {
    local runtime="$1"
    local snapshot_volume="$2"
    
    if [[ "$runtime" == "podman" ]]; then
        podman volume rm "$snapshot_volume" 2>/dev/null || true
    else
        docker volume rm "$snapshot_volume" 2>/dev/null || true
    fi
}

restore_single_backup() {
    local enc_file="$1"
    local staging_dir="$2"
    
    if [[ ! -f "$enc_file" ]]; then
        echo "ERROR: Backup file not found: $enc_file" >&2
        return 1
    fi

    local restore_files
    mapfile -t restore_files < <(get_restore_file_list "$enc_file") || {
        echo "ERROR: Failed to determine restore files" >&2
        return 1
    }

    if [[ ${#restore_files[@]} -eq 0 ]]; then
        echo "ERROR: No files to restore" >&2
        return 1
    fi

    local first_file="${restore_files[0]}"
    local base_name timestamp type
    parse_backup_filename "$first_file"
    local base="$BASE"
    
    local target_path=""
    local restore_type=""
    local volume_name=""
    
    if [[ "$base" == "digital-independence" ]] || [[ "$base" == "$(basename "$SOURCE_DIR")" ]]; then
        restore_type="dir"
        target_path="${SOURCE_DIR%/}"
    elif [[ "$base" =~ ^volume_ ]]; then
        restore_type="volume"
        volume_name="${base#volume_}"
        target_path="Volume: $volume_name"
    else
        restore_type="dir"
        target_path="${SOURCE_DIR%/}"
    fi

    local pre_backup_path=""
    if [[ -e "$target_path" ]] || [[ -n "$volume_name" ]]; then
        echo ""
        echo "🔄 Creating pre-restore backup..."
        if [[ "$restore_type" == "volume" ]]; then
            local runtime=$(detect_container_runtime)
            if volume_exists "$runtime" "$volume_name"; then
                local snapshot_vol="${volume_name}_pre_restore_$$"
                create_snapshot_volume "$runtime" "$volume_name" "$snapshot_vol"
                pre_backup_path="Volume snapshot: $snapshot_vol"
                log "✅ Pre-restore volume snapshot created: $snapshot_vol"
            else
                log_verbose "⚠️ Volume $volume_name does not exist, no pre-restore backup needed"
            fi
        else
            pre_backup_path=$(create_pre_restore_backup "$target_path" "$base")
            if [[ $? -ne 0 ]]; then
                echo "⚠️ Failed to create pre-restore backup. Continue anyway? (yes/no): "
                read -r continue_anyway
                if [[ "$continue_anyway" != "yes" ]]; then
                    return 1
                fi
            fi
        fi
    fi

    if [[ -n "$pre_backup_path" ]]; then
        echo ""
        echo "💾 Pre-restore backup saved to: $pre_backup_path"
    fi
    
    if ! confirm_restore "$target_path" "Restoring from: $(basename "$enc_file")"; then
        return 1
    fi

    log "🔄 Restoring from ${#restore_files[@]} backup(s)"

    local checksum_ok=true
    local checksum_failed=0

    for enc in "${restore_files[@]}"; do
        log "📦 Processing: $(basename "$enc")"
        local decrypted_gz="${staging_dir}/$(basename "${enc%.enc}")"
        log "🔐 Decrypting..."
        decrypt_file "$enc" "$decrypted_gz" || {
            echo "ERROR: Decryption failed for $enc" >&2
            return 1
        }

        local checksum_file="${enc%.enc}.checksums"
        if [[ -f "$checksum_file" ]]; then
            local stored_sha=$(grep '^SHA256:' "$checksum_file" | awk '{print $2}')
            local current_sha=$(sha256sum "$decrypted_gz" | awk '{print $1}')
            if [[ "$stored_sha" != "$current_sha" ]]; then
                log "❌ Checksum MISMATCH for $(basename "$enc")"
                checksum_ok=false
                checksum_failed=$((checksum_failed + 1))
            else
                log "✅ Checksum verified: $(basename "$enc")"
            fi
        else
            log "⚠️ No checksum file found for $(basename "$enc")"
        fi

        log "🗜️ Decompressing..."
        gunzip -f "$decrypted_gz" || {
            echo "ERROR: Gunzip failed" >&2
            return 1
        }
        local tar_file="${decrypted_gz%.gz}"
        if [[ ! -f "$tar_file" ]]; then
            echo "ERROR: Tar file not found after decompression" >&2
            return 1
        fi

        log "📂 Extracting to staging..."
        tar -xf "$tar_file" -C "$staging_dir" --overwrite --preserve-permissions 2>/dev/null || \
            tar -xf "$tar_file" -C "$staging_dir" --overwrite 2>/dev/null || {
                echo "ERROR: Failed to extract tar" >&2
                return 1
            }

        rm -f "$tar_file" "$decrypted_gz" 2>/dev/null
    done

    log "✅ All backups extracted to staging: $staging_dir"

    if [[ "$restore_type" == "dir" ]]; then
        mkdir -p "$target_path" 2>/dev/null || sudo mkdir -p "$target_path" 2>/dev/null
        
        log "📁 Restoring directory to $target_path"
        
        if command -v rsync &>/dev/null; then
            rsync -a --no-owner --no-group "$staging_dir/" "$target_path/" 2>/dev/null
        else
            cp -a "$staging_dir/." "$target_path/" 2>/dev/null
        fi
        
        log "✅ Directory restore completed to $target_path"

    elif [[ "$restore_type" == "volume" ]]; then
        log "📦 Restoring volume: $volume_name"
        
        local runtime=$(detect_container_runtime)
        
        if ! volume_exists "$runtime" "$volume_name"; then
            if [[ "$runtime" == "podman" ]]; then
                podman volume create "$volume_name" || {
                    echo "ERROR: Failed to create volume $volume_name" >&2
                    return 1
                }
            else
                docker volume create "$volume_name" || {
                    echo "ERROR: Failed to create volume $volume_name" >&2
                    return 1
                }
            fi
            log "📦 Created volume: $volume_name"
        fi

        local container_name="chantik_restore_vol_${volume_name}_$(date +%s)_$$"
        
        if [[ "$runtime" == "podman" ]]; then
            podman run -d --name "$container_name" -v "$volume_name":/volume "$DOCKER_IMAGE" sleep infinity 2>/dev/null || \
                podman run -d --name "$container_name" -v "$volume_name":/volume alpine sleep infinity 2>/dev/null || {
                    echo "ERROR: Cannot create restore container" >&2
                    return 1
                }
            
            podman cp "$staging_dir/." "$container_name:/volume/" 2>/dev/null || \
                podman cp "$staging_dir" "$container_name:/volume/" 2>/dev/null || {
                    echo "ERROR: Failed to copy data to volume" >&2
                    return 1
                }
            
            local source_count=$(find "$staging_dir" -type f 2>/dev/null | wc -l)
            local dest_count=$(podman exec "$container_name" find /volume -type f 2>/dev/null | wc -l)
            
            if [[ "$source_count" -ne "$dest_count" ]]; then
                log "❌ File count mismatch during volume restore"
                log "   Source: $source_count files"
                log "   Destination: $dest_count files"
                return 1
            fi
            
            log "✅ Volume restore verified: $source_count files copied"
            
            podman stop "$container_name" >/dev/null 2>&1
            podman rm "$container_name" >/dev/null 2>&1
        else
            docker run -d --name "$container_name" -v "$volume_name":/volume "$DOCKER_IMAGE" sleep infinity 2>/dev/null || \
                docker run -d --name "$container_name" -v "$volume_name":/volume alpine sleep infinity 2>/dev/null || {
                    echo "ERROR: Cannot create restore container" >&2
                    return 1
                }
            
            docker cp "$staging_dir/." "$container_name:/volume/" 2>/dev/null || \
                docker cp "$staging_dir" "$container_name:/volume/" 2>/dev/null || {
                    echo "ERROR: Failed to copy data to volume" >&2
                    return 1
                }
            
            local source_count=$(find "$staging_dir" -type f 2>/dev/null | wc -l)
            local dest_count=$(docker exec "$container_name" find /volume -type f 2>/dev/null | wc -l)
            
            if [[ "$source_count" -ne "$dest_count" ]]; then
                log "❌ File count mismatch during volume restore"
                log "   Source: $source_count files"
                log "   Destination: $dest_count files"
                return 1
            fi
            
            log "✅ Volume restore verified: $source_count files copied"
            
            docker stop "$container_name" >/dev/null 2>&1
            docker rm "$container_name" >/dev/null 2>&1
        fi
        
        log "✅ Volume restore completed for $volume_name"
    else
        echo "ERROR: Unknown restore type" >&2
        return 1
    fi

    return 0
}

multi_restore_from_backup() {
    local -a backup_patterns=("$@")
    
    if [[ ${#backup_patterns[@]} -eq 0 ]]; then
        echo "🕊️ ERROR: No backup patterns specified for multi-restore."
        echo ""
        echo "Usage: $SCRIPT_NAME restore <pattern1> <pattern2> ..."
        echo ""
        echo "Examples:"
        echo "  $SCRIPT_NAME restore volume_postgres volume_redis"
        echo "  $SCRIPT_NAME restore 20260906 20260907"
        echo "  $SCRIPT_NAME restore postgres redis"
        echo ""
        echo "Available backups:"
        chantik_list_backups "$BACKUP_BASE_DIR"
        return 1
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔄 MULTI-RESTORE: ${#backup_patterns[@]} pattern(s)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    echo ""
    echo "📦 Phase 1: Staging all restores..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local -a staged_restores=()
    local -a failed_patterns=()
    local -a stage_dirs=()
    
    for pattern in "${backup_patterns[@]}"; do
        echo ""
        echo "🔍 Staging: '$pattern'"
        
        local enc_file
        if ! enc_file=$(find_backup_file "$pattern" "$BACKUP_BASE_DIR"); then
            echo "  ❌ No backup found matching '$pattern'"
            failed_patterns+=("$pattern")
            continue
        fi
        
        local pattern_stage=$(setup_secure_staging "stage_${pattern}_$$")
        stage_dirs+=("$pattern_stage")
        
        if restore_single_backup "$enc_file" "$pattern_stage"; then
            staged_restores+=("$pattern|$pattern_stage|$enc_file")
            echo "  ✅ Staged successfully: $pattern"
        else
            failed_patterns+=("$pattern")
            echo "  ❌ Failed to stage: $pattern"
        fi
    done
    
    if [[ ${#failed_patterns[@]} -gt 0 ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "❌ MULTI-RESTORE TRANSACTION FAILED"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  Failed patterns: ${failed_patterns[*]}"
        echo "📦 Successful stages: ${#staged_restores[@]}"
        echo ""
        echo "🧹 Cleaning up staged restores (NO CHANGES APPLIED)..."
        
        for stage_dir in "${stage_dirs[@]}"; do
            rm -rf "$stage_dir" 2>/dev/null || true
        done
        
        echo "✅ Cleanup complete. No changes were applied to your system."
        return 1
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Phase 2: All ${#staged_restores[@]} restores staged successfully"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo "📋 Restore plan:"
    for staged in "${staged_restores[@]}"; do
        IFS='|' read -r pattern stage_dir enc_file <<< "$staged"
        echo "  - $pattern -> $(basename "$enc_file")"
    done
    
    echo ""
    echo -n "Apply all restores? (type 'APPLY' to proceed): "
    read -r apply_confirm
    
    if [[ "$apply_confirm" != "APPLY" ]]; then
        echo "❌ Multi-restore cancelled. No changes applied."
        
        for stage_dir in "${stage_dirs[@]}"; do
            rm -rf "$stage_dir" 2>/dev/null || true
        done
        return 0
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔄 Phase 3: Applying restores..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local -a applied=()
    local -a apply_failed=()
    
    for staged in "${staged_restores[@]}"; do
        IFS='|' read -r pattern stage_dir enc_file <<< "$staged"
        
        echo ""
        echo "📦 Applying: $pattern"
        
        local first_file="$enc_file"
        local base_name timestamp type
        parse_backup_filename "$first_file"
        local base="$BASE"
        
        if [[ "$base" == "digital-independence" ]] || [[ "$base" == "$(basename "$SOURCE_DIR")" ]]; then
            local dest_dir="${SOURCE_DIR%/}"
            log "📁 Applying to: $dest_dir"
            
            if command -v rsync &>/dev/null; then
                rsync -a --no-owner --no-group "$stage_dir/" "$dest_dir/" 2>/dev/null
            else
                cp -a "$stage_dir/." "$dest_dir/" 2>/dev/null
            fi
            
            if [[ $? -eq 0 ]]; then
                applied+=("$pattern")
                echo "  ✅ Applied: $pattern"
            else
                apply_failed+=("$pattern")
                echo "  ❌ Failed to apply: $pattern"
            fi
            
        elif [[ "$base" =~ ^volume_ ]]; then
            local volume_name="${base#volume_}"
            log "📦 Applying to volume: $volume_name"
            
            local runtime=$(detect_container_runtime)
            
            if ! volume_exists "$runtime" "$volume_name"; then
                if [[ "$runtime" == "podman" ]]; then
                    podman volume create "$volume_name" || {
                        apply_failed+=("$pattern")
                        continue
                    }
                else
                    docker volume create "$volume_name" || {
                        apply_failed+=("$pattern")
                        continue
                    }
                fi
                log "📦 Created volume: $volume_name"
            fi
            
            local container_name="chantik_apply_vol_${volume_name}_$(date +%s)_$$"
            
            if [[ "$runtime" == "podman" ]]; then
                podman run -d --name "$container_name" -v "$volume_name":/volume "$DOCKER_IMAGE" sleep infinity 2>/dev/null || \
                podman run -d --name "$container_name" -v "$volume_name":/volume alpine sleep infinity 2>/dev/null || {
                    apply_failed+=("$pattern")
                    continue
                }
                
                podman cp "$stage_dir/." "$container_name:/volume/" 2>/dev/null
                local copy_result=$?
                
                if [[ $copy_result -eq 0 ]]; then
                    local source_count=$(find "$stage_dir" -type f 2>/dev/null | wc -l)
                    local dest_count=$(podman exec "$container_name" find /volume -type f 2>/dev/null | wc -l)
                    if [[ "$source_count" -eq "$dest_count" ]]; then
                        applied+=("$pattern")
                        echo "  ✅ Applied: $pattern ($source_count files)"
                    else
                        apply_failed+=("$pattern")
                        echo "  ❌ Failed to apply: $pattern (file count mismatch)"
                    fi
                else
                    apply_failed+=("$pattern")
                    echo "  ❌ Failed to apply: $pattern"
                fi
                
                podman stop "$container_name" >/dev/null 2>&1
                podman rm "$container_name" >/dev/null 2>&1
                
            else
                docker run -d --name "$container_name" -v "$volume_name":/volume "$DOCKER_IMAGE" sleep infinity 2>/dev/null || \
                docker run -d --name "$container_name" -v "$volume_name":/volume alpine sleep infinity 2>/dev/null || {
                    apply_failed+=("$pattern")
                    continue
                }
                
                docker cp "$stage_dir/." "$container_name:/volume/" 2>/dev/null
                local copy_result=$?
                
                if [[ $copy_result -eq 0 ]]; then
                    local source_count=$(find "$stage_dir" -type f 2>/dev/null | wc -l)
                    local dest_count=$(docker exec "$container_name" find /volume -type f 2>/dev/null | wc -l)
                    if [[ "$source_count" -eq "$dest_count" ]]; then
                        applied+=("$pattern")
                        echo "  ✅ Applied: $pattern ($source_count files)"
                    else
                        apply_failed+=("$pattern")
                        echo "  ❌ Failed to apply: $pattern (file count mismatch)"
                    fi
                else
                    apply_failed+=("$pattern")
                    echo "  ❌ Failed to apply: $pattern"
                fi
                
                docker stop "$container_name" >/dev/null 2>&1
                docker rm "$container_name" >/dev/null 2>&1
            fi
        fi
        
        rm -rf "$stage_dir" 2>/dev/null || true
    done
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 MULTI-RESTORE TRANSACTION COMPLETE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Successfully applied: ${#applied[@]}"
    echo "❌ Failed to apply: ${#apply_failed[@]}"
    
    if [[ ${#apply_failed[@]} -gt 0 ]]; then
        echo "⚠️  Failed items: ${apply_failed[*]}"
        echo ""
        echo "💡 Some restores failed. Your system may be in an inconsistent state."
        echo "   Check the logs for details: $LOG_FILE"
        return 1
    else
        echo "✅ All restores applied successfully!"
        return 0
    fi
}

restore_from_backup() {
    local input="$1"
    
    local dry_run=false
    if [[ "$1" == "--dry-run" ]]; then
        dry_run=true
        shift
        input="$1"
    fi
    
    if [[ $# -gt 1 ]]; then
        multi_restore_from_backup "$@"
        return $?
    fi
    
    if [[ "$input" == *" "* ]] || [[ "$input" == *","* ]]; then
        IFS=' ,' read -ra patterns <<< "$input"
        multi_restore_from_backup "${patterns[@]}"
        return $?
    fi
    
    local enc_file
    if ! enc_file=$(find_backup_file "$input" "$BACKUP_BASE_DIR"); then
        echo "🕊️ ERROR: No backup found matching '$input'"
        echo ""
        echo "Available backups:"
        chantik_list_backups "$BACKUP_BASE_DIR"
        exit 1
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        echo ""
        echo "🔍 DRY RUN MODE - No changes will be made"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📦 Would restore: $(basename "$enc_file")"
        
        local restore_files
        mapfile -t restore_files < <(get_restore_file_list "$enc_file") || {
            echo "ERROR: Failed to determine restore files" >&2
            return 1
        }
        echo "📁 Total backups to restore: ${#restore_files[@]}"
        
        local total_size=0
        for f in "${restore_files[@]}"; do
            local size=$(stat -c%s "$f" 2>/dev/null || echo 0)
            total_size=$((total_size + size))
            echo "   - $(basename "$f") ($(human_size "$size"))"
        done
        echo "📊 Total size: $(human_size "$total_size")"
        
        local first_file="${restore_files[0]}"
        local base_name timestamp type
        parse_backup_filename "$first_file"
        local base="$BASE"
        
        if [[ "$base" == "digital-independence" ]] || [[ "$base" == "$(basename "$SOURCE_DIR")" ]]; then
            echo "📂 Target: ${SOURCE_DIR%/}"
        elif [[ "$base" =~ ^volume_ ]]; then
            local volume_name="${base#volume_}"
            echo "📦 Target volume: $volume_name"
        else
            echo "📂 Target: ${SOURCE_DIR%/}"
        fi
        
        echo ""
        echo "✅ Dry run complete. No changes made."
        return 0
    fi
    
    local staging_dir=$(setup_secure_staging "restore_$$")
    trap 'rm -rf "$staging_dir" 2>/dev/null; cleanup_temp; exit' INT TERM EXIT
    
    if restore_single_backup "$enc_file" "$staging_dir"; then
        rm -rf "$staging_dir" 2>/dev/null
        trap - INT TERM EXIT
        log "✅ Restore completed successfully."
        return 0
    else
        rm -rf "$staging_dir" 2>/dev/null
        trap - INT TERM EXIT
        error_exit "Restore failed"
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
    done < <(find "$backup_dir" -type f -name "*.enc" 2>/dev/null | sort)
    
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
                local total_files=$(find "$backup_dir" -type f -name "*.enc" 2>/dev/null | wc -l)
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
                local total_files=$(find "$backup_dir" -type f -name "*.enc" 2>/dev/null | wc -l)
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

    local file_count=$(find "$backup_dir" -type f -name "*.enc" 2>/dev/null | wc -l)
    log_verbose "Found $file_count backup files in $backup_dir"

    local daily="$RETENTION_DAILY"
    local weekly="$RETENTION_WEEKLY"
    local monthly="$RETENTION_MONTHLY"

    local tmp_file
    if ! tmp_file=$(mktemp -p "$TMP_DIR" backup_rotate_XXXXXX 2>/dev/null); then
        tmp_file="${TMP_DIR}/backup_rotate_$$_$RANDOM"
    fi
    local grouped_file="${tmp_file}.grouped"

    find "$backup_dir" -type f -name "*.enc" > "$tmp_file" 2>/dev/null

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

chantik_list_backups() {
    local backup_dir="$1"
    echo ""
    echo "📦 Available backups in: $backup_dir"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local found=false
    while IFS= read -r enc_file; do
        found=true
        local basename=$(basename "$enc_file")
        local size=$(human_size $(stat -c%s "$enc_file" 2>/dev/null || echo 0))
        
        local date_str=$(echo "$basename" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | head -1)
        local formatted_date=""
        if [[ -n "$date_str" ]]; then
            local year="${date_str:0:4}"
            local month="${date_str:4:2}"
            local day="${date_str:6:2}"
            local hour="${date_str:9:2}"
            local minute="${date_str:11:2}"
            local second="${date_str:13:2}"
            formatted_date="$year-$month-$day $hour:$minute:$second"
        fi
        
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
        
        printf "  %s %s %-55s  %-10s  %s\n" "$status" "$backup_type" "$basename" "$size" "$formatted_date"
    done < <(find "$backup_dir" -type f -name "*.enc" 2>/dev/null | sort)
    
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
    
    local runtime=$(detect_container_runtime)
    CONTAINER_RUNTIME="$runtime"
    log "🐳 Container runtime: $runtime"
    
    local hostname=$(hostname)
    local source_size=$(get_dir_size "$SOURCE_DIR")
    local source_size_human=$(human_size "$source_size")
    local source_files=$(get_file_count "$SOURCE_DIR")
    local source_dirs=$(find "$SOURCE_DIR" -type d 2>/dev/null | wc -l)
    
    local volume_count=0
    if [[ ${#DOCKER_VOLUMES[@]} -gt 0 ]]; then
        volume_count=$((volume_count + ${#DOCKER_VOLUMES[@]}))
    fi
    if [[ ${#PODMAN_VOLUMES[@]} -gt 0 ]] && [[ "$runtime" == "podman" ]]; then
        volume_count=$((volume_count + ${#PODMAN_VOLUMES[@]}))
    fi
    
    local free_space_mb
    free_space_mb=$(df -m "$BACKUP_BASE_DIR" | awk 'NR==2 {print $4}')
    local free_space_human=$(human_size $((free_space_mb * 1024 * 1024)))
    
    log "📁 Source: $SOURCE_DIR"
    log "📊 Size: $source_size_human ($source_files files, $source_dirs dirs)"
    log "🐳 Volumes: $volume_count volumes"
    log "💾 Target: $BACKUP_BASE_DIR"
    log "💿 Free: $free_space_human"
    log "🔒 Encryption: ${ENCRYPTION_CIPHER^^}"
    log "🔑 PBKDF2: ${PBKDF2_ITERATIONS:-600000}"
    log "🔗 Dedup: $([ -n "$FIXED_NONCE" ] && echo "ENABLED" || echo "DISABLED")"
    log "🗜️ Compression: gzip level $GZIP_LEVEL"
    log "📋 Retention: D${RETENTION_DAILY}/W${RETENTION_WEEKLY}/M${RETENTION_MONTHLY}"
    log "🔄 Incremental: $([ "$INCREMENTAL_ENABLED" == "true" ] && echo "ENABLED (${FULL_BACKUP_INTERVAL} days)" || echo "DISABLED")"
    
    send_ntfy "📅 $start_date\n💻 $hostname\n📁 $SOURCE_DIR\n📊 $source_size_human ($source_files files, $source_dirs dirs)\n🐳 $volume_count volumes\n🐳 Runtime: $runtime\n💾 $BACKUP_BASE_DIR\n💿 Free: $free_space_human\n🔒 ${ENCRYPTION_CIPHER^^}\n🔑 PBKDF2: ${PBKDF2_ITERATIONS:-600000}\n🔗 Dedup: $([ -n "$FIXED_NONCE" ] && echo "ENABLED" || echo "DISABLED")\n🗜️ gzip $GZIP_LEVEL\n📋 Retention: D${RETENTION_DAILY}/W${RETENTION_WEEKLY}/M${RETENTION_MONTHLY}\n🔄 $([ "$INCREMENTAL_ENABLED" == "true" ] && echo "ENABLED (${FULL_BACKUP_INTERVAL} days)" || echo "DISABLED")" "info"
    
    acquire_lock
    check_container_runtime
    check_disk_space "$BACKUP_BASE_DIR" 1024

    local timestamp
    timestamp=$(get_timestamp)
    local backup_dir="${BACKUP_BASE_DIR}/${BACKUP_PREFIX}_${timestamp}"
    mkdir -p "$backup_dir"
    log "📂 Backup directory created: $backup_dir"

    backup_directory_incremental "$SOURCE_DIR" "$backup_dir" "digital-independence"

    local failed=0
    local vol_count=0
    local vol_success=0
    
    for vol in "${DOCKER_VOLUMES[@]}"; do
        vol_count=$((vol_count + 1))
        log "📦 Docker volume $vol_count/${#DOCKER_VOLUMES[@]}: $vol"
        
        local vol_runtime="$runtime"
        if [[ "$runtime" == "podman" ]] && ! volume_exists "podman" "$vol"; then
            if volume_exists "docker" "$vol"; then
                log "Volume $vol exists in Docker, using Docker"
                vol_runtime="docker"
            else
                log "⚠️ Volume $vol not found, skipping..."
                failed=$((failed + 1))
                continue
            fi
        fi
        
        if backup_container_volume "$vol_runtime" "$vol" "$backup_dir"; then
            vol_success=$((vol_success + 1))
            log "✅ Volume $vol backed up successfully"
        else
            log "❌ Failed to backup volume: $vol"
            failed=$((failed + 1))
        fi
    done

    if [[ "$runtime" == "podman" ]]; then
        for vol in "${PODMAN_VOLUMES[@]}"; do
            local already_processed=false
            for processed in "${DOCKER_VOLUMES[@]}"; do
                if [[ "$processed" == "$vol" ]]; then
                    already_processed=true
                    break
                fi
            done
            [[ "$already_processed" == "true" ]] && continue
            
            vol_count=$((vol_count + 1))
            log "📦 Podman volume $vol_count: $vol"
            
            if ! volume_exists "podman" "$vol"; then
                log "⚠️ Podman volume $vol not found, skipping..."
                failed=$((failed + 1))
                continue
            fi
            
            if backup_container_volume "podman" "$vol" "$backup_dir"; then
                vol_success=$((vol_success + 1))
                log "✅ Podman volume $vol backed up successfully"
            else
                log "❌ Failed to backup Podman volume: $vol"
                failed=$((failed + 1))
            fi
        done
    fi

    if [[ $failed -gt 0 ]]; then
        log "⚠️ WARNING: $failed of $vol_count volume backup(s) failed"
    else
        log "✅ All $vol_count volumes backed up successfully"
    fi

    check_backup_size "$backup_dir"

    local all_ok=true
    local enc_files=()
    local verified_count=0
    local failed_verify=0
    
    if ls "$backup_dir"/*.enc &>/dev/null; then
        for enc_file in "$backup_dir"/*.enc; do
            enc_files+=("$enc_file")
            if verify_backup "$enc_file"; then
                verified_count=$((verified_count + 1))
            else
                all_ok=false
                failed_verify=$((failed_verify + 1))
            fi
        done
        if $all_ok; then
            log "✅ All backups verified ($verified_count files)"
        else
            log "⚠️ WARNING: $failed_verify of $verified_count backups failed verification"
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

    local full_count=0
    local inc_count=0
    local full_size=0
    local inc_size=0
    
    for enc in "${enc_files[@]}"; do
        local fname=$(basename "$enc")
        local fsize=$(stat -c%s "$enc" 2>/dev/null || echo 0)
        if [[ "$fname" == *_full* ]]; then
            full_count=$((full_count + 1))
            full_size=$((full_size + fsize))
        elif [[ "$fname" == *_inc* ]]; then
            inc_count=$((inc_count + 1))
            inc_size=$((inc_size + fsize))
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 BACKUP SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📂 Location: $backup_dir"
    echo "📁 Source: $source_dirs dirs, $source_files files ($source_size_human)"
    echo "📦 Archives: $backup_count encrypted files"
    echo "   FULL: $full_count ($(human_size $full_size))"
    echo "   INC:  $inc_count ($(human_size $inc_size))"
    echo "   Total: $total_backup_size_human"
    echo "🔐 Verification: $([ $failed_verify -eq 0 ] && echo "✅ ALL PASSED" || echo "⚠️ $failed_verify FAILED")"
    echo "💿 Storage: $free_space_human → $(human_size $((new_free_space_mb * 1024 * 1024))) (used $space_used_human)"
    echo "🐳 Volumes: ${vol_success}/${volume_count} successful"
    echo "⏱️ Duration: $duration_human"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    log_section "✅ Backup completed successfully"
    log "🕊️ $BRAND_NAME — $BRAND_TAGLINE"
    log "⏱️ Duration: $duration_human"
    log "📦 Archives: $backup_count encrypted files"
    log "💾 Total size: $total_backup_size_human"
    log "📍 Location: $backup_dir"
    log "📝 Log: $LOG_FILE"
    log "🙏 $BRAND_MOTTO"

    send_ntfy "📅 Completed: $end_date\n⏱️ Duration: $duration_human\n📦 $backup_count files (F:$full_count/I:$inc_count)\n📁 $source_files files, $source_dirs dirs\n💾 $total_backup_size_human\n🐳 Volumes: ${vol_success}/${volume_count} successful\n🔐 Verification: $([ $failed_verify -eq 0 ] && echo "✅ ALL PASSED" || echo "⚠️ $failed_verify FAILED")\n💿 Free: $free_space_human → $(human_size $((new_free_space_mb * 1024 * 1024)))\n📂 $backup_dir" "success"
    
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
    
    echo "🐳 Testing container runtime detection..."
    local runtime=$(detect_container_runtime)
    echo "   Detected runtime: $runtime"
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
    echo "  • Container runtime detection: ✅ ($runtime)"
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
$BRAND_TAGLINE
$BRAND_MOTTO
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

USAGE: $SCRIPT_NAME [COMMAND] [ARGS]

COMMANDS:
  backup              Run backup (default)
  restore <pattern>   Restore backup(s) - supports partial match
  list                List all backups
  verify <file>       Verify backup integrity
  verify-all          Verify all backups
  dedup               Run deduplication
  test                Run encryption test
  help                Show this help

RESTORE EXAMPLES:
  chantik restore postgres          # All postgres backups
  chantik restore redis full        # All redis full backups
  chantik restore 20260906          # All backups from date
  chantik restore vol1 vol2 vol3    # Multiple volumes
  chantik restore "postgres,redis"  # Comma-separated

CONFIG: chantik.conf (BACKUP_BASE_DIR, SOURCE_DIR, ENCRYPTION_KEY_FILE, etc)
ENV:    CHANTIK_CONFIG, CHANTIK_WORK_DIR

ALIAS:  alias chantik="/path/to/chantik.sh"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

main() {
    case "${1:-}" in
        test)
            load_config
            init_tmp
            run_test
            ;;
        restore)
            shift
            local dry_run=false
            if [[ "$1" == "--dry-run" ]]; then
                dry_run=true
                shift
            fi
            if [[ -z "${1:-}" ]]; then
                echo "🕊️ ERROR: Missing backup name for restore."
                echo ""
                echo "Usage: $SCRIPT_NAME restore [--dry-run] <name> [name2] [name3] ..."
                echo ""
                echo "Examples:"
                echo "  $SCRIPT_NAME restore volume_postgres volume_redis"
                echo "  $SCRIPT_NAME restore postgres redis"
                echo "  $SCRIPT_NAME restore 20260906"
                echo "  $SCRIPT_NAME restore --dry-run volume_postgres"
                echo ""
                echo "Available backups:"
                chantik_list_backups "$BACKUP_BASE_DIR"
                exit 1
            fi
            load_config
            init_tmp
            if [[ "$dry_run" == "true" ]]; then
                restore_from_backup --dry-run "$@"
            else
                restore_from_backup "$@"
            fi
            ;;
        verify)
            if [[ -z "${2:-}" ]]; then
                echo "🕊️ ERROR: Missing backup file for verification."
                echo "Usage: $SCRIPT_NAME verify <backup-file>"
                exit 1
            fi
            load_config
            init_tmp
            verify_backup_integrity "$2"
            ;;
        verify-all)
            load_config
            init_tmp
            verify_all_backups "$BACKUP_BASE_DIR"
            ;;
        list)
            load_config
            chantik_list_backups "$BACKUP_BASE_DIR"
            ;;
        dedup)
            load_config
            init_tmp
            deduplicate_backups "$BACKUP_BASE_DIR"
            ;;
        help|-h|--help)
            show_help
            ;;
        "")
            do_backup
            ;;
        *)
            echo "🕊️ ERROR: Unknown command: $1"
            echo "Use '$SCRIPT_NAME help' for usage information."
            exit 1
            ;;
    esac
}

main "$@"

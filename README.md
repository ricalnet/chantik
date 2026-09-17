# 🕊️ Chantik

<p align="center">
  <strong>ChaCha20-Authenticated Backup Protection for Docker/Podman Directories and Volumes</strong><br>
  with authenticated encryption, compression, smart retention, incremental backups, deduplication, and real-time notifications.
</p>

<p align="center">
  <a href="https://opensource.org/licenses/MIT">
    <img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT">
  </a>
  <a href="https://www.gnu.org/software/bash/">
    <img src="https://img.shields.io/badge/Bash-4EAA25?logo=gnu-bash&logoColor=white" alt="Bash">
  </a>
  <a href="https://www.docker.com/">
    <img src="https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white" alt="Docker">
  </a>
  <a href="https://podman.io/">
    <img src="https://img.shields.io/badge/Podman-892CA0?logo=podman&logoColor=white" alt="Podman">
  </a>
  <a href="https://www.openssl.org/">
    <img src="https://img.shields.io/badge/ChaCha20--Poly1305-721412?logo=openssl&logoColor=white" alt="ChaCha20-Poly1305">
  </a>
  <br>
  <a href="https://git.ricalnet.my.id/chantik">
    <img src="https://img.shields.io/badge/Platform-Linux%20%7C%20macOS-important" alt="Platform">
  </a>
  <a href="https://git.ricalnet.my.id/chantik/graphs/commit-activity">
    <img src="https://img.shields.io/badge/Maintained-yes-green.svg" alt="Maintenance">
  </a>
</p>

<hr>

## 🕊️ Overview

> **Chantik** — A robust backup solution, originally built for the [digital-independence](https://git.ricalnet.my.id/digital-independence) project, now available for general use. Chantik provides protection with ChaCha20-Poly1305 authenticated encryption, smart retention policies, and comprehensive automation features.

### ✨ Key Features

| Feature | Description |
|---------|-------------|
| 🔐 Authenticated Encryption | ChaCha20-Poly1305 (primary) with AES-256-CBC fallback |
| 🔑 Strong Key Derivation | PBKDF2 with configurable iterations (default: 600,000) |
| 🔗 Deduplication | Fixed nonce support for deterministic encryption |
| 🗜️ Compression | Gzip with configurable level (1-9) |
| 🐳 Container Support | Backup and restore Docker and Podman volumes |
| 🔄 Incremental Backup | Saves storage and speeds up backups |
| 📊 Smart Retention | Daily, weekly, and monthly retention policies |
| 🔔 Real-time Notifications | Instant alerts via ntfy.sh |
| ✅ Integrity Verification | SHA256 checksum verification for every backup |
| 🔒 Security | Configurable permissions and process locking |
| 📝 Comprehensive Logging | Detailed logs for auditing and troubleshooting |
| 🎯 Multi-Container Runtime | Supports Docker and Podman automatically |

## 🚀 Quick Start

### Prerequisites

Ensure your system has:

```bash
- Bash 4.0+
- Docker or Podman (if backing up volumes)
- OpenSSL with ChaCha20 support
- gzip, tar, curl
- find, grep, sed, awk
- df, du, hostname, sha256sum
```

### Installation

1. Clone the repository:
   ```bash
   git clone https://git.ricalnet.my.id/chantik.git
   cd chantik
   ```

2. Set up an alias for ease of use:
   ```bash
   # For Zsh (common on macOS and most modern Linux distros)
   nano ~/.zshrc
   
   # Or for Bash (default on many systems)
   nano ~/.bashrc
   
   # Add the following line to the appropriate file:
   alias chantik='/path/to/chantik/chantik.sh'
   
   # Example: if you cloned to /home/user/chantik
   alias chantik='/home/user/chantik/chantik.sh'
   
   # Save the file and reload the configuration:
   source ~/.zshrc   # or source ~/.bashrc
   
   # Now you can run Chantik from anywhere:
   chantik backup
   chantik list
   chantik restore postgres_data
   ```

3. Generate an encryption key:
   ```bash
   openssl rand -base64 32 > encryption.key
   chmod 600 encryption.key
   ```

4. (Optional) Generate a fixed salt for deduplication:
   ```bash
   openssl rand -hex 8 > fixed_salt.txt
   chmod 600 fixed_salt.txt
   ```

5. Create a configuration from the example:
   ```bash
   cp chantik.conf.example chantik.conf
   ```

6. Edit the configuration with your settings:
   ```bash
   nano chantik.conf
   ```

7. Make the script executable:
   ```bash
   chmod +x chantik.sh
   ```

8. Test the encryption system:
   ```bash
   chantik test
   ```

### Run Your First Backup

```bash
chantik backup

# Example output:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-09-09 23:06:03] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-09-09 23:06:03] 🕊️ Starting Chantik (v0.1.4)
[2026-09-09 23:06:03] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-09-09 23:06:03] 💬 ChaCha20-Authenticated Backup Protection
[2026-09-09 23:06:03] 🙏 In ChaCha We Trust — Authentically Secured
[2026-09-09 23:06:03] 
✅ Config loaded: /home/user/chantik/chantik.conf
✅ Runtime: podman
[2026-09-09 23:06:06] 🐳 Container runtime: podman
[2026-09-09 23:06:06] 📁 Source: /home/user/my-projects
[2026-09-09 23:06:06] 📊 Size: 78.4 KB (33 files, 23 dirs)
[2026-09-09 23:06:06] 🐳 Volumes: 37 volumes
[2026-09-09 23:06:06] 💾 Target: /path/kto/BACKUP/my-bacups
[2026-09-09 23:06:06] 💿 Free: 761.6 GB
[2026-09-09 23:06:06] 🔒 Encryption: CHACHA20
[2026-09-09 23:06:06] 🔑 PBKDF2: 600000
[2026-09-09 23:06:06] 🔗 Dedup: DISABLED
[2026-09-09 23:06:06] 🗜️ Compression: gzip level 6
[2026-09-09 23:06:06] 📋 Retention: D7/W4/M6
[2026-09-09 23:06:06] 🔄 Incremental: ENABLED (7 days)
[2026-09-09 23:06:07] 📂 Backup directory created: /path/to/BACKUP/my-backups/chantik-backup_20260909_230607
[2026-09-09 23:06:08] 📦 INCREMENTAL backup of /home/user/my-projects (since 2026-09-09 22:56:24)
[2026-09-09 23:06:08] Backing up directory: /home/user/my-projects
[2026-09-09 23:06:08] Creating INCREMENTAL backup archive...
[2026-09-09 23:06:08] 📊 Found 33 changed files
[2026-09-09 23:06:08] 🗜️ Compressing...
[2026-09-09 23:06:08] ✅ Compression complete
[2026-09-09 23:06:08] ✅ INCREMENTAL backup: digital-independence_20260909_230607_inc.tar.gz.enc (31.2 KB)
[2026-09-09 23:06:08] 📦 Podman volume 1: element_nginx_conf
[2026-09-09 23:06:08] 📦 INCREMENTAL backup of volume: element_nginx_conf (since 2026-09-09 22:56:37)
[2026-09-09 23:06:08] 📦 Backing up volume: element_nginx_conf
element_nginx_conf_snapshot_19911
ddbb9a592b309c9c79d3190869757428ece7e9f38315d25e7e5a1cef40764aa0
chantik_copy_19911
[2026-09-09 23:06:22] Creating INCREMENTAL backup archive for volume...
element_nginx_conf_snapshot_19911
[2026-09-09 23:06:23] 🗜️ Compressing...
[2026-09-09 23:06:23] ✅ FULL volume backup: volume_element_nginx_conf_20260909_230608_inc.tar.gz.enc (606 B)
[2026-09-09 23:06:23] ✅ Podman volume element_nginx_conf backed up successfully
```

## 📋 Configuration Guide

### Essential Configuration

| Variable | Description | Example |
|----------|-------------|---------|
| `BACKUP_BASE_DIR` | Where encrypted backups are stored | `/media/backup` |
| `SOURCE_DIR` | Main directory to back up | `/home/user/digital-independence` |
| `DOCKER_VOLUMES` | Docker volume names | `("postgres_data" "redis_cache")` |
| `PODMAN_VOLUMES` | Podman volume names | `("podman_data" "podman_config")` |
| `CONTAINER_RUNTIME` | Container runtime (auto/docker/podman) | `auto` |
| `ENCRYPTION_KEY_FILE` | Path to encryption key | `/home/user/chantik/encryption.key` |
| `NTFY_TOPIC` | ntfy.sh topic for notifications | `my-backup-topic` |
| `NTFY_TOKEN` | ntfy.sh authentication token | `tk_xxxxxxxxxxxxxxxx` |

### Advanced Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `ENCRYPTION_CIPHER` | Cipher used (auto-detected) | `chacha20` |
| `PBKDF2_ITERATIONS` | Key derivation iterations (100,000+) | `600000` |
| `FIXED_SALT_FILE` | Fixed salt for deterministic encryption | (optional) |
| `INCREMENTAL_ENABLED` | Enable incremental backups | `true` |
| `FULL_BACKUP_INTERVAL` | Days between full backups | `7` |
| `RETENTION_DAILY` | Number of daily backups to keep | `7` |
| `RETENTION_WEEKLY` | Number of weekly backups to keep | `4` |
| `RETENTION_MONTHLY` | Number of monthly backups to keep | `6` |
| `GZIP_LEVEL` | Compression level (1-9) | `6` |
| `DEDUP_TOOL` | Deduplication tool (hardlink/jdupes) | `hardlink` |
| `VERBOSE` | Enable detailed debug output | `false` |
| `BACKUP_PREFIX` | Backup directory prefix | `chantik-backup` |
| `EXCLUDE_PATTERNS` | File/directory exclusion patterns | `*.tmp,*.log` |
| `MAX_BACKUP_SIZE_MB` | Maximum backup size limit | `0` (unlimited) |
| `NTFY_CUSTOM_SERVER` | Custom ntfy server URL | (empty) |
| `DOCKER_IMAGE` | Image for helper container | `alpine:latest` |

### Configuration Examples

<details>
<summary><b>Enabling Deduplication</b></summary>

Generate a fixed salt:
```bash
openssl rand -hex 8 > fixed_salt.txt
chmod 600 fixed_salt.txt
```

In `chantik.conf`:
```bash
FIXED_SALT_FILE="/path/to/fixed_salt.txt"
DEDUP_TOOL="hardlink"
```
</details>

<details>
<summary><b>Using Podman</b></summary>

In `chantik.conf`:
```bash
CONTAINER_RUNTIME="podman"
PODMAN_VOLUMES=(
    "postgres_data"
    "redis_cache"
)
```
</details>

<details>
<summary><b>Custom ntfy Server</b></summary>

In `chantik.conf`:
```bash
NTFY_CUSTOM_SERVER="https://ntfy.your-domain.com"
```
</details>

## 🔄 Command Reference

### Basic Commands

```bash
# Run a backup (full or incremental based on config)
chantik backup

# Test the encryption/decryption system
chantik test

# List all available backups
chantik list

# Verify the integrity of a specific backup
chantik verify /path/to/backup.enc

# Verify all backups
chantik verify-all

# Restore from backup
chantik restore <pattern>

# Restore with dry-run (no changes)
chantik restore --dry-run <pattern>

# Restore multiple backups at once
chantik restore volume_postgres volume_redis

# Run deduplication on the backup directory
chantik dedup

# Show help
chantik help
```

### Restore Command Examples

```bash
# Restore all backups matching 'postgres'
chantik restore postgres

# Restore backups from a specific date
chantik restore 20260906

# Restore multiple volumes at once
chantik restore vol1 vol2 vol3

# Restore with comma separator
chantik restore "postgres,redis"

# Dry-run restore (see what would be restored)
chantik restore --dry-run postgres
```

### Backup Naming Convention

```
chantik-backup_YYYYMMDD_HHMMSS/
├── digital-independence_YYYYMMDD_HHMMSS_full.tar.gz.enc     # Full backup
├── digital-independence_YYYYMMDD_HHMMSS_inc.tar.gz.enc      # Incremental backup
├── volume_postgres_data_YYYYMMDD_HHMMSS_full.tar.gz.enc     # Full volume backup
├── volume_redis_cache_YYYYMMDD_HHMMSS_inc.tar.gz.enc        # Incremental volume backup
├── *.checksums                                              # SHA256 checksums
└── *.enc.checksums                                          # Encrypted file checksums
```

## 🔐 Security

### Encryption Details

- Primary cipher is ChaCha20‑Poly1305 (authenticated encryption)
- Fallback cipher is AES‑256‑CBC with PBKDF2 key derivation
- Key derivation uses PBKDF2 with configurable iterations (default 600,000)
- Key strength is 256‑bit encryption
- Integrity is guaranteed by SHA256 checksums for verification
- Every backup is verified against potential tampering
- Fixed nonce support for deterministic deduplication

### Security Best Practices

1. Never commit configuration to version control
2. Protect the encryption key: `chmod 600 encryption.key`
3. Store the encryption key separately from backups
4. Use a strong ntfy.sh token
5. Rotate encryption keys regularly
6. Test restores periodically
7. Use high PBKDF2 iterations (600,000+)

### Key Management

Generate a new encryption key:
```bash
openssl rand -base64 32 > encryption.key
chmod 600 encryption.key
```

Generate a fixed salt for deduplication:
```bash
openssl rand -hex 8 > fixed_salt.txt
chmod 600 fixed_salt.txt
```

Back up the encryption key separately (GPG):
```bash
gpg -c encryption.key
```

## 🔔 Notifications

Chantik integrates with [ntfy.sh](https://ntfy.sh/) for real-time notifications.

### Setting Up Notifications

1. Get an ntfy token: Visit https://ntfy.sh/account
2. Choose a unique topic name
3. Configure in `chantik.conf`:
   ```bash
   NTFY_TOPIC="my-backup-topic"
   NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
   ```

### Notification Types

| Type | Priority | Tag | When Triggered |
|------|----------|------|----------------|
| Success | 3 (default) | ✅ | Backup completed successfully |
| Error | 5 (urgent) | 🔴 | Backup failed or interrupted |
| Info | 3 | ℹ️ | Backup started, config loaded |
| Restore | 3 | 🔄 | Restore operation completed |

## 🗄️ Retention & Rotation

Chantik uses a smart retention policy:

1. Daily backups: Keep the last `RETENTION_DAILY` days (default: 7)
2. Weekly backups: Keep the last `RETENTION_WEEKLY` weeks (default: 4)
3. Monthly backups: Keep the last `RETENTION_MONTHLY` months (default: 6)

### Retention Logic

```bash
# Example retention timeline
Retention: Daily=7, Weekly=4, Monthly=6

# Backups retained:
Day 1-7:      All daily backups
Week 1-4:     One backup per week
Month 1-6:    One backup per month
Older:        Deleted
```

## 🐳 Container Integration

Chantik can back up and restore Docker and Podman volumes:

### Backing Up Container Volumes

```bash
# In chantik.conf - Use Docker
DOCKER_VOLUMES=(
    "postgres_data"
    "redis_cache"
    "nginx_conf"
)
CONTAINER_RUNTIME="docker"

# Or use Podman
PODMAN_VOLUMES=(
    "postgres_data"
    "redis_cache"
)
CONTAINER_RUNTIME="podman"

# Or let it auto-detect
CONTAINER_RUNTIME="auto"

# Each volume gets its own encrypted backup
volume_postgres_data_20260808_100000_full.tar.gz.enc
volume_redis_cache_20260808_100000_inc.tar.gz.enc
```

### Auto-Detecting the Runtime

Chantik will detect the available container runtime:
1. If `CONTAINER_RUNTIME` is set to `docker` or `podman`, use that
2. If `auto`, check Podman first, then Docker
3. If no runtime is found, an error will appear

### Restoring Container Volumes

```bash
# Restore a volume (auto-detects runtime)
chantik restore postgres_data

# Restore multiple volumes at once
chantik restore postgres_data redis_cache

# Restore with dry-run
chantik restore --dry-run postgres_data

# Output:
[2026-08-08 10:30:00] 🦑 Restoring type: volume_postgres_data
[2026-08-08 10:30:00] 🔐 Decrypting...
[2026-08-08 10:30:05] ✅ Checksum verification passed.
[2026-08-08 10:30:10] 📦 Restoring volume: postgres_data
[2026-08-08 10:30:15] ✅ Volume restore complete for postgres_data
```

## 🤖 Automation

### Cron Job Examples

```bash
# Edit crontab
sudo crontab -e

# Daily backup at 2:00 AM
0 2 * * * /usr/local/bin/chantik backup >> /var/log/chantik-cron.log 2>&1

# Weekly full backup on Sunday at 3:00 AM
0 3 * * 0 /usr/local/bin/chantik backup >> /var/log/chantik-cron.log 2>&1

# Backup with verbose logging
0 2 * * * VERBOSE=true /usr/local/bin/chantik backup >> /var/log/chantik-cron.log 2>&1

# Backup with custom configuration
0 2 * * * CHANTIK_CONFIG=/etc/chantik/prod.conf /usr/local/bin/chantik backup
```

### Schedule Examples

| Schedule | Cron Expression | Description |
|----------|----------------|-------------|
| Daily | `0 2 * * *` | Every day at 2:00 AM |
| Hourly | `0 * * * *` | Every hour |
| Weekly | `0 3 * * 0` | Every Sunday at 3:00 AM |
| Monthly | `0 4 1 * *` | 1st of every month at 4:00 AM |

### Environment Variables

```bash
# Specify a custom configuration
CHANTIK_CONFIG=/path/to/chantik.conf

# Specify the working directory
CHANTIK_WORK_DIR=/path/to/workdir

# Enable verbose
VERBOSE=true

# Use in cron
0 2 * * * CHANTIK_CONFIG=/etc/chantik/prod.conf VERBOSE=false /usr/local/bin/chantik backup
```

## 🛠️ Troubleshooting

### Common Issues

ChaCha20 not supported:
```bash
⚠️ WARNING: ChaCha20-Poly1305 not supported; falling back to AES-256-CBC.
```
*The script will automatically use AES-256-CBC as a fallback.*

Insufficient disk space:
```bash
# Check available space
df -h /media/backup

# Reduce retention or increase storage
RETENTION_DAILY=3
RETENTION_WEEKLY=2
```

Key file errors:
```bash
# If a previous backup was interrupted
rm -f /path/to/chantik/.chantik.lock
# Or remove the lock directory
rm -rf /path/to/chantik/.chantik.lock.dir
```

Container runtime not detected:
```bash
# Check Docker
docker info

# Check Podman
podman info

# Set the runtime explicitly in the config
CONTAINER_RUNTIME="docker"  # or "podman"
```

### Debug Mode

Enable verbose mode:
```bash
VERBOSE=true chantik backup
```

Check the log:
```bash
tail -f chantik.log
# or if the log is in a custom location
tail -f /path/to/chantik.log
```

Test the encryption system:
```bash
chantik test
```

## 📊 Performance Optimization

### Recommended Settings

| Scenario | GZIP_LEVEL | PBKDF2_ITERATIONS | INCREMENTAL_ENABLED |
|----------|------------|-------------------|-------------------|
| Daily backup | 6 | 600000 | true |
| Large files | 3 | 600000 | false |
| Maximum compression | 9 | 600000 | true |
| Speed priority | 1 | 100000 | false |
| Security priority | 6 | 1000000 | true |

### Storage Optimization

Use deduplication with a fixed salt:
```bash
FIXED_SALT_FILE="/path/to/fixed_salt.txt"
DEDUP_TOOL="hardlink"
```

Use incremental backups:
```bash
INCREMENTAL_ENABLED=true
FULL_BACKUP_INTERVAL=14
```

More aggressive compression:
```bash
GZIP_LEVEL=9
```

### Multi-Runtime Support

Chantik detects and uses the available runtime:
- **Podman**: Detected first (if available)
- **Docker**: Used as a fallback
- **Manual**: Set `CONTAINER_RUNTIME` explicitly

## 🧪 Testing

Run the full test suite:
```bash
chantik test
```

The test suite verifies:
- ChaCha20 encryption/decryption (text and binary)
- AES-256-CBC fallback
- PBKDF2 compatibility
- Fixed nonce deduplication (if configured)
- Container runtime detection

## 🏗️ Directory Structure

```
chantik/
├── chantik.sh              # Main script
├── chantik.conf            # Configuration (create from example)
├── chantik.conf.example    # Example configuration
├── encryption.key          # Encryption key (generate your own)
├── fixed_salt.txt          # Fixed salt (optional)
├── chantik.log             # Log file
├── .chantik.lock           # Lock file (automatic)
├── .chantik.lock.dir/      # Lock directory (automatic)
├── .tmp/                   # Temporary directory
└── .incremental/           # Incremental snapshot data
    ├── dir_digital-independence.snar
    ├── vol_postgres_data.snar
    └── vol_redis_cache.snar
```

## 🙏 Acknowledgements

- ChaCha20-Poly1305 - Authenticated encryption
- OpenSSL - Cryptographic operations
- ntfy.sh - Notification service
- Docker & Podman - Container volume backups
- Alpine Linux - Lightweight container image

## 📄 License

MIT License - See the [LICENSE](LICENSE) file for details.
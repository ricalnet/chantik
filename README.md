<h1 align="center">🕊️ Chantik</h1>

<p align="center">
  <strong>ChaCha20-Authenticated Backup Protection for Directories and Docker Volumes</strong><br>
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
  <a href="https://www.openssl.org/">
    <img src="https://img.shields.io/badge/ChaCha20--Poly1305-721412?logo=openssl&logoColor=white" alt="ChaCha20-Poly1305">
  </a>
  <br>
  <a href="https://github.com/ricalnet/chantik">
    <img src="https://img.shields.io/badge/Platform-Linux%20%7C%20macOS-important" alt="Platform">
  </a>
  <a href="https://github.com/ricalnet/chantik/graphs/commit-activity">
    <img src="https://img.shields.io/badge/Maintained-yes-green.svg" alt="Maintenance">
  </a>
</p>

<hr>

## 🕊️ Overview

> **Chantik** — A robust backup solution originally created for the [digital-independence](https://github.com/ricalnet/digital-independence) project, now available for general use. Chantik provides protection with ChaCha20-Poly1305 authenticated encryption, smart retention policies, and comprehensive automation features.

### ✨ Key Features

| Feature | Description |
|---------|-------------|
| 🔐 Authenticated Encryption | ChaCha20-Poly1305 (primary) with AES-256-CBC fallback |
| 🔑 Strong Key Derivation | PBKDF2 with configurable iterations (default: 600,000) |
| 🔗 Deduplication | Fixed nonce support for deterministic encryption |
| 🗜️ Compression | Gzip with configurable levels (1-9) |
| 🐳 Docker Support | Seamless backup and restore of Docker volumes |
| 🔄 Incremental Backups | Save storage and speed up backups |
| 📊 Smart Retention | Daily, weekly, and monthly retention policies |
| 🔔 Real-time Notifications | Instant alerts via ntfy.sh |
| ✅ Integrity Verification | SHA256 checksum verification for every backup |
| 🔒 Security | Configurable permissions and process locking |
| 📝 Comprehensive Logging | Detailed logs for auditing and troubleshooting |

## 🚀 Quick Start

### Prerequisites

Ensure your system has:

```bash
- Bash 4.0+
- Docker (if backing up Docker volumes)
- OpenSSL 1.1.1+ (with ChaCha20 support)
- gzip
- tar
- curl
- find
- grep
- sed
- awk
- df
- du
- hostname
- sha256sum
```

### Installation

1. Clone repository:
   ```bash
   git clone https://github.com/ricalnet/chantik.git
   cd chantik
   ```

2. Generate encryption key:
   ```bash
   openssl rand -base64 32 > encryption.key
   chmod 600 encryption.key
   ```

3. (Optional) Generate fixed salt for deduplication:
   ```bash
   openssl rand -hex 8 > fixed_salt.txt
   chmod 600 fixed_salt.txt
   ```

4. Create configuration from example:
   ```bash
   cp chantik.conf.example chantik.conf
   ```

5. Edit configuration with your settings:
   ```bash
   nano chantik.conf
   ```

6. Make script executable:
   ```bash
   chmod +x chantik.sh
   ```

7. Test the encryption system:
   ```bash
   ./chantik.sh --test
   ```

### Perform First Backup

```bash
# Perform backup
sudo ./chantik.sh

# Example output:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-08-08 10:00:00] 🕊️ Starting Chantik (v0.1.1)
[2026-08-08 10:00:00] 💬 ChaCha20-Authenticated Backup Protection
[2026-08-08 10:00:00] 🙏 In ChaCha We Trust — Authentically Secured
[2026-08-08 10:00:00] 
✅ Configuration loaded successfully
[2026-08-08 10:00:00] 📁 Source: /home/user/digital-independence
[2026-08-08 10:00:00] 📊 Size: 156.2 MB (1,234 files)
[2026-08-08 10:00:00] 🔒 Encryption: CHACHA20
[2026-08-08 10:00:00] 📦 Performing FULL backup...
[2026-08-08 10:00:45] ✅ FULL encrypted backup created: digital-independence_20260808_100000_full.tar.gz.enc (28.3 MB)
[2026-08-08 10:01:35] ✅ Backup completed successfully
[2026-08-08 10:01:35] ⏱️ Duration: 1m 35s
[2026-08-08 10:01:35] 📦 Archives: 12 encrypted files
[2026-08-08 10:01:35] 💾 Total size: 117.1 MB
[2026-08-08 10:01:35] 📍 Location: /media/backup/chantik-backup_20260808_100000
[2026-08-08 10:01:35] 🙏 In ChaCha We Trust — Authentically Secured
```

## 📋 Configuration Guide

### Essential Configuration

| Variable | Description | Example |
|----------|-------------|---------|
| `BACKUP_BASE_DIR` | Where encrypted backups are stored | `/media/backup` |
| `SOURCE_DIR` | Main directory to backup | `/home/user/digital-independence` |
| `DOCKER_VOLUMES` | Array of Docker volume names | `("postgres_data" "redis_cache")` |
| `ENCRYPTION_KEY_FILE` | Path to encryption key | `/home/user/chantik/encryption.key` |
| `NTFY_TOPIC` | ntfy.sh topic for notifications | `my-backup-topic` |
| `NTFY_TOKEN` | ntfy.sh authentication token | `tk_xxxxxxxxxxxxxxxx` |

### Advanced Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `ENCRYPTION_CIPHER` | Cipher to use (auto-detected) | `chacha20` |
| `PBKDF2_ITERATIONS` | Key derivation iterations (100,000+) | `600000` |
| `FIXED_SALT_FILE` | Fixed salt for deterministic encryption | (optional) |
| `INCREMENTAL_ENABLED` | Enable incremental backups | `true` |
| `FULL_BACKUP_INTERVAL` | Days between full backups | `7` |
| `RETENTION_DAILY` | Number of daily backups to keep | `7` |
| `RETENTION_WEEKLY` | Number of weekly backups to keep | `4` |
| `RETENTION_MONTHLY` | Number of monthly backups to keep | `6` |
| `GZIP_LEVEL` | Compression level (1-9) | `6` |
| `DEDUP_TOOL` | Deduplication tool | `hardlink` |
| `VERBOSE` | Enable detailed debug output | `false` |
| `MAX_BACKUP_SIZE_MB` | Maximum backup size limit | `0` (unlimited) |
| `EXCLUDE_PATTERNS` | Files/directories to exclude | `*.tmp,*.log` |
| `NTFY_CUSTOM_SERVER` | Custom ntfy server URL | (empty) |

### Configuration Examples

<details>
<summary><b>Enable Deduplication</b></summary>

Generate fixed salt:
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
<summary><b>Disable Incremental Backups</b></summary>

In `chantik.conf`:
```bash
INCREMENTAL_ENABLED=false
```
</details>

<details>
<summary><b>Custom ntfy Server</b></summary>

In `chantik.conf`:
```bash
NTFY_CUSTOM_SERVER="https://your-ntfy-server.com"
```
</details>

## 🔄 Command Reference

### Basic Commands

```bash
# Perform a backup (full or incremental based on configuration)
./chantik.sh

# Test encryption/decryption system
./chantik.sh --test

# List all available backups
./chantik.sh --list

# Verify a specific backup's integrity
./chantik.sh --verify /path/to/backup.enc

# Verify all backups
./chantik.sh --verify-all

# Restore from a backup
./chantik.sh --restore /path/to/backup.enc

# Run deduplication on backup directory
./chantik.sh --dedup

# Show help
./chantik.sh --help
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
- Key strength is a 256‑bit encryption
- Integrity is ensured by SHA256 checksums for verification
- Every backup is verified for tampering

### Security Best Practices

1. Never commit configuration to version control
2. Protect encryption key: `chmod 600 encryption.key`
3. Store encryption key separately from backups
4. Use strong ntfy.sh tokens
5. Regularly rotate encryption keys
6. Test restoration periodically

### Key Management

Generate new encryption key:
```bash
openssl rand -base64 32 > encryption.key
chmod 600 encryption.key
```

Generate fixed salt for deduplication:
```bash
openssl rand -hex 8 > fixed_salt.txt
chmod 600 fixed_salt.txt
```

Backup encryption key separately (GPG):
```bash
gpg -c encryption.key
```

## 🔔 Notifications

Chantik integrates with [ntfy.sh](https://ntfy.sh/) for real-time notifications.

### Setting Up Notifications

1. Get ntfy token: Visit https://ntfy.sh/account
2. Choose a unique topic name
3. Configure in `chantik.conf`:
   ```bash
   NTFY_TOPIC="my-backup-topic"
   NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
   ```

### Notification Types

| Type | Priority | Tags | When Triggered |
|------|----------|------|----------------|
| Success | 3 (default) | ✅ | Backup completes successfully |
| Error | 5 (urgent) | 🔴 | Backup fails or is interrupted |
| Info | 3 | ℹ️ | Backup starts, configuration loaded |
| Restore | 3 | 🔄 | Restore operation completes |

## 🗄️ Retention & Rotation

Chantik uses a smart retention policy:

1. Daily backups: Keep last `RETENTION_DAILY` days (default: 7)
2. Weekly backups: Keep last `RETENTION_WEEKLY` weeks (default: 4)
3. Monthly backups: Keep last `RETENTION_MONTHLY` months (default: 6)

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

## 🐳 Docker Integration

Chantik can backup and restore Docker volumes:

### Backup Docker Volumes

```bash
# In chantik.conf
DOCKER_VOLUMES=(
    "postgres_data"
    "redis_cache"
    "nginx_conf"
)

# Each volume gets its own encrypted backup
volume_postgres_data_20260808_100000_full.tar.gz.enc
volume_redis_cache_20260808_100000_inc.tar.gz.enc
```

### Restore Docker Volumes

```bash
# Restore a Docker volume
./chantik.sh --restore /media/backup/volume_postgres_data_20260808_100000_full.tar.gz.enc

# Output:
[2026-08-08 10:30:00] 🦑 Restoring type: volume_postgres_data
[2026-08-08 10:30:00] 🔐 Decrypting...
[2026-08-08 10:30:05] ✅ Checksum verification passed.
[2026-08-08 10:30:10] 📦 Restoring Docker volume: postgres_data
[2026-08-08 10:30:15] ✅ Volume restore completed for postgres_data
```

## 🤖 Automation

### Cron Job Examples

```bash
# Edit crontab
sudo crontab -e

# Daily backup at 2:00 AM
0 2 * * * /path/to/chantik.sh >> /path/to/backup-cron.log 2>&1

# Weekly full backup on Sunday at 3:00 AM
0 3 * * 0 /path/to/chantik.sh >> /path/to/backup-cron.log 2>&1

# Backup with verbose logging
0 2 * * * VERBOSE=true /path/to/chantik.sh >> /path/to/backup-cron.log 2>&1
```

### Schedule Examples

| Schedule | Cron Expression | Description |
|----------|----------------|-------------|
| Daily | `0 2 * * *` | Every day at 2:00 AM |
| Hourly | `0 * * * *` | Every hour |
| Weekly | `0 3 * * 0` | Every Sunday at 3:00 AM |
| Monthly | `0 4 1 * *` | First of every month at 4:00 AM |

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

Lock file error:
```bash
# If a previous backup was interrupted
rm /path/to/chantik/.chantik.lock
```

### Debug Mode

Enable verbose mode:
```bash
VERBOSE=true ./chantik.sh
```

Check logs:
```bash
tail -f chantik.log
```

Test encryption system:
```bash
./chantik.sh --test
```

## 📊 Performance Optimization

### Recommended Settings

| Scenario | GZIP_LEVEL | PBKDF2_ITERATIONS | INCREMENTAL_ENABLED |
|----------|------------|-------------------|-------------------|
| Daily backups | 6 | 600000 | true |
| Large files | 3 | 600000 | false |
| Maximum compression | 9 | 600000 | true |
| Speed priority | 1 | 100000 | false |
| Security priority | 6 | 1000000 | true |

### Storage Optimization

Use deduplication with fixed salt:
```bash
FIXED_SALT_FILE="/path/to/fixed_salt.txt"
DEDUP_TOOL="hardlink"
```

Use incremental backups:
```bash
INCREMENTAL_ENABLED=true
FULL_BACKUP_INTERVAL=14
```

Compress more aggressively:
```bash
GZIP_LEVEL=9
```

## 🧪 Testing

Run the complete test suite:
```bash
./chantik.sh --test
```

The test suite verifies:
- ChaCha20 encryption/decryption
- AES-256-CBC fallback
- PBKDF2 compatibility
- Fixed nonce deduplication

## 🙏 Acknowledgements

- ChaCha20-Poly1305 - Authenticated encryption
- OpenSSL - Cryptographic operations
- ntfy.sh - Notification service
- Docker - Container volume backup
- Alpine Linux - Lightweight container image

## 📄 License

MIT License - See [LICENSE](LICENSE) file for details.

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## 📞 Support

- 📧 Issues: [GitHub Issues](https://github.com/ricalnet/chantik/issues)
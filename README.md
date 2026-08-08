

<h1 align="center">🔐 Encrypted Backup System</h1>

<p align="center">
  <strong>Enterprise-grade backup solution for directories and Docker volumes</strong><br>
  with encryption, compression, smart retention, and real-time notifications.
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
    <img src="https://img.shields.io/badge/AES--256--CBC-721412?logo=logoColor=white" alt="OpenSSL">
  </a>
  <br>
  <a href="https://github.com/ricalnet/encrypted-backup-system">
    <img src="https://img.shields.io/badge/Platform-Linux%20%7C%20macOS-important" alt="Platform">
  </a>
  <a href="https://github.com/ricalnet/encrypted-backup-system/graphs/commit-activity">
    <img src="https://img.shields.io/badge/Maintained-yes-green.svg" alt="Maintenance">
  </a>
</p>

<hr>

## Overview

>  This script was originally created for the [digital-independence](https://github.com/ricalnet/digital-independence) project, but it can also be used for **general** purposes — making it versatile for any backup needs.

| Feature | Description |
|---------|-------------|
| 🔐 Encryption | AES-256-CBC encryption using OpenSSL |
| 🗜️ Compression | Gzip compression with configurable levels |
| 🐳 Docker Support | Backup Docker volumes seamlessly |
| 📊 Smart Retention | Automatic cleanup of old backups |
| 🔔 Notifications | Real-time alerts via ntfy.sh |
| ✅ Verification | MD5 and SHA256 checksums |
| 🔒 Security | Configurable permissions and locking |
| 📝 Logging | Detailed logs for auditing |

## Prerequisites

Before starting, ensure your system has:

```bash
- Bash
- Docker (if backing up Docker volumes)
- OpenSSL
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
```

Install missing packages:

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install -y openssl gzip tar curl coreutils

# RHEL/CentOS/Fedora
sudo yum install -y openssl gzip tar curl coreutils

# Alpine Linux
apk add openssl gzip tar curl coreutils

# macOS (using Homebrew)
brew install openssl gzip tar curl coreutils
```

## Quick Start

1. Clone repository:
    ```bash
    git clone https://github.com/ricalnet/encrypted-backup-system.git
    cd encrypted-backup-system
    ```

2. Generate encryption key:
    ```bash
    openssl rand -base64 32 > encryption.key
    chmod 600 encryption.key
    ```

3. Create configuration from template:
    ```bash
    cp backup.conf.example backup.conf
    ```

4. Edit configuration with your settings
    ```bash
    nano backup.conf
    ```

5. Make script executable
    ```bash
    chmod +x backup.sh
    ```

6. Run your first backup:
    ```bash
    sudo ./backup.sh
    ```

### Perform First Backup

Run your first full backup:

```bash
# Perform backup
sudo ./backup.sh

# Watch the output:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[yyy-mm-dd HH:MM:SS] 🚀 Starting backup
[yyy-mm-dd HH:MM:SS] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Configuration loaded successfully from: /path/to/encrypted-backup-system/backup.conf
[yyy-mm-dd HH:MM:SS] 📁 Source: /path/to/source-directory
[yyy-mm-dd HH:MM:SS] 📊 Size: 6.9 MB (951 files)
[yyy-mm-dd HH:MM:SS] 🐳 Volumes: 1 volumes
[yyy-mm-dd HH:MM:SS] 💾 Target: /path/to/BACKUP
[yyy-mm-dd HH:MM:SS] 💿 Free space: 766.7 GB
[yyy-mm-dd HH:MM:SS] 🔒 Encryption: AES-256-CBC
[yyy-mm-dd HH:MM:SS] 🗜️ Compression: gzip level 6
[yyy-mm-dd HH:MM:SS] 📋 Retention: 7 daily backups
[yyy-mm-dd HH:MM:SS] 📂 Backup directory created: /path/to/BACKUP/backup_xxxxxxxx_xxxxxx
[yyy-mm-dd HH:MM:SS] ..........
[yyy-mm-dd HH:MM:SS] ✅ Encrypted backup created: digital-independence.tar.gz.enc
[yyy-mm-dd HH:MM:SS] ..........
[yyy-mm-dd HH:MM:SS] ✅ Encrypted volume backup created: volume_docker.tar.gz.enc
[yyy-mm-dd HH:MM:SS] ✅ All backups verified.
[yyy-mm-dd HH:MM:SS] Rotating backups in /media/user/BACKUP
[yyy-mm-dd HH:MM:SS] ✅ Rotation completed successfully
[yyy-mm-dd HH:MM:SS] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[yyy-mm-dd HH:MM:SS] ✅ Backup completed successfully
[yyy-mm-dd HH:MM:SS] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[yyy-mm-dd HH:MM:SS] ..........
```

## Restore from Backup

Restore a single backup file:
```bash
sudo ./backup.sh --restore /path/to/backup/file.enc
```

Example: Restore entire directory:
```bash
sudo ./backup.sh --restore /home/user/backups/backup_20260808_100005/digital-independence_20260808_100005.tar.gz.enc
```

Example: Restore a Docker volume:
```bash
sudo ./backup.sh --restore /home/user/backups/backup_20260808_100005/volume_postgres_data_20260808_100005.tar.gz.enc
```

Output example:

```
[2026-08-08 10:30:00] Restoring type: volume_postgres_data
[2026-08-08 10:30:00] Decrypting volume_postgres_data_20260808_100005.tar.gz.enc to volume_postgres_data_20260808_100005.tar.gz
[2026-08-08 10:30:15] ✅ Checksum verification passed.
[2026-08-08 10:30:15] Decompressing volume_postgres_data_20260808_100005.tar.gz
[2026-08-08 10:30:30] Restoring Docker volume: postgres_data
[2026-08-08 10:30:35] ✅ Volume restore completed for postgres_data
[2026-08-08 10:30:35] ✅ Restore completed successfully.
```

## Automation

### Cron Job Setup

Set up automatic daily backups:

```bash
# Edit crontab
sudo crontab -e

# Add daily backup at 2:00 AM
0 2 * * * /home/user/encrypted-backup-system/backup.sh >> /home/user/encrypted-backup-system/backup-cron.log 2>&1

# Add weekly backup on Sunday at 3:00 AM
0 3 * * 0 /home/user/encrypted-backup-system/backup.sh >> /home/user/encrypted-backup-system/backup-cron.log 2>&1

# Add with verbose logging for debugging
0 2 * * * VERBOSE=true /home/user/encrypted-backup-system/backup.sh >> /home/user/encrypted-backup-system/backup-cron.log 2>&1
```

Cron schedule examples:

| Schedule | Cron Expression | Description |
|----------|----------------|-------------|
| Daily | `0 2 * * *` | Every day at 2:00 AM |
| Hourly | `0 * * * *` | Every hour |
| Weekly | `0 3 * * 0` | Every Sunday at 3:00 AM |
| Monthly | `0 4 1 * *` | First of every month at 4:00 AM |

## Useful Commands Cheatsheet

```bash
# Quick backup
./backup.sh

# Verbose backup
VERBOSE=true sudo ./backup.sh

# List all backups
sudo ./backup.sh --list

# Restore specific backup
sudo ./backup.sh --restore /path/to/backup.enc

# Check backup size
du -sh /backups/latest-backup

# Check encryption key
cat encryption.key

# Test encryption
openssl enc -aes-256-cbc -d -in backup.enc -out test.tar.gz -pass file:encryption.key
```

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Submit a pull request
<h1 align="center">🕊️ Chantik</h1>

<p align="center">
  <strong>ChaCha20-Authenticated Backup Protection untuk Direktori dan Volume Docker/Podman</strong><br>
  dengan enkripsi terotentikasi, kompresi, retensi cerdas, backup inkremental, deduplikasi, dan notifikasi waktu-nyata.
</p>

<p align="center">
  <a href="https://opensource.org/licenses/MIT">
    <img src="https://img.shields.io/badge/Lisensi-MIT-yellow.svg" alt="Lisensi: MIT">
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
    <img src="https://img.shields.io/badge/Dipelihara-yes-green.svg" alt="Pemeliharaan">
  </a>
</p>

<hr>

## 🕊️ Ikhtisar

> **Chantik** — Solusi backup yang tangguh, awalnya dibuat untuk proyek [digital-independence](https://git.ricalnet.my.id/digital-independence), kini tersedia untuk penggunaan umum. Chantik memberikan perlindungan dengan enkripsi terotentikasi ChaCha20-Poly1305, kebijakan retensi cerdas, dan fitur otomatisasi yang komprehensif.

### ✨ Fitur Utama

| Fitur | Deskripsi |
|---------|-------------|
| 🔐 Enkripsi Terotentikasi | ChaCha20-Poly1305 (utama) dengan fallback AES-256-CBC |
| 🔑 Derivasi Kunci Kuat | PBKDF2 dengan iterasi yang dapat dikonfigurasi (default: 600.000) |
| 🔗 Deduplikasi | Dukungan nonce tetap untuk enkripsi deterministik |
| 🗜️ Kompresi | Gzip dengan tingkat yang dapat dikonfigurasi (1-9) |
| 🐳 Dukungan Container | Backup dan pemulihan volume Docker dan Podman |
| 🔄 Backup Inkremental | Hemat penyimpanan dan percepat backup |
| 📊 Retensi Cerdas | Kebijakan retensi harian, mingguan, dan bulanan |
| 🔔 Notifikasi Waktu-nyata | Peringatan instan melalui ntfy.sh |
| ✅ Verifikasi Integritas | Verifikasi checksum SHA256 untuk setiap backup |
| 🔒 Keamanan | Izin yang dapat dikonfigurasi dan penguncian proses |
| 📝 Pencatatan Komprehensif | Log terperinci untuk audit dan pemecahan masalah |
| 🎯 Multi-Container Runtime | Mendukung Docker dan Podman secara otomatis |

## 🚀 Mulai Cepat

### Prasyarat

Pastikan sistem Anda memiliki:

```bash
- Bash 4.0+
- Docker atau Podman (jika melakukan backup volume)
- OpenSSL dengan dukungan ChaCha20
- gzip, tar, curl
- find, grep, sed, awk
- df, du, hostname, sha256sum
```

### Instalasi

1. Kloning repositori:
   ```bash
   git clone https://git.ricalnet.my.id/chantik.git
   cd chantik
   ```

2. Setup alias untuk kemudahan penggunaan:
   ```bash
   # Untuk Zsh (umum di macOS dan sebagian besar distro Linux modern)
   nano ~/.zshrc
   
   # Atau untuk Bash (default di banyak sistem)
   nano ~/.bashrc
   
   # Tambahkan baris berikut ke file yang sesuai:
   alias chantik='/path/to/chantik/chantik.sh'
   
   # Contoh: jika Anda mengkloning di /home/user/chantik
   alias chantik='/home/user/chantik/chantik.sh'
   
   # Simpan file dan muat ulang konfigurasi:
   source ~/.zshrc   # atau source ~/.bashrc
   
   # Sekarang Anda dapat menjalankan Chantik dari mana saja:
   chantik backup
   chantik list
   chantik restore postgres_data
   ```

3. Hasilkan kunci enkripsi:
   ```bash
   openssl rand -base64 32 > encryption.key
   chmod 600 encryption.key
   ```

4. (Opsional) Hasilkan salt tetap untuk deduplikasi:
   ```bash
   openssl rand -hex 8 > fixed_salt.txt
   chmod 600 fixed_salt.txt
   ```

5. Buat konfigurasi dari contoh:
   ```bash
   cp chantik.conf.example chantik.conf
   ```

6. Edit konfigurasi dengan pengaturan Anda:
   ```bash
   nano chantik.conf
   ```

7. Buat skrip dapat dieksekusi:
   ```bash
   chmod +x chantik.sh
   ```

8. Uji sistem enkripsi:
   ```bash
   chantik test
   ```

### Lakukan Backup Pertama

```bash
chantik backup

# Contoh keluaran:
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

## 📋 Panduan Konfigurasi

### Konfigurasi Penting

| Variabel | Deskripsi | Contoh |
|----------|-------------|---------|
| `BACKUP_BASE_DIR` | Tempat penyimpanan backup terenkripsi | `/media/backup` |
| `SOURCE_DIR` | Direktori utama yang akan di-backup | `/home/user/digital-independence` |
| `DOCKER_VOLUMES` | Nama volume Docker | `("postgres_data" "redis_cache")` |
| `PODMAN_VOLUMES` | Nama volume Podman | `("podman_data" "podman_config")` |
| `CONTAINER_RUNTIME` | Runtime container (auto/docker/podman) | `auto` |
| `ENCRYPTION_KEY_FILE` | Jalur ke kunci enkripsi | `/home/user/chantik/encryption.key` |
| `NTFY_TOPIC` | Topik ntfy.sh untuk notifikasi | `my-backup-topic` |
| `NTFY_TOKEN` | Token otentikasi ntfy.sh | `tk_xxxxxxxxxxxxxxxx` |

### Konfigurasi Lanjutan

| Variabel | Deskripsi | Default |
|----------|-------------|---------|
| `ENCRYPTION_CIPHER` | Sandi yang digunakan (terdeteksi otomatis) | `chacha20` |
| `PBKDF2_ITERATIONS` | Iterasi derivasi kunci (100.000+) | `600000` |
| `FIXED_SALT_FILE` | Salt tetap untuk enkripsi deterministik | (opsional) |
| `INCREMENTAL_ENABLED` | Aktifkan backup inkremental | `true` |
| `FULL_BACKUP_INTERVAL` | Hari antara backup penuh | `7` |
| `RETENTION_DAILY` | Jumlah backup harian yang disimpan | `7` |
| `RETENTION_WEEKLY` | Jumlah backup mingguan yang disimpan | `4` |
| `RETENTION_MONTHLY` | Jumlah backup bulanan yang disimpan | `6` |
| `GZIP_LEVEL` | Tingkat kompresi (1-9) | `6` |
| `DEDUP_TOOL` | Alat deduplikasi (hardlink/jdupes) | `hardlink` |
| `VERBOSE` | Aktifkan keluaran debug terperinci | `false` |
| `BACKUP_PREFIX` | Prefiks direktori backup | `chantik-backup` |
| `EXCLUDE_PATTERNS` | Pola file/direktori yang dikecualikan | `*.tmp,*.log` |
| `MAX_BACKUP_SIZE_MB` | Batas ukuran backup maksimum | `0` (tak terbatas) |
| `NTFY_CUSTOM_SERVER` | URL server ntfy kustom | (kosong) |
| `DOCKER_IMAGE` | Image untuk container helper | `alpine:latest` |

### Contoh Konfigurasi

<details>
<summary><b>Mengaktifkan Deduplikasi</b></summary>

Hasilkan salt tetap:
```bash
openssl rand -hex 8 > fixed_salt.txt
chmod 600 fixed_salt.txt
```

Di `chantik.conf`:
```bash
FIXED_SALT_FILE="/path/to/fixed_salt.txt"
DEDUP_TOOL="hardlink"
```
</details>

<details>
<summary><b>Menggunakan Podman</b></summary>

Di `chantik.conf`:
```bash
CONTAINER_RUNTIME="podman"
PODMAN_VOLUMES=(
    "postgres_data"
    "redis_cache"
)
```
</details>

<details>
<summary><b>Server ntfy Kustom</b></summary>

Di `chantik.conf`:
```bash
NTFY_CUSTOM_SERVER="https://ntfy.domain-anda.com"
```
</details>

## 🔄 Referensi Perintah

### Perintah Dasar

```bash
# Lakukan backup (penuh atau inkremental berdasarkan konfigurasi)
chantik backup

# Uji sistem enkripsi/dekripsi
chantik test

# Daftarkan semua backup yang tersedia
chantik list

# Verifikasi integritas backup tertentu
chantik verify /path/to/backup.enc

# Verifikasi semua backup
chantik verify-all

# Pulihkan dari backup
chantik restore <pola>

# Pulihkan dengan dry-run (tanpa perubahan)
chantik restore --dry-run <pola>

# Pulihkan beberapa backup sekaligus
chantik restore volume_postgres volume_redis

# Jalankan deduplikasi pada direktori backup
chantik dedup

# Tampilkan bantuan
chantik help
```

### Contoh Perintah Restore

```bash
# Pulihkan semua backup yang cocok dengan 'postgres'
chantik restore postgres

# Pulihkan backup dari tanggal tertentu
chantik restore 20260906

# Pulihkan beberapa volume sekaligus
chantik restore vol1 vol2 vol3

# Pulihkan dengan pemisah koma
chantik restore "postgres,redis"

# Dry-run restore (lihat apa yang akan dipulihkan)
chantik restore --dry-run postgres
```

### Konvensi Penamaan Backup

```
chantik-backup_YYYYMMDD_HHMMSS/
├── digital-independence_YYYYMMDD_HHMMSS_full.tar.gz.enc     # Backup penuh
├── digital-independence_YYYYMMDD_HHMMSS_inc.tar.gz.enc      # Backup inkremental
├── volume_postgres_data_YYYYMMDD_HHMMSS_full.tar.gz.enc     # Backup volume penuh
├── volume_redis_cache_YYYYMMDD_HHMMSS_inc.tar.gz.enc        # Backup volume inkremental
├── *.checksums                                              # Checksum SHA256
└── *.enc.checksums                                          # Checksum file terenkripsi
```

## 🔐 Keamanan

### Detail Enkripsi

- Sandi utama adalah ChaCha20‑Poly1305 (enkripsi terotentikasi)
- Sandi fallback adalah AES‑256‑CBC dengan derivasi kunci PBKDF2
- Derivasi kunci menggunakan PBKDF2 dengan iterasi yang dapat dikonfigurasi (default 600.000)
- Kekuatan kunci adalah enkripsi 256‑bit
- Integritas dijamin oleh checksum SHA256 untuk verifikasi
- Setiap backup diverifikasi terhadap kemungkinan perubahan
- Dukungan nonce tetap untuk deduplikasi deterministik

### Praktik Terbaik Keamanan

1. Jangan pernah melakukan komit konfigurasi ke kontrol versi
2. Lindungi kunci enkripsi: `chmod 600 encryption.key`
3. Simpan kunci enkripsi secara terpisah dari backup
4. Gunakan token ntfy.sh yang kuat
5. Rotasi kunci enkripsi secara teratur
6. Uji pemulihan secara berkala
7. Gunakan iterasi PBKDF2 yang tinggi (600.000+)

### Manajemen Kunci

Hasilkan kunci enkripsi baru:
```bash
openssl rand -base64 32 > encryption.key
chmod 600 encryption.key
```

Hasilkan salt tetap untuk deduplikasi:
```bash
openssl rand -hex 8 > fixed_salt.txt
chmod 600 fixed_salt.txt
```

Cadangkan kunci enkripsi secara terpisah (GPG):
```bash
gpg -c encryption.key
```

## 🔔 Notifikasi

Chantik terintegrasi dengan [ntfy.sh](https://ntfy.sh/) untuk notifikasi real-time.

### Menyiapkan Notifikasi

1. Dapatkan token ntfy: Kunjungi https://ntfy.sh/account
2. Pilih nama topik unik
3. Konfigurasikan di `chantik.conf`:
   ```bash
   NTFY_TOPIC="my-backup-topic"
   NTFY_TOKEN="tk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
   ```

### Jenis Notifikasi

| Jenis | Prioritas | Tag | Saat Dipicu |
|------|----------|------|----------------|
| Sukses | 3 (default) | ✅ | Backup berhasil diselesaikan |
| Kesalahan | 5 (mendesak) | 🔴 | Backup gagal atau terputus |
| Info | 3 | ℹ️ | Backup dimulai, konfigurasi dimuat |
| Pemulihan | 3 | 🔄 | Operasi pemulihan selesai |

## 🗄️ Retensi & Rotasi

Chantik menggunakan kebijakan retensi cerdas:

1. Backup harian: Simpan `RETENTION_DAILY` hari terakhir (default: 7)
2. Backup mingguan: Simpan `RETENTION_WEEKLY` minggu terakhir (default: 4)
3. Backup bulanan: Simpan `RETENTION_MONTHLY` bulan terakhir (default: 6)

### Logika Retensi

```bash
# Contoh garis waktu retensi
Retensi: Harian=7, Mingguan=4, Bulanan=6

# Backup yang dipertahankan:
Hari 1-7:      Semua backup harian
Minggu 1-4:    Satu backup per minggu
Bulan 1-6:     Satu backup per bulan
Lebih lama:    Dihapus
```

## 🐳 Integrasi Container

Chantik dapat melakukan backup dan pemulihan volume Docker dan Podman:

### Backup Volume Container

```bash
# Di chantik.conf - Gunakan Docker
DOCKER_VOLUMES=(
    "postgres_data"
    "redis_cache"
    "nginx_conf"
)
CONTAINER_RUNTIME="docker"

# Atau gunakan Podman
PODMAN_VOLUMES=(
    "postgres_data"
    "redis_cache"
)
CONTAINER_RUNTIME="podman"

# Atau biarkan auto-detect
CONTAINER_RUNTIME="auto"

# Setiap volume mendapatkan backup terenkripsi sendiri
volume_postgres_data_20260808_100000_full.tar.gz.enc
volume_redis_cache_20260808_100000_inc.tar.gz.enc
```

### Mendeteksi Runtime Secara Otomatis

Chantik akan mendeteksi runtime container yang tersedia:
1. Jika `CONTAINER_RUNTIME` diatur ke `docker` atau `podman`, gunakan itu
2. Jika `auto`, periksa Podman terlebih dahulu, lalu Docker
3. Jika tidak ada runtime ditemukan, akan muncul error

### Memulihkan Volume Container

```bash
# Pulihkan volume (otomatis mendeteksi runtime)
chantik restore postgres_data

# Pulihkan beberapa volume sekaligus
chantik restore postgres_data redis_cache

# Pulihkan dengan dry-run
chantik restore --dry-run postgres_data

# Keluaran:
[2026-08-08 10:30:00] 🦑 Memulihkan tipe: volume_postgres_data
[2026-08-08 10:30:00] 🔐 Mendekripsi...
[2026-08-08 10:30:05] ✅ Verifikasi checksum lulus.
[2026-08-08 10:30:10] 📦 Memulihkan volume: postgres_data
[2026-08-08 10:30:15] ✅ Pemulihan volume selesai untuk postgres_data
```

## 🤖 Otomatisasi

### Cron Job Examples

```bash
# Edit crontab
sudo crontab -e

# Backup harian pada jam 2:00 AM
0 2 * * * /usr/local/bin/chantik backup >> /var/log/chantik-cron.log 2>&1

# Backup penuh mingguan pada hari Minggu jam 3:00 AM
0 3 * * 0 /usr/local/bin/chantik backup >> /var/log/chantik-cron.log 2>&1

# Backup dengan pencatatan verbose
0 2 * * * VERBOSE=true /usr/local/bin/chantik backup >> /var/log/chantik-cron.log 2>&1

# Backup dengan konfigurasi kustom
0 2 * * * CHANTIK_CONFIG=/etc/chantik/prod.conf /usr/local/bin/chantik backup
```

### Contoh Jadwal

| Jadwal | Ekspresi Cron | Deskripsi |
|----------|----------------|-------------|
| Harian | `0 2 * * *` | Setiap hari jam 2:00 AM |
| Per Jam | `0 * * * *` | Setiap jam |
| Mingguan | `0 3 * * 0` | Setiap hari Minggu jam 3:00 AM |
| Bulanan | `0 4 1 * *` | Tanggal 1 setiap bulan jam 4:00 AM |

### Variabel Lingkungan

```bash
# Tentukan konfigurasi kustom
CHANTIK_CONFIG=/path/to/chantik.conf

# Tentukan direktori kerja
CHANTIK_WORK_DIR=/path/to/workdir

# Aktifkan verbose
VERBOSE=true

# Gunakan dalam cron
0 2 * * * CHANTIK_CONFIG=/etc/chantik/prod.conf VERBOSE=false /usr/local/bin/chantik backup
```

## 🛠️ Pemecahan Masalah

### Masalah Umum

ChaCha20 tidak didukung:
```bash
⚠️ PERINGATAN: ChaCha20-Poly1305 tidak didukung; beralih ke AES-256-CBC.
```
*Skrip akan secara otomatis menggunakan AES-256-CBC sebagai fallback.*

Ruang disk tidak mencukupi:
```bash
# Periksa ruang yang tersedia
df -h /media/backup

# Kurangi retensi atau tingkatkan penyimpanan
RETENTION_DAILY=3
RETENTION_WEEKLY=2
```

Kesalahan file kunci:
```bash
# Jika backup sebelumnya terputus
rm -f /path/to/chantik/.chantik.lock
# Atau hapus direktori lock
rm -rf /path/to/chantik/.chantik.lock.dir
```

Runtime container tidak terdeteksi:
```bash
# Periksa Docker
docker info

# Periksa Podman
podman info

# Atur runtime secara eksplisit di konfigurasi
CONTAINER_RUNTIME="docker"  # atau "podman"
```

### Mode Debug

Aktifkan mode verbose:
```bash
VERBOSE=true chantik backup
```

Periksa log:
```bash
tail -f chantik.log
# atau jika log di lokasi kustom
tail -f /path/to/chantik.log
```

Uji sistem enkripsi:
```bash
chantik test
```

## 📊 Optimasi Kinerja

### Pengaturan yang Direkomendasikan

| Skenario | GZIP_LEVEL | PBKDF2_ITERATIONS | INCREMENTAL_ENABLED |
|----------|------------|-------------------|-------------------|
| Backup harian | 6 | 600000 | true |
| File besar | 3 | 600000 | false |
| Kompresi maksimum | 9 | 600000 | true |
| Prioritas kecepatan | 1 | 100000 | false |
| Prioritas keamanan | 6 | 1000000 | true |

### Optimasi Penyimpanan

Gunakan deduplikasi dengan salt tetap:
```bash
FIXED_SALT_FILE="/path/to/fixed_salt.txt"
DEDUP_TOOL="hardlink"
```

Gunakan backup inkremental:
```bash
INCREMENTAL_ENABLED=true
FULL_BACKUP_INTERVAL=14
```

Kompresi lebih agresif:
```bash
GZIP_LEVEL=9
```

### Mendukung Banyak Runtime

Chantik mendeteksi dan menggunakan runtime yang tersedia:
- **Podman**: Dideteksi pertama (jika tersedia)
- **Docker**: Digunakan sebagai fallback
- **Manual**: Atur `CONTAINER_RUNTIME` secara eksplisit

## 🧪 Pengujian

Jalankan rangkaian uji lengkap:
```bash
chantik test
```

Rangkaian uji memverifikasi:
- Enkripsi/dekripsi ChaCha20 (teks dan biner)
- Fallback AES-256-CBC
- Kompatibilitas PBKDF2
- Deduplikasi nonce tetap (jika dikonfigurasi)
- Deteksi runtime container

## 🏗️ Struktur Direktori

```
chantik/
├── chantik.sh              # Skrip utama
├── chantik.conf            # Konfigurasi (buat dari example)
├── chantik.conf.example    # Contoh konfigurasi
├── encryption.key          # Kunci enkripsi (hasilkan sendiri)
├── fixed_salt.txt          # Salt tetap (opsional)
├── chantik.log             # File log
├── .chantik.lock           # File lock (otomatis)
├── .chantik.lock.dir/      # Direktori lock (otomatis)
├── .tmp/                   # Direktori temporary
└── .incremental/           # Data snapshot inkremental
    ├── dir_digital-independence.snar
    ├── vol_postgres_data.snar
    └── vol_redis_cache.snar
```

## 🙏 Ucapan Terima Kasih

- ChaCha20-Poly1305 - Enkripsi terotentikasi
- OpenSSL - Operasi kriptografi
- ntfy.sh - Layanan notifikasi
- Docker & Podman - Backup volume container
- Alpine Linux - Image container ringan

## 📄 Lisensi

Lisensi MIT - Lihat file [LICENSE](LICENSE) untuk detailnya.
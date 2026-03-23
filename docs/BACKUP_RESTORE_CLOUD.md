# Backup/Restore Cloud

## Mode

- `Google Drive`: cocok untuk backup pribadi / akun personal.
- `Cloudflare R2`: cocok untuk backup server / object storage native.

## Google Drive

### Opsi A. Termux langsung

1. Jalankan:

```bash
apt update && apt upgrade
apt install rclone -y
```

2. Jalankan:

```bash
rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"
```

3. Login Google lalu copy JSON token hasil auth
4. Tempel token itu ke flow `Paste OAuth Token JSON`

### Opsi B. VPS + SSH tunnel

1. Di VPS jalankan:

```bash
rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"
```

2. Copy URL lokal yang muncul
3. Di Termux jalankan:

```bash
ssh -L 53682:127.0.0.1:53682 root@IP_VPS
```

4. Buka URL tadi di browser HP
5. Login Google lalu copy JSON token hasil auth
6. Tempel token itu ke flow `Paste OAuth Token JSON`

### Verifikasi

```bash
rclone about gdrive:
rclone mkdir gdrive:autoscript-backups
```

### Config autoscript

```bash
BACKUP_GDRIVE_REMOTE="gdrive:autoscript-backups"
```

Catatan:
- Jika port `53682` sudah terpakai, jalankan `pkill -f rclone`
- Jika tunnel menampilkan zombie process, itu normal selama SSH tetap aktif
- Setelah remote jadi, cek lagi dari bot/CLI lewat `Status Config`
- Setelah token tersimpan, operasi backup/restore bisa jalan penuh dari VPS

## Cloudflare R2

1. Login ke dashboard Cloudflare lalu buka R2 Object Storage
2. Siapkan:
   - `Account ID`
   - `Bucket Name`
   - `Access Key ID`
   - `Secret Access Key`
3. Di autoscript/bot, isi data itu ke flow setup R2
4. Jika ingin setup manual via terminal:
   - jalankan `rclone config`
   - buat remote baru, misalnya `r2`
   - pilih backend `s3`
   - pilih provider `Cloudflare`
   - isi `Access Key ID` dan `Secret Access Key`
5. Endpoint:

```text
https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

6. Verifikasi:

```bash
rclone lsf r2:<bucket-name>
```

7. Set config autoscript:

```bash
BACKUP_R2_REMOTE="r2:<bucket-name>"
```

Catatan:
- Lebih cocok untuk backup server/object storage
- Setelah setup, cek lagi dari bot/CLI lewat `Status Config`
- Akses root bucket bisa dibatasi token; operasi pada bucket target tetap normal

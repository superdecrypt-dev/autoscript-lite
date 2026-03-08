# BadVPN Prebuilt

Direktori ini disediakan untuk binary prebuilt `badvpn-udpgw`.

File yang diharapkan:
- `badvpn-udpgw-linux-amd64`
- `badvpn-udpgw-linux-arm64`
- `SHA256SUMS`

Status saat ini:
- placeholder only
- belum ada binary yang dibundel

Saat implementasi aktif, installer akan:
1. deteksi arsitektur host
2. pilih binary yang cocok
3. verifikasi checksum
4. install ke `/usr/local/bin/badvpn-udpgw`

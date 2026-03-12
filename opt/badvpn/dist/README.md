# BadVPN Prebuilt

Direktori ini disediakan untuk binary prebuilt `badvpn-udpgw`.

File yang diharapkan:
- `badvpn-udpgw-linux-amd64`
- `badvpn-udpgw-linux-arm64`

Status saat ini:
- binary prebuilt sudah dibundel
- installer memilih binary sesuai arsitektur host
- runtime live sudah dipakai oleh setup normal

Saat setup normal, installer akan:
1. deteksi arsitektur host
2. pilih binary yang cocok
3. install ke `/usr/local/bin/badvpn-udpgw`

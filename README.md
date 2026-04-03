# Autoscript

> Installer, runtime, dan panel operasional harian untuk stack `Xray-core`, `SSH WS`, `OpenVPN`, `Edge Gateway`, `WARP`, dan bot `Telegram` di VPS Linux.

Autoscript dirancang untuk operator yang ingin satu repo untuk:
- bootstrap server dari nol
- mengelola user `Xray` dan `SSH` dari CLI modular
- menautkan `OpenVPN` langsung ke lifecycle akun `SSH`
- menjalankan ingress publik berbasis `Go edge-mux`
- mengoperasikan `WARP`, `BadVPN`, `Domain Guard`, dan bot `Telegram`

## Sebelum Install
Sebelum menjalankan installer, aktifkan dulu lisensi IP VPS di website:

- Website lisensi: `https://autoscript.license.dpdns.org`
- Langkah singkat:
  1. buka website lisensi
  2. input public IPv4 VPS
  3. selesaikan verifikasi bila diminta
  4. pastikan IP sudah aktif
  5. baru jalankan `run.sh`

Kalau lisensi belum aktif, installer akan berhenti di preflight license guard.

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/run.sh)
```

## Arsitektur Singkat
```text
Internet / Cloudflare
        |
        v
  edge-mux (Go)
  :80, :8080, :8880, :2052, :2082, :2086, :2095
  :443, :2053, :2083, :2087, :2096, :8443
        |
        +--> nginx            127.0.0.1:18080
        +--> SSH Dropbear     127.0.0.1:22022
        +--> SSH Stunnel      127.0.0.1:22443
        +--> Websocket Proxy (Go)  127.0.0.1:10015
        +--> Xray-core        via inbound runtime
```

## Layanan Utama

| Komponen | Peran | Status Runtime |
| --- | --- | --- |
| `edge-mux` | ingress publik untuk `Xray` dan `SSH` | frontend utama |
| `xray` | core proxy untuk `VLESS`, `VMess`, `Trojan` | backend utama |
| `nginx` | HTTP backend internal dan TLS/web support | internal |
| `sshws-dropbear` | backend SSH direct/dropbear | internal |
| `sshws-stunnel` | backend SSH SSL/TLS | internal |
| `sshws-proxy` | Websocket Proxy (Go) untuk backend SSH WS | internal |
| `openvpn-server@autoscript-tcp` | OpenVPN TCP classic yang terikat ke akun SSH | publik |
| `badvpn-udpgw` | UDPGW lokal untuk payload/game tertentu | internal |
| `wireproxy` / `warp-svc` | runtime `WARP Free/Plus` atau `Zero Trust` | sesuai mode aktif |
| `xray-domain-guard` | guardrail domain, TLS, dan health check | maintenance |
| `bot-telegram-backend` | API internal bot Telegram | opsional |
| `bot-telegram-gateway` | gateway Telegram menu-first | opsional |

## Layanan dan Protokol
- `VLESS`, `VMess`, `Trojan`
- transport `XHTTP`, `WS`, `HTTPUpgrade`, `gRPC`, `TCP+TLS`
- `SSH WS`, `SSH SSL/TLS`, `SSH Direct`
- `OpenVPN TCP`
- `WARP Free/Plus`, `WARP Zero Trust`, `BadVPN UDPGW`

## Port Publik

### Front Door Edge Gateway

| Kategori | Port | Keterangan |
| --- | --- | --- |
| `HTTP primary` | `80` | ingress utama |
| `HTTP alternate` | `8080, 8880, 2052, 2082, 2086, 2095` | port alternatif kompatibel Cloudflare |
| `HTTPS primary` | `443` | ingress utama TLS |
| `HTTPS alternate` | `2053, 2083, 2087, 2096, 8443` | port alternatif kompatibel Cloudflare |

### Service Exposure

| Layanan | Jalur / Port User-Facing |
| --- | --- |
| `SSH WS` | `443, 80` + alt port Cloudflare |
| `SSH SSL/TLS` | `443, 80` + alt port Cloudflare |
| `SSH Direct` | `443, 80` + alt port Cloudflare |
| `VLESS XHTTP` | `443, 80` + alt port Cloudflare |
| `VLESS WS` | `443, 80` + alt port Cloudflare |
| `VLESS HUP` | `443, 80` + alt port Cloudflare |
| `VLESS gRPC` | `443, 80` + alt port Cloudflare |
| `VLESS TCP+TLS` | `443, 80` + alt port Cloudflare |
| `VMess XHTTP` | `443, 80` + alt port Cloudflare |
| `VMess WS` | `443, 80` + alt port Cloudflare |
| `VMess HUP` | `443, 80` + alt port Cloudflare |
| `VMess gRPC` | `443, 80` + alt port Cloudflare |
| `Trojan XHTTP` | `443, 80` + alt port Cloudflare |
| `Trojan WS` | `443, 80` + alt port Cloudflare |
| `Trojan HUP` | `443, 80` + alt port Cloudflare |
| `Trojan gRPC` | `443, 80` + alt port Cloudflare |
| `Trojan TCP+TLS` | `443, 80` + alt port Cloudflare |
| `OpenVPN TCP` | `443, 80` + alt port Cloudflare |
| `OpenVPN WS` | `443, 80` + alt port Cloudflare |

## Path Runtime

Gunakan hanya path publik di bawah ini untuk client.
Jangan gunakan path internal acak backend `Xray` atau proxy lokal karena nilainya bisa berubah setiap install atau re-render config.

### Path Publik Stabil

| Transport | Path utama | Varian alt yang didukung | Catatan |
| --- | --- | --- | --- |
| `SSH WS` | `/<token-hex-10>` atau `/diagnostic-probe` | `/<bebas>/<token-hex-10>/<bebas>` dan `/<bebas>/diagnostic-probe/<bebas>` | token SSH WS adalah 10 karakter heksadesimal |
| `OpenVPN WS` | `/<token-openvpn>` | `/<bebas>/<token-openvpn>/<bebas>` | token live mengikuti `OPENVPN_WS_PUBLIC_PATH` |
| `VLESS WS` | `/vless-ws` | `/<bebas>/vless-ws` atau `/<bebas>/vless-ws/<bebas>` | path publik stabil |
| `VLESS HUP` | `/vless-hup` | `/<bebas>/vless-hup` atau `/<bebas>/vless-hup/<bebas>` | path publik stabil |
| `VLESS XHTTP` | `/vless-xhttp` | `/<bebas>/vless-xhttp` atau `/<bebas>/vless-xhttp/<bebas>` | path publik stabil |
| `VLESS gRPC` | `/vless-grpc` | `/<bebas>/vless-grpc` atau `/<bebas>/vless-grpc/<bebas>` | request publik tetap path, service name internal dirahasiakan |
| `VMess WS` | `/vmess-ws` | `/<bebas>/vmess-ws` atau `/<bebas>/vmess-ws/<bebas>` | path publik stabil |
| `VMess HUP` | `/vmess-hup` | `/<bebas>/vmess-hup` atau `/<bebas>/vmess-hup/<bebas>` | path publik stabil |
| `VMess XHTTP` | `/vmess-xhttp` | `/<bebas>/vmess-xhttp` atau `/<bebas>/vmess-xhttp/<bebas>` | path publik stabil |
| `VMess gRPC` | `/vmess-grpc` | `/<bebas>/vmess-grpc` atau `/<bebas>/vmess-grpc/<bebas>` | request publik tetap path, service name internal dirahasiakan |
| `Trojan WS` | `/trojan-ws` | `/<bebas>/trojan-ws` atau `/<bebas>/trojan-ws/<bebas>` | path publik stabil |
| `Trojan HUP` | `/trojan-hup` | `/<bebas>/trojan-hup` atau `/<bebas>/trojan-hup/<bebas>` | path publik stabil |
| `Trojan XHTTP` | `/trojan-xhttp` | `/<bebas>/trojan-xhttp` atau `/<bebas>/trojan-xhttp/<bebas>` | path publik stabil |
| `Trojan gRPC` | `/trojan-grpc` | `/<bebas>/trojan-grpc` atau `/<bebas>/trojan-grpc/<bebas>` | request publik tetap path, service name internal dirahasiakan |

### Path Internal

Contoh path internal yang tidak perlu dipakai operator:
- `Xray WS/HUP` memakai path acak seperti `/h5faaachbphar0`
- `Xray gRPC` memakai service name acak seperti `24j1m934rp8m`
- `SSH WS` backend proxy tetap listen internal di `127.0.0.1:10015`
- `OpenVPN WS` backend proxy tetap listen internal di `127.0.0.1:10016`

Path internal itu hanya dipakai untuk wiring `nginx -> proxy/Xray` di host.

## Portal Info Akun
- Setiap akun `Xray`, `SSH`, dan `OpenVPN` sekarang bisa punya link portal read-only sendiri.
- Portal ini berdiri sebagai service mandiri di host, tidak menumpang backend bot Telegram.
- Format URL:
  - `https://<domain-vps>/account/<token>`
- Portal menampilkan:
  - status akun
  - sisa masa aktif
  - quota limit / quota terpakai / quota tersisa
  - IP login aktif yang masih terdeteksi runtime
- API JSON pendukung:
  - `GET /api/account/<token>/summary`
- Link portal ikut ditulis ke:
  - `XRAY ACCOUNT INFO`
  - `SSH ACCOUNT INFO`
  - blok `OpenVPN` pada `SSH ACCOUNT INFO`

## Port Internal

| Komponen | Bind | Keterangan |
| --- | --- | --- |
| `nginx` | `127.0.0.1:18080` | backend web internal |
| `sshws-dropbear` | `127.0.0.1:22022` | backend SSH direct |
| `sshws-stunnel` | `127.0.0.1:22443` | backend SSH TLS |
| `sshws-proxy` | `127.0.0.1:10015` | Websocket Proxy (Go) untuk SSH WS |
| `ovpn-ws-proxy` | `127.0.0.1:10016` | Websocket Proxy (Go) untuk OpenVPN WS |
| `account-portal` | `127.0.0.1:7082` | website read-only info akun |
| `bot-telegram-backend` | `127.0.0.1:7081` | API internal bot Telegram |
| `edge-mux metrics` | `127.0.0.1:9910` | metrics dan status edge |
| `WARP local proxy` | `127.0.0.1:40000` | runtime `Zero Trust` / proxy lokal |
| `BadVPN UDPGW` | `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900` | UDPGW lokal |

## Service Highlights
- `manage.sh` adalah panel CLI modular untuk operasi harian.
- `run.sh` dan `setup.sh` menangani bootstrap host, install runtime, dan sinkronisasi service.
- `account-portal/` menyediakan website mandiri untuk status akun per token.
- `bot-telegram/` menyediakan backend + gateway menu-first untuk operasi dari Telegram.
- `opt/edge/go/` memuat source `edge-mux` dan `wsproxy`, sedangkan artefak distribusi ada di `opt/edge/dist/` dan `opt/wsproxy/dist/`.
- `manage_bundle.zip` dan `bot_telegram.zip` dipakai sebagai release artifact untuk installer.

## Menu Utama
```text
1) Xray Users
2) SSH Users
3) Xray QAC
4) SSH & OpenVPN QAC
5) Xray Network
6) SSH Network
7) Adblocker
8) Domain Control
9) Speedtest
10) Security
11) Maintenance
12) Traffic
13) Tools
0) Keluar
```

### Tools
```text
13) Tools
1) Telegram Bot
2) WARP Tier
3) Backup/Restore
4) License Guard
0) Back
```

## Backup/Restore
- `Backup/Restore` sekarang tersedia di:
  - CLI `manage` lewat `13) Tools -> 3) Backup/Restore`
  - bot Telegram lewat `Main Menu -> Backup/Restore`
- Provider cloud yang didukung:
  - `Google Drive`
  - `Cloudflare R2`
  - `Telegram` dipakai untuk backup lokal + restore upload dari chat
- Nama file backup manual memakai format:
  - `backup-YYYY-MM-DD-HH:MM.tar.gz`
- `safety backup` internal tetap dibuat otomatis sebelum restore penuh dan disimpan terpisah.

### Menu Cloud
Baik di CLI maupun bot Telegram, menu cloud sekarang mengikuti susunan ini:

```text
- Setup
- Status Config
- Test Remote
- Create & Upload Backup
- List Cloud Backups
- Restore Latest Cloud Backup
- Restore Select Backup
- Delete Cloud Backup
```

### Setup Google Drive
- `Google Drive` mendukung flow OAuth headless.
- Setup bisa dilakukan dari:
  - `Termux` langsung memakai `rclone authorize`
  - `VPS + SSH tunnel`
- Bot Telegram menyediakan:
  - `Tutorial Setup`
  - `Paste JSON Auth Google`
  - `Use Existing Remote`
- CLI menyediakan flow yang sama di menu `Google Drive -> Setup`.

### Setup Cloudflare R2
- `Cloudflare R2` mendukung setup dari:
  - bot Telegram lewat `Quick Setup R2`
  - CLI lewat wizard `Quick Setup R2`
  - `Manual rclone config`
- Data minimum yang dibutuhkan:
  - `Account ID`
  - `Bucket Name`
  - `Access Key ID`
  - `Secret Access Key`

### Perilaku Restore
- `Restore Latest Cloud Backup` dan `Restore Select Backup` adalah restore penuh.
- Restore penuh bekerja sebagai `snapshot replace` untuk scope restore yang diizinkan.
- Artinya file akun/quota/speed/config dalam scope restore akan mengikuti isi backup, bukan merge.
- Domain aktif, config Xray, quota, speed, cert, dan state runtime yang masuk whitelist restore akan ikut dipulihkan.
- Sebelum restore penuh, sistem membuat `safety backup` dulu dan mencoba rollback otomatis jika validasi pasca-restore gagal.

### Perilaku Select/Delete
- `Restore Select Backup` dan `Delete Cloud Backup` sekarang memakai `NO` dari `List Cloud Backups`, bukan nama file manual.
- Di CLI, daftar backup cloud ditampilkan dulu sebelum input `NO`.
- Di bot Telegram, submenu select/delete menyediakan:
  - `List Cloud Backups`
  - `Input Backup NO`

### Catatan Operasional
- Restore bersifat live dan akan menimpa runtime aktif.
- Gunakan restore hanya untuk rollback atau recovery, bukan untuk trial acak.
- `Google Drive` lebih cocok untuk backup pribadi/operator.
- `Cloudflare R2` lebih cocok untuk backup server/object storage native.
- Panduan lebih detail ada di `docs/BACKUP_RESTORE_CLOUD.md`.

## Bot
### Telegram
- Entry point: `/menu`, `/cleanup`, `/start`
- UX sekarang menu-first dengan kategori `Status`, `Accounts`, `QAC`, `Domain`, `Network`, `Ops`
- Action mutasi dikendalikan lewat ACL admin Telegram, bukan lagi flag dangerous terpisah
- Detail: `bot-telegram/README.md`

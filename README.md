# Autoscript

> Installer, runtime, dan panel operasional harian untuk stack `Xray-core`, `SSH WS`, `OpenVPN`, `Edge Gateway`, `WARP`, dan bot `Telegram` di VPS Linux.

Autoscript dirancang untuk operator yang ingin satu repo untuk:
- bootstrap server dari nol
- mengelola user `Xray` dan `SSH` dari CLI modular
- menautkan `OpenVPN` langsung ke lifecycle akun `SSH`
- menjalankan ingress publik berbasis `Go edge-mux`
- mengoperasikan `WARP`, `BadVPN`, `Domain Guard`, dan bot `Telegram`

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/run.sh)
```

Catatan penting:
- Metadata aktif SSH berada di `/opt/quota/ssh/<username>@ssh.json`.
- Host lama yang masih memakai flow lain di luar menu resmi sebaiknya recreate akun dari panel saat upgrade besar.
- License guard IP VPS sekarang built-in dan default mengarah ke `https://autoscript.temp10sgt.workers.dev/api/v1/license/check`, jadi user VPS tidak perlu set env manual.
- Runtime license guard menyimpan cache allow terakhir hingga `24 jam` dan statusnya bisa dilihat dari `manage -> 13) Tools -> License Guard`.

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

## Path Publik

| Transport | Path / Service |
| --- | --- |
| `SSH WS` | `/<token>` dan `/<bebas>/<token>` |
| `OpenVPN WS` | `/<token>` dan `/<bebas>/<token>` |
| `VLESS WS` | `/vless-ws` dan `/<bebas>/vless-ws` |
| `VLESS HUP` | `/vless-hup` dan `/<bebas>/vless-hup` |
| `VLESS XHTTP` | `/vless-xhttp` dan `/<bebas>/vless-xhttp` |
| `VLESS gRPC` | `vless-grpc` dan `<bebas>/vless-grpc` |
| `VMess WS` | `/vmess-ws` dan `/<bebas>/vmess-ws` |
| `VMess HUP` | `/vmess-hup` dan `/<bebas>/vmess-hup` |
| `VMess XHTTP` | `/vmess-xhttp` dan `/<bebas>/vmess-xhttp` |
| `VMess gRPC` | `vmess-grpc` dan `<bebas>/vmess-grpc` |
| `Trojan WS` | `/trojan-ws` dan `/<bebas>/trojan-ws` |
| `Trojan HUP` | `/trojan-hup` dan `/<bebas>/trojan-hup` |
| `Trojan XHTTP` | `/trojan-xhttp` dan `/<bebas>/trojan-xhttp` |
| `Trojan gRPC` | `trojan-grpc` dan `<bebas>/trojan-grpc` |

## Port Internal

| Komponen | Bind | Keterangan |
| --- | --- | --- |
| `nginx` | `127.0.0.1:18080` | backend web internal |
| `sshws-dropbear` | `127.0.0.1:22022` | backend SSH direct |
| `sshws-stunnel` | `127.0.0.1:22443` | backend SSH TLS |
| `sshws-proxy` | `127.0.0.1:10015` | Websocket Proxy (Go) untuk SSH WS |
| `ovpn-ws-proxy` | `127.0.0.1:10016` | Websocket Proxy (Go) untuk OpenVPN WS |
| `bot-telegram-backend` | `127.0.0.1:7081` | API internal bot Telegram |
| `edge-mux metrics` | `127.0.0.1:9910` | metrics dan status edge |
| `WARP local proxy` | `127.0.0.1:40000` | runtime `Zero Trust` / proxy lokal |
| `BadVPN UDPGW` | `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900` | UDPGW lokal |

## Service Highlights
- `manage.sh` adalah panel CLI modular untuk operasi harian.
- `run.sh` dan `setup.sh` menangani bootstrap host, install runtime, dan sinkronisasi service.
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

## Cloudflare License Portal
- Portal web lisensi IP VPS sekarang tersedia di [`cloudflare/autoscript-license-portal/`](/root/project/autoscript/cloudflare/autoscript-license-portal)
- Target deploy:
  - `Cloudflare Worker` untuk API lisensi publik dan endpoint check autoscript
  - `Cloudflare D1` untuk database allowlist, audit, dan rate limit
  - `Cloudflare Pages` untuk website publik `/`
- Workflow deploy yang didukung:
  - `Connect GitHub` untuk `Pages` dan `Worker`
  - Pages build sekarang menghasilkan `dist/config.js` dari env build Cloudflare, jadi tidak perlu commit `apiBaseUrl` produksi ke source
- Flow publik default:
  - siapa pun bisa mengaktifkan izin IP VPS dari website publik
  - masa aktif awal default `14 hari`
  - input IP yang sama lagi akan memperpanjang masa aktif
  - user VPS cukup input IP di web lalu langsung jalankan autoscript
- Flow admin:
  - panel admin tidak dipakai di mode sederhana ini
- Endpoint autoscript yang dipakai VPS:
  - `POST /api/v1/license/check`
- Endpoint built-in autoscript:
  - `AUTOSCRIPT_LICENSE_DEFAULT_API_URL=https://autoscript.temp10sgt.workers.dev/api/v1/license/check`
- Secret penting untuk deploy portal:
  - tidak ada secret wajib untuk mode publik super sederhana ini

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

# Autoscript Lite

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Linux-0f172a?style=for-the-badge&logo=linux&logoColor=white" alt="Linux">
  <img src="https://img.shields.io/badge/Core-Xray-111827?style=for-the-badge&logo=radar&logoColor=white" alt="Xray">
  <img src="https://img.shields.io/badge/Edge-Go%20edge--mux-0b5fff?style=for-the-badge&logo=go&logoColor=white" alt="Go edge-mux">
  <img src="https://img.shields.io/badge/Remote-Telegram-229ED9?style=for-the-badge&logo=telegram&logoColor=white" alt="Telegram">
  <img src="https://img.shields.io/badge/WARP-Cloudflare-F38020?style=for-the-badge&logo=cloudflare&logoColor=white" alt="Cloudflare WARP">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Manage-CLI-1f2937?style=flat-square&logo=gnubash&logoColor=white" alt="Manage CLI">
  <img src="https://img.shields.io/badge/Portal-Account-2563eb?style=flat-square&logo=vercel&logoColor=white" alt="Account Portal">
  <img src="https://img.shields.io/badge/Zero%20Trust-Cloudflare%20WARP-F38020?style=flat-square&logo=cloudflare&logoColor=white" alt="Cloudflare WARP">
</p>

## Fokus

- `autoscript-lite` = repo ringan untuk stack `Xray`
- `run.sh` = bootstrap host
- `manage` = panel operasi harian
- `Xray`, `edge-mux`, `WARP`, `Account Portal`
- `Domain Control`, `Speedtest`, `Traffic`, `Security`, `Backup/Restore`

## Status Biaya

Source code `autoscript-lite` tersedia gratis untuk digunakan.

Aktivasi lisensi IP VPS tetap menjadi bagian dari flow produk, tetapi repo ini sendiri bukan software berbayar.

## Sebelum Install

Sebelum menjalankan installer, aktifkan lisensi IP VPS terlebih dahulu:

- Website lisensi: `https://autoscript.license.dpdns.org`
- Langkah singkat:
  1. buka website lisensi
  2. input public IPv4 VPS
  3. selesaikan verifikasi bila diminta
  4. pastikan IP sudah aktif
  5. baru jalankan `run.sh`

Kalau lisensi belum aktif, installer akan berhenti pada preflight `License Guard`.

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript-lite/main/run.sh)
```

## Arsitektur

```text
Internet / Cloudflare
        |
        v
  edge-mux (Go)
  :80, :8080, :8880, :2052, :2082, :2086, :2095
  :443, :2053, :2083, :2087, :2096, :8443
        |
        +--> nginx         127.0.0.1:18080
        +--> Xray-core     via inbound runtime
```

## Layanan Utama

| Komponen | Peran | Status Runtime |
| --- | --- | --- |
| `edge-mux` | ingress publik untuk `Xray` | frontend utama |
| `xray` | core proxy untuk `VLESS`, `VMess`, `Trojan` | backend utama |
| `nginx` | HTTP backend internal dan TLS/web support | internal |
| `wireproxy` / `warp-svc` | runtime `WARP Free/Plus` atau `Zero Trust` | sesuai mode aktif |
| `xray-domain-guard` | guardrail domain, TLS, dan health check | maintenance |
| `account-portal` | portal akun read-only | opsional |
| `bot-telegram-backend` | API internal bot Telegram | opsional |
| `bot-telegram-gateway` | gateway Telegram menu-first | opsional |

## Kapabilitas

### Protokol dan transport

- `VLESS`, `VMess`, `Trojan`
- transport `XHTTP`, `WS`, `HTTPUpgrade`, `gRPC`, `TCP+TLS`
- `WARP Free/Plus`, `WARP Zero Trust`

### Transport highlight

- `VMess TCP+TLS`
- `VLESS XHTTP3`

### Surface operasional

- `manage` CLI modular
- `Account Portal`
- `Bot Telegram`
- `Backup/Restore`
- `License Guard`
- `Domain Control`
- `Traffic`, `QAC`, `Speed`, dan `Adblocker`

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
| `VLESS XHTTP` | `443, 80` + alt port Cloudflare |
| `VLESS WS` | `443, 80` + alt port Cloudflare |
| `VLESS HUP` | `443, 80` + alt port Cloudflare |
| `VLESS gRPC` | `443, 80` + alt port Cloudflare |
| `VLESS TCP+TLS` | `443, 80` + alt port Cloudflare |
| `VMess XHTTP` | `443, 80` + alt port Cloudflare |
| `VMess WS` | `443, 80` + alt port Cloudflare |
| `VMess HUP` | `443, 80` + alt port Cloudflare |
| `VMess gRPC` | `443, 80` + alt port Cloudflare |
| `VMess TCP+TLS` | `443, 80` + alt port Cloudflare |
| `Trojan XHTTP` | `443, 80` + alt port Cloudflare |
| `Trojan WS` | `443, 80` + alt port Cloudflare |
| `Trojan HUP` | `443, 80` + alt port Cloudflare |
| `Trojan gRPC` | `443, 80` + alt port Cloudflare |
| `Trojan TCP+TLS` | `443, 80` + alt port Cloudflare |

## Path Publik

Gunakan hanya path publik di bawah ini untuk client. Hindari memakai path internal backend karena nilainya bisa berubah saat install ulang atau re-render config.

| Transport | Path utama | Varian alt | Catatan |
| --- | --- | --- | --- |
| `VLESS WS` | `/vless-ws` | `/<bebas>/vless-ws` atau `/<bebas>/vless-ws/<bebas>` | path publik stabil |
| `VLESS HUP` | `/vless-hup` | `/<bebas>/vless-hup` atau `/<bebas>/vless-hup/<bebas>` | path publik stabil |
| `VLESS XHTTP` | `/vless-xhttp` | `/<bebas>/vless-xhttp` atau `/<bebas>/vless-xhttp/<bebas>` | path publik stabil |
| `VLESS gRPC` | `/vless-grpc` | `/<bebas>/vless-grpc` atau `/<bebas>/vless-grpc/<bebas>` | service name internal dirahasiakan |
| `VMess WS` | `/vmess-ws` | `/<bebas>/vmess-ws` atau `/<bebas>/vmess-ws/<bebas>` | path publik stabil |
| `VMess HUP` | `/vmess-hup` | `/<bebas>/vmess-hup` atau `/<bebas>/vmess-hup/<bebas>` | path publik stabil |
| `VMess XHTTP` | `/vmess-xhttp` | `/<bebas>/vmess-xhttp` atau `/<bebas>/vmess-xhttp/<bebas>` | path publik stabil |
| `VMess gRPC` | `/vmess-grpc` | `/<bebas>/vmess-grpc` atau `/<bebas>/vmess-grpc/<bebas>` | service name internal dirahasiakan |
| `Trojan WS` | `/trojan-ws` | `/<bebas>/trojan-ws` atau `/<bebas>/trojan-ws/<bebas>` | path publik stabil |
| `Trojan HUP` | `/trojan-hup` | `/<bebas>/trojan-hup` atau `/<bebas>/trojan-hup/<bebas>` | path publik stabil |
| `Trojan XHTTP` | `/trojan-xhttp` | `/<bebas>/trojan-xhttp` atau `/<bebas>/trojan-xhttp/<bebas>` | path publik stabil |
| `Trojan gRPC` | `/trojan-grpc` | `/<bebas>/trojan-grpc` atau `/<bebas>/trojan-grpc/<bebas>` | service name internal dirahasiakan |

Catatan:

- `TCP+TLS` tidak menggunakan path publik
- `VLESS XHTTP3` menggunakan profile `xray.json` yang dirender per akun

## Port Internal

| Komponen | Bind | Keterangan |
| --- | --- | --- |
| `nginx` | `127.0.0.1:18080` | backend web internal |
| `account-portal` | `127.0.0.1:7082` | website info akun |
| `bot-telegram-backend` | `127.0.0.1:7081` | API internal bot |
| `edge-mux metrics` | `127.0.0.1:9910` | metrics edge |
| `WARP local proxy` | `127.0.0.1:40000` | runtime Zero Trust |
| `BadVPN UDPGW` | `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900` | UDPGW lokal |

## Account Portal

Setiap akun `Xray` dapat memiliki link portal read-only sendiri.

- format URL:
  - `https://<domain-vps>/account/<token>`
- portal menampilkan:
  - status akun
  - masa aktif
  - quota limit, used, dan remaining
  - sesi aktif yang masih terdeteksi runtime
- endpoint JSON:
  - `GET /api/account/<token>/summary`

## Cloudflare Zero Trust Setup

Bagian ini dipakai saat Anda ingin menyiapkan `WARP Zero Trust` dengan service token.

### 1) Device enrollment permissions

Masuk ke:

`Team & Resources -> Devices -> Management -> Device enrollment permissions -> Manage -> Policies`

Lalu:

1. add rule `Policies`
2. nama bebas
3. `Rule action`: `service auth`
4. `Include selector`: `Any Access Service Token`
5. save

### 2) Device Profile

Masuk ke:

`Team & Resources -> Devices -> Device Profile`

Lalu:

1. `Create new profile`
2. nama bebas
3. selector -> `user email`
4. operator -> `is`
5. value: `non_identity@<team-name>.cloudflareaccess.com`
6. `+ AND condition`
7. selector -> `operating system`
8. operator -> `is`
9. value: `Linux`
10. `Device tunnel protocol`: `MASQUE`
11. `Service mode`: `local proxy mode port 40000`
12. save

### 3) Service Token

Masuk ke:

`Access controls -> Service Credentials -> Service Token`

Lalu:

1. create service token
2. nama bebas
3. token durasi bebas
4. generate token
5. copy `Client ID` token dan `Client Secret` token

Catatan:

- Untuk enrollment headless Linux, `Device enrollment permissions` dengan `Service Auth` adalah bagian penting.
- `Device Profile` di atas dipakai sebagai pelengkap konfigurasi client, bukan pengganti service token.
- Pada host, kredensial biasanya dipakai oleh file `mdm.xml` di `/var/lib/cloudflare-warp/mdm.xml` dan config Zero Trust di `/etc/autoscript/warp-zerotrust/config.env`.

## Menu Utama

```text
1) Xray Users
2) Xray QAC
3) Xray Network
4) Domain Control
5) Speedtest
6) Security
7) Maintenance
8) Traffic
9) Tools
0) Keluar
```

### Tools

```text
9) Tools
1) Telegram Bot
2) WARP Tier
3) Backup/Restore
4) License Guard
0) Back
```

## Backup/Restore

- `Backup/Restore` tersedia di:
  - CLI `manage` lewat `9) Tools -> 3) Backup/Restore`
  - bot Telegram lewat `Main Menu -> Backup/Restore`
- Provider cloud yang didukung:
  - `Google Drive`
  - `Cloudflare R2`
  - `Telegram` dipakai untuk backup lokal + restore upload dari chat
- Nama file backup manual memakai format:
  - `backup-YYYY-MM-DD-HH:MM.tar.gz`
- `safety backup` internal tetap dibuat otomatis sebelum restore penuh dan disimpan terpisah.
- Panduan setup provider cloud ada di [`docs/BACKUP_RESTORE_CLOUD.md`](/root/project/autoscript-lite/docs/BACKUP_RESTORE_CLOUD.md).

## Lisensi

Repo ini menggunakan lisensi `GPL-3.0-or-later`.

- detail lengkap tersedia di file [`LICENSE`](/root/project/autoscript-lite/LICENSE)
- website lisensi VPS dan flow aktivasi produk tidak mengubah lisensi source code repo ini

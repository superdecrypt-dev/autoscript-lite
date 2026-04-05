# Autoscript Lite

> Installer, runtime, dan panel operasional harian untuk stack `Xray-core`, `edge-mux`, `WARP`, dan bot `Telegram` di VPS Linux.

`autoscript-lite` adalah varian yang hanya menyajikan layanan `Xray-core`. Repo ini tidak memuat surface installer, CLI, bot, atau dokumentasi operasional untuk `SSH WS`, `OpenVPN`, `BadVPN`, dan menu turunannya.

Beberapa helper kompatibilitas internal masih tersisa untuk membaca state/runtime lama saat upgrade host lama ke snapshot terbaru. Itu bukan surface produk aktif dan tidak didokumentasikan sebagai fitur `lite`.

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
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript-lite/main/run.sh)
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
        +--> nginx       127.0.0.1:18080
        +--> Xray-core   via inbound runtime
```

## Layanan Utama

| Komponen | Peran | Status Runtime |
| --- | --- | --- |
| `edge-mux` | ingress publik untuk `Xray` | frontend utama |
| `xray` | core proxy untuk `VLESS`, `VMess`, `Trojan` | backend utama |
| `nginx` | HTTP backend internal dan TLS/web support | internal |
| `wireproxy` / `warp-svc` | runtime `WARP Free/Plus` atau `Zero Trust` | sesuai mode aktif |
| `xray-domain-guard` | guardrail domain, TLS, dan health check | maintenance |
| `bot-telegram-backend` | API internal bot Telegram | opsional |
| `bot-telegram-gateway` | gateway Telegram menu-first | opsional |

## Layanan dan Protokol

- `VLESS`, `VMess`, `Trojan`
- transport `XHTTP`, `WS`, `HTTPUpgrade`, `gRPC`, `TCP+TLS`
- `WARP Free/Plus`, `WARP Zero Trust`

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
| `Trojan XHTTP` | `443, 80` + alt port Cloudflare |
| `Trojan WS` | `443, 80` + alt port Cloudflare |
| `Trojan HUP` | `443, 80` + alt port Cloudflare |
| `Trojan gRPC` | `443, 80` + alt port Cloudflare |
| `Trojan TCP+TLS` | `443, 80` + alt port Cloudflare |

## Path Runtime

Gunakan hanya path publik di bawah ini untuk client. Jangan gunakan path internal acak backend `Xray` karena nilainya bisa berubah setiap install atau re-render config.

### Path Publik Stabil

| Transport | Path utama | Varian alt yang didukung | Catatan |
| --- | --- | --- | --- |
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

Path internal itu hanya dipakai untuk wiring `nginx -> Xray` di host.

## Portal Info Akun

- Setiap akun `Xray` bisa punya link portal read-only sendiri.
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

## Port Internal

| Komponen | Bind | Keterangan |
| --- | --- | --- |
| `nginx` | `127.0.0.1:18080` | backend web internal |
| `account-portal` | `127.0.0.1:7082` | website read-only info akun |
| `bot-telegram-backend` | `127.0.0.1:7081` | API internal bot Telegram |
| `edge-mux metrics` | `127.0.0.1:9910` | metrics dan status edge |
| `WARP local proxy` | `127.0.0.1:40000` | runtime `Zero Trust` / proxy lokal |

## Service Highlights

- `manage.sh` adalah panel CLI modular untuk operasi harian.
- `run.sh` dan `setup.sh` menangani bootstrap host, install runtime, dan sinkronisasi service.
- `account-portal/` menyediakan website mandiri untuk status akun per token.
- `bot-telegram/` menyediakan backend + gateway menu-first untuk operasi dari Telegram.
- `opt/edge/go/` memuat source `edge-mux` untuk ingress publik dan observability.
- `manage_bundle.zip` dan `bot_telegram.zip` dipakai sebagai release artifact untuk installer.

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

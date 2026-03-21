# Autoscript

> Installer, runtime, dan panel operasional harian untuk stack `Xray-core`, `SSH WS`, `Edge Gateway`, `WARP`, dan bot `Telegram` di VPS Linux.

Autoscript dirancang untuk operator yang ingin satu repo untuk:
- bootstrap server dari nol
- mengelola user `Xray` dan `SSH` dari CLI modular
- menjalankan ingress publik berbasis `Go edge-mux`
- mengoperasikan `WARP`, `BadVPN`, `Domain Guard`, dan bot `Telegram`

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/run.sh)
```

Catatan penting:
- Metadata aktif SSH berada di `/opt/quota/ssh/<username>@ssh.json`.
- Host lama yang masih memakai flow lain di luar menu resmi sebaiknya recreate akun dari panel saat upgrade besar.

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
| `badvpn-udpgw` | UDPGW lokal untuk payload/game tertentu | internal |
| `wireproxy` / `warp-svc` | runtime `WARP Free/Plus` atau `Zero Trust` | sesuai mode aktif |
| `xray-domain-guard` | guardrail domain, TLS, dan health check | maintenance |
| `bot-telegram-backend` | API internal bot Telegram | opsional |
| `bot-telegram-gateway` | gateway Telegram menu-first | opsional |

## Layanan dan Protokol
- `VLESS`, `VMess`, `Trojan`
- transport `XHTTP`, `WS`, `HTTPUpgrade`, `gRPC`, `TCP+TLS`
- `SSH WS`, `SSH SSL/TLS`, `SSH Direct`
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

## Path Publik

| Transport | Path / Service |
| --- | --- |
| `SSH WS` | `/<token>` dan `/<bebas>/<token>` |
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
| `bot-telegram-backend` | `127.0.0.1:7081` | API internal bot Telegram |
| `edge-mux metrics` | `127.0.0.1:9910` | metrics dan status edge |
| `WARP local proxy` | `127.0.0.1:40000` | runtime `Zero Trust` / proxy lokal |
| `BadVPN UDPGW` | `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900` | UDPGW lokal |

## Service Highlights
- `manage.sh` adalah panel CLI modular untuk operasi harian.
- `run.sh` dan `setup.sh` menangani bootstrap host, install runtime, dan sinkronisasi service.
- `bot-telegram/` menyediakan backend + gateway menu-first untuk operasi dari Telegram.
- `opt/edge/go/` memuat source `edge-mux` dan artefak distribusi ada di `opt/edge/dist/`.
- `manage_bundle.zip` dan `bot_telegram.zip` dipakai sebagai release artifact untuk installer.

## Menu Utama
```text
1) Xray Users
2) SSH Users
3) Xray QAC
4) SSH QAC
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

## Bot
### Telegram
- Entry point: `/menu`, `/cleanup`, `/start`
- UX sekarang menu-first dengan kategori `Status`, `Accounts`, `QAC`, `Domain`, `Network`, `Ops`
- Action mutasi dikendalikan lewat ACL admin Telegram, bukan lagi flag dangerous terpisah
- Detail: `bot-telegram/README.md`

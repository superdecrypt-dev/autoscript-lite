# Autoscript

> Installer dan panel operasional harian untuk Xray-core di VPS Linux.

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/run.sh)
```

Catatan penting:
- Metadata aktif SSH berada di `/opt/quota/ssh/<username>@ssh.json`.
- Host lama yang masih memakai flow lain di luar menu resmi sebaiknya recreate akun dari panel saat upgrade besar.

## Inti Install
- `Xray-core`
- `Edge Gateway` provider `go` sebagai ingress utama `80/443`
- `nginx` backend internal `127.0.0.1:18080`
- `SSH WS`, `SSH SSL/TLS`, dan `SSH Direct`
- `VLESS TCP+TLS` dan `Trojan TCP+TLS` via `Edge Gateway`
- `WARP`, `BadVPN UDPGW`, TLS, dan `xray-domain-guard`
- `manage.sh` untuk operasional harian
- installer bot `Discord` dan `Telegram`

## Protokol
- `VLESS`, `VMess`, `Trojan`
- transport `WS`, `HTTPUpgrade`, `gRPC`, `TCP+TLS` (khusus `VLESS` dan `Trojan`)
- `SSH WS`, `SSH SSL/TLS`, `SSH Direct`

## Port Utama
- publik `80/443`: ditangani `edge-mux` untuk `Xray` dan `SSH`
- `nginx` backend: `127.0.0.1:18080`
- `SSH dropbear`: `127.0.0.1:22022`
- `SSH stunnel`: `127.0.0.1:22443`
- `SSH WS proxy`: `127.0.0.1:10015`
- `BadVPN UDPGW`: `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900`

## Service Utama
- `edge-mux`
- `nginx`
- `xray`
- `sshws-dropbear`
- `sshws-stunnel`
- `sshws-proxy`
- `badvpn-udpgw`
- `xray-domain-guard`

## Catatan Operasional
- Pergantian domain lewat `6) Domain Control > Set Domain` akan me-refresh `XRAY ACCOUNT INFO` dan `SSH ACCOUNT INFO` ke domain baru.
- `SSH QAC` mengatur `quota`, `IP/Login limit`, `speed limit`, dan `expiry` khusus untuk SSH.

## Menu Utama
```text
1) Xray Users
2) SSH Users
3) Xray QAC
4) SSH QAC
5) Network
6) Domain Control
7) Speedtest
8) Security
9) Maintenance
10) Traffic
11) Discord Bot
12) Telegram Bot
0) Keluar
```

## Bot
### Telegram
- Entry point: `/menu`, `/cleanup`, `/start`
- UX sekarang menu-first dengan kategori `Status`, `Accounts`, `QAC`, `Domain`, `Network`, `Ops`
- Action mutasi dikendalikan lewat ACL admin Telegram, bukan lagi flag dangerous terpisah
- Detail: `bot-telegram/README.md`

### Discord
- Entry point utama: `/menu`
- Slash publik ringkas: `/menu`, `/status`, `/notify`
- Flow utama hybrid lewat button, select menu, modal, dan konfirmasi
- Pelengkap CLI, bukan pengganti penuh

## Command Cepat
```bash
bash run.sh
manage
install-discord-bot
install-telegram-bot
edge-provider-switch go
edge-provider-switch nginx-stream
```

## Dokumen Lanjutan
- `TESTING_PLAYBOOK.md`: SOP pengujian
- `AUDIT_PLAYBOOK.md`: SOP audit dan prioritas review
- `EDGE_PROVIDER_DESIGN.md`: desain teknis Edge Gateway

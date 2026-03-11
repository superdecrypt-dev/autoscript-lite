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
- `WARP`, `BadVPN UDPGW`, TLS, dan `xray-domain-guard`
- `manage.sh` untuk operasional harian
- installer bot `Discord` dan `Telegram`

## Protokol
- `VLESS`, `VMess`, `Trojan`, `Shadowsocks`, `Shadowsocks 2022`
- transport `WS`, `HTTPUpgrade`, `gRPC`
- `SSH WS`, `SSH SSL/TLS`, `SSH Direct`

## Port Utama
- publik `80/443`: ditangani `edge-mux` untuk `Xray` dan `SSH`
- `nginx` backend: `127.0.0.1:18080`
- `SSH dropbear`: `127.0.0.1:22022`
- `SSH stunnel`: `127.0.0.1:22443`
- `SSH WS proxy`: `127.0.0.1:10015`
- `BadVPN UDPGW`: `127.0.0.1:7300`

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
- Pergantian domain lewat `7) Domain Control > Set Domain` akan me-refresh `XRAY ACCOUNT INFO` dan `SSH ACCOUNT INFO` ke domain baru.
- `SSH QAC` mengatur `quota`, `IP/Login limit`, `speed limit`, dan `expiry` khusus untuk SSH.

## Menu Utama
```text
1) Status
2) Xray Users
3) SSH Users
4) Xray QAC
5) SSH QAC
6) Network
7) Domain Control
8) Speedtest
9) Security
10) Maintenance
11) Traffic
12) Discord Bot
13) Telegram Bot
```

## Bot
### Telegram
- Entry point: `/panel`, `/cleanup`
- Xray dan SSH sudah dipisah
- Action dangerous disembunyikan saat `ENABLE_DANGEROUS_ACTIONS=false`
- Detail: `bot-telegram/README.md`

### Discord
- Entry point utama: `/panel`
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

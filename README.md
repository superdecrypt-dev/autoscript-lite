# Autoscript

> Installer dan panel operasional harian untuk Xray-core di VPS Linux.

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/run.sh)
```

## Inti Install
- `Xray-core`
- `Edge Gateway` provider `go` sebagai ingress utama `80/443`
- `nginx` backend internal `127.0.0.1:18080`
- `SSH WS`, `SSH SSL/TLS`, dan `SSH Direct`
- `OpenVPN TCP`, `OpenVPN SSL/TLS`, dan `OpenVPN WS`
- `WARP`, `BadVPN UDPGW`, TLS, dan daemon observability
- `manage.sh` untuk operasional harian
- installer bot `Discord` dan `Telegram`

## Protokol
- `VLESS`, `VMess`, `Trojan`, `Shadowsocks`, `Shadowsocks 2022`
- transport `WS`, `HTTPUpgrade`, `gRPC`
- `SSH WS`, `SSH SSL/TLS`, `SSH Direct`
- `OpenVPN TCP`, `OpenVPN SSL/TLS`, `OpenVPN WS`

## Port Utama
- publik `80/443`: ditangani `edge-mux` untuk `Xray`, `SSH`, dan `OpenVPN`
- `nginx` backend: `127.0.0.1:18080`
- `SSH dropbear`: `127.0.0.1:22022`
- `SSH stunnel`: `127.0.0.1:22443`
- `SSH WS proxy`: `127.0.0.1:10015`
- `OpenVPN core`: `127.0.0.1:21194`
- `OpenVPN WS proxy`: `127.0.0.1:21195`
- `BadVPN UDPGW`: `127.0.0.1:7300`

## Service Utama
- `edge-mux`
- `nginx`
- `xray`
- `sshws-dropbear`
- `sshws-stunnel`
- `sshws-proxy`
- `ovpn-tcp`
- `ovpnws-proxy`
- `badvpn-udpgw`
- `xray-observe`
- `xray-domain-guard`

## Menu Utama
```text
1) Status
2) Xray Users
3) SSH & OVPN User
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

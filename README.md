# Autoscript

> Installer dan panel operasional harian untuk Xray-core di VPS Linux.

`setup.sh` dipakai sekali untuk provisioning.
Implementasi installer sekarang dimodularisasi di `opt/setup/`.
`manage.sh` dipakai untuk operasi harian.
Bot standalone tersedia di `bot-discord/` dan `bot-telegram/`.

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/run.sh)
```

### Quick Install OpenVPN Edge
```bash
OVPN_ENABLE_TCP=true OVPN_ENABLE_SSL=true OVPN_ENABLE_WS=true \
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/run.sh)
```

## Komponen
- `run.sh`: bootstrap installer
- `setup.sh`: orchestrator provisioning awal
- `opt/setup/`: modul installer, template, dan asset runtime setup
- `manage.sh`: panel operasional
- `install-discord-bot.sh`: installer bot Discord
- `install-telegram-bot.sh`: installer bot Telegram

## Menu Utama
```text
1) Status & Diagnostics
2) Xray Management
3) SSH Management
4) Xray QAC
5) SSH QAC
6) Network Controls
7) Domain Control
8) Speedtest
9) Security
10) Maintenance
11) Traffic Analytics
12) Install BOT Discord
13) Install BOT Telegram
```

## Fitur Inti
- Xray, Nginx, TLS, WARP, dan daemon runtime
- Installer modular via `opt/setup/*`
- Operasional akun Xray dan SSH dari satu menu
- QAC untuk Xray dan seluruh surface SSH yang dikelola edge
- Edge Gateway (provider `go`) aktif di `80/443`
- provider `nginx-stream` tersedia sebagai opsi experimental
- nginx berjalan sebagai backend internal `127.0.0.1:18080`
- SSH WS di `80/443`
- SSH SSL/TLS di `80/443`
- SSH Direct di `80/443`
- BadVPN UDPGW tersedia untuk ekosistem SSH di `127.0.0.1:7300`
- OpenVPN `TCP`, `SSL/TLS`, dan `WS` tersedia secara opt-in di atas Edge Gateway
- Artefak demo OpenVPN sekarang ikut menulis paket klien resmi:
  - `*-tcp.ovpn`
  - `*-tcp-run.sh`
  - `*-ssl.ovpn` + `*-ssl-helper.py` + `*-ssl-run.sh`
  - `*-ws.ovpn` + `*-ws-helper.py` + `*-ws-run.sh`
- SSH WS token path per-user: `/<token>` atau `/<bebas>/<token>`
- SSH QAC berlaku sebagai satu sistem SSH pada:
  - `SSH WS`
  - `SSH Direct`
  - `SSH SSL/TLS`
- `sshd:22` native tetap bukan target traffic enforcement
- Bot Discord dan Telegram standalone

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
OVPN_ENABLE_TCP=true OVPN_ENABLE_SSL=true OVPN_ENABLE_WS=true bash run.sh
```

## Dokumen Lanjutan
- `TESTING_PLAYBOOK.md`: SOP pengujian
- `AUDIT_PLAYBOOK.md`: SOP audit dan prioritas review
- `EDGE_PROVIDER_DESIGN.md`: desain teknis Edge Gateway

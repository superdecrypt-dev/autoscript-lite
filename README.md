# Autoscript

> Installer dan panel operasional harian untuk Xray-core di VPS Linux.

`setup.sh` dipakai sekali untuk provisioning.
`manage.sh` dipakai untuk operasi harian.
Bot standalone tersedia di `bot-discord/` dan `bot-telegram/`.

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/run.sh)
```

## Komponen
- `run.sh`: bootstrap installer
- `setup.sh`: provisioning awal
- `manage.sh`: panel operasional
- `install-discord-bot.sh`: installer bot Discord
- `install-telegram-bot.sh`: installer bot Telegram

## Menu Utama
```text
1) Status & Diagnostics
2) Xray Management
3) SSH Management
4) Xray Quota & Access Control
5) SSH Quota & Access Control
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
- Operasional akun Xray dan SSH dari satu menu
- QAC untuk Xray dan SSHWS
- SSH WebSocket di `80/443`
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
manage
install-discord-bot
install-telegram-bot
```

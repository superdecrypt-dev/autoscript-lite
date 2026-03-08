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
- Installer modular via `opt/setup/*`
- Operasional akun Xray dan SSH dari satu menu
- QAC untuk Xray dan seluruh surface SSH yang dikelola edge
- Edge Gateway (provider `go`) aktif di `80/443`
- HAProxy fallback standby tersedia di `18082/18444`
- provider `nginx-stream` tersedia sebagai opsi experimental
- nginx berjalan sebagai backend internal `127.0.0.1:18080`
- SSH WS di `80/443`
- SSH SSL/TLS di `80/443`
- SSH Direct di `80/443`
- SSH WS token path per-user: `/<token>` atau `/<bebas>/<token>`
- QAC SSH berlaku seperti ini:
  - `SSH WS`: quota, speed, dan IP/Login limit
  - `SSH Direct` / `SSH SSL/TLS`: quota, speed, dan IP/Login limit saat provider aktif adalah `Edge Gateway (go)`
  - `sshd:22` native: bukan target traffic enforcement
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
edge-provider-switch haproxy
edge-provider-switch go
edge-provider-switch nginx-stream
```

## Dokumen Lanjutan
- `TESTING_PLAYBOOK.md`: SOP pengujian
- `AUDIT_PLAYBOOK.md`: SOP audit dan prioritas review

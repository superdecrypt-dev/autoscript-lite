# Telegram Bot Architecture Lock

## Scope
Bot Telegram ini standalone dan tidak mengeksekusi `manage.sh` secara langsung.

## Runtime
- Backend API: `backend-py` (FastAPI) pada `127.0.0.1:7081`
- Gateway Telegram: `gateway-py` (long polling)
- Shared contract: `shared/commands.json`

## Service Units
- `bot-telegram-backend.service`
- `bot-telegram-gateway.service`
- `bot-telegram-monitor.service` + timer

## Security Baseline
- Semua endpoint backend menggunakan `X-Internal-Shared-Secret`.
- Auth bot di gateway berbasis `TELEGRAM_ADMIN_CHAT_IDS` dan/atau `TELEGRAM_ADMIN_USER_IDS`.
- Secret/env disimpan di `/etc/bot-telegram/bot.env` (mode 600).

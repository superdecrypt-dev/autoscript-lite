[Unit]
Description=Bot Telegram Lightweight Monitor
After=network-online.target bot-telegram-backend.service bot-telegram-gateway.service
Wants=network-online.target

[Service]
Type=oneshot
User=bot-telegram-gateway
EnvironmentFile=/etc/bot-telegram/bot.env
ExecStart=/opt/bot-telegram/scripts/monitor-lite.sh --quiet

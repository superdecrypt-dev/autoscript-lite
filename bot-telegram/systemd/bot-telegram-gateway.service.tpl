[Unit]
Description=Bot Telegram Gateway (python-telegram-bot)
After=network-online.target bot-telegram-backend.service
Wants=network-online.target

[Service]
Type=simple
User=bot-telegram-gateway
WorkingDirectory=/opt/bot-telegram/gateway-py
EnvironmentFile=/etc/bot-telegram/bot.env
ExecStartPre=+/usr/local/bin/autoscript-license-check check --stage runtime --allow-disabled=false
ExecStart=/opt/bot-telegram/.venv/bin/python -m app.main
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target

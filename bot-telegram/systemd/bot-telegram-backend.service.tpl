[Unit]
Description=Bot Telegram Backend (FastAPI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/bot-telegram/backend-py
EnvironmentFile=/etc/bot-telegram/bot.env
ExecStart=/opt/bot-telegram/.venv/bin/python -m uvicorn app.main:app --host ${BACKEND_HOST} --port ${BACKEND_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target

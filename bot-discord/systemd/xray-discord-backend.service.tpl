[Unit]
Description=Xray Discord Backend (FastAPI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/bot-discord/backend-py
EnvironmentFile=/etc/xray-discord-bot/bot.env
ExecStart=/opt/bot-discord/.venv/bin/python -m uvicorn app.main:app --host ${BACKEND_HOST} --port ${BACKEND_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target

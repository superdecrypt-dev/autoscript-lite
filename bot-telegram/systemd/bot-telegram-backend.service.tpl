[Unit]
Description=Bot Telegram Backend (FastAPI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/bot-telegram/backend-py
EnvironmentFile=/etc/bot-telegram/bot.env
ExecStartPre=+/usr/local/bin/autoscript-license-check check --stage runtime --allow-disabled=false
ExecStart=/opt/bot-telegram/.venv/bin/python -m uvicorn app.main:app --host ${BACKEND_HOST} --port ${BACKEND_PORT}
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native
UMask=0077

[Install]
WantedBy=multi-user.target

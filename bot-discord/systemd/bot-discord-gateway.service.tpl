[Unit]
Description=Bot Discord Gateway (discord.js)
After=network-online.target bot-discord-backend.service
Wants=network-online.target

[Service]
Type=simple
User=bot-discord-gateway
WorkingDirectory=/opt/bot-discord/gateway-ts
EnvironmentFile=/etc/bot-discord/bot.env
ExecStart=/usr/bin/node /opt/bot-discord/gateway-ts/dist/index.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target

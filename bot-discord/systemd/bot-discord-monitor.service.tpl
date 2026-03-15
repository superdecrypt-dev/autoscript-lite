[Unit]
Description=Bot Discord Lightweight Monitor
After=network-online.target bot-discord-backend.service bot-discord-gateway.service
Wants=network-online.target

[Service]
Type=oneshot
User=bot-discord-gateway
EnvironmentFile=/etc/bot-discord/bot.env
ExecStart=/opt/bot-discord/scripts/monitor-lite.sh --quiet

[Unit]
Description=Bot Telegram Lightweight Monitor
After=network-online.target bot-telegram-backend.service bot-telegram-gateway.service
Wants=network-online.target

[Service]
Type=oneshot
User=bot-telegram-gateway
EnvironmentFile=/etc/bot-telegram/bot.env
ExecStartPre=+/usr/local/bin/autoscript-license-check check --stage runtime --allow-disabled=false
ExecStart=/opt/bot-telegram/scripts/monitor-lite.sh --quiet
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/bot-telegram /var/log/bot-telegram /var/lib/autoscript-license
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native
UMask=0077

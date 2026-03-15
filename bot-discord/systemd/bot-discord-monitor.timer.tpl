[Unit]
Description=Run Bot Discord Lightweight Monitor every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=20
Persistent=true
Unit=bot-discord-monitor.service

[Install]
WantedBy=timers.target

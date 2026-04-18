# opt/setup/templates

Folder ini berisi template config/runtime yang masih dipakai surface aktif `autoscript-lite`.

Template aktif utama:
- `nginx/xray.conf`
- `nginx/nginx.conf`
- `nginx/stream-edge.conf`
- `config/adblock.env`
- `config/adblock-dnsmasq.conf`
- `config/edge-runtime.env`
- `config/warp-zerotrust.env`
- `config/xray-speed-config.json`
- `systemd/account-portal.service`
- `systemd/adblock-dns.service`
- `systemd/adblock-sync.service`
- `systemd/adblock-update.service`
- `systemd/adblock-update.timer`
- `systemd/autoscript-license-enforcer.service`
- `systemd/autoscript-license-enforcer.timer`
- `systemd/edge-mux.service`
- `systemd/wireproxy.service`
- `systemd/xray-confdir.conf`
- `systemd/xray-domain-guard.service`
- `systemd/xray-domain-guard.timer`
- `systemd/xray-expired.service`
- `systemd/xray-limit-ip.service`
- `systemd/xray-quota.service`
- `systemd/xray-speed.service`

Catatan:
- runtime Hysteria 2 native sekarang dirender langsung ke `Xray conf.d` oleh `hysteria2-manage`, bukan lewat service standalone.
- `systemd/hysteria2-expired.service` masih dipakai sebagai cleaner untuk prune user expired lalu restart `xray.service`.

Template non-Xray yang tidak lagi wired ke installer `lite` sudah dibersihkan dari folder ini.

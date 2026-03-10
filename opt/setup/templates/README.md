# opt/setup/templates

Template besar dari `setup.sh` sebaiknya dipindah ke sini secara bertahap.

Yang sudah dipindah pada tahap awal:
- `nginx/xray.conf`
- `systemd/sshws-dropbear.service`
- `systemd/sshws-stunnel.service`
- `systemd/sshws-proxy.service`
- `systemd/sshws-qac-enforcer.service`
- `systemd/sshws-qac-enforcer.timer`
- `systemd/xray-confdir.conf`
- `systemd/xray-speed.service`
- `systemd/wireproxy.service`
- `systemd/xray-expired.service`
- `systemd/xray-limit-ip.service`
- `systemd/xray-quota.service`
- `systemd/xray-observe.service`
- `systemd/xray-observe.timer`
- `systemd/xray-domain-guard.service`
- `systemd/xray-domain-guard.timer`
- `config/sshws-stunnel.conf`
- `config/xray-speed-config.json`
- `nginx/nginx.conf`
- `systemd/ovpn-tcp.service`
- `systemd/ovpnws-proxy.service`
- `config/openvpn-runtime.env`
- `config/openvpn/server-tcp.conf`
- `config/openvpn/client-run-wrapper-tcp.sh`
- `config/openvpn/client-tunnel-helper-tls.py`
- `config/openvpn/client-tunnel-helper-ws.py`
- `config/openvpn/client-run-wrapper.sh`

Target berikutnya yang masih layak dipindah:
- `systemd/xray.service.d/10-confdir.conf`
- script `xray-observe`
- script `xray-domain-guard`
- config `xray-observe/config.env`
- config `xray-domain-guard/config.env`

Tujuan:
- mengurangi ukuran `setup.sh`
- mempermudah diff dan audit template
- memisahkan logic install dari payload file konfigurasi

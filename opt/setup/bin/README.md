# opt/setup/bin

Script executable yang sebelumnya dihasilkan dari heredoc di `setup.sh` dipindah ke folder ini secara bertahap.

Helper aktif utama:
- `xray-domain-guard`
- `xray-speed.py`
- `xray-warp-sync.py`
- `xray-ws-control.py`
- `autoscript-license-check`
- `backup-manage.py`

Komponen Go yang sekarang juga aktif:
- `opt/edge/go/cmd/edge-mux`
- `opt/edge/go/cmd/wsproxy`

Catatan:
- file di sini adalah source repo
- saat provisioning, `setup.sh` menyalin/menaruhnya ke path runtime seperti `/usr/local/bin/...`
- helper legacy non-Xray yang tidak lagi wired ke installer `lite` sudah dibersihkan dari folder ini

# opt/setup/bin

Script executable yang sebelumnya dihasilkan dari heredoc di `setup.sh` dipindah ke folder ini secara bertahap.

Helper aktif utama:
- `xray-domain-guard`
- `xray-session.py`
- `xray-speed.py`
- `xray-warp-sync.py`
- `autoscript-license-check`
- `backup-manage.py`
- `hysteria2-manage.py`
- `hysteria2-expired.py`

Komponen Go yang sekarang juga aktif:
- `opt/edge/go/cmd/edge-mux`

Catatan:
- file di sini adalah source repo
- saat provisioning, `setup.sh` menyalin/menaruhnya ke path runtime seperti `/usr/local/bin/...`
- helper non-Xray yang tidak lagi wired ke installer `lite` sudah dibersihkan dari folder ini

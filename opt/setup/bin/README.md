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

Catatan Hysteria native:
- `hysteria2-manage.py` tetap memakai `users.json` sebagai source of truth untuk add/list/render akun.
- `hysteria2-expired.py` memakai `xray api rmu` hanya untuk sinkron remove user expired ke runtime agar tidak perlu restart penuh setiap kali prune.
- jalur `xray api` untuk add/list/count user Hysteria belum dianggap andal, jadi tidak dipakai sebagai control plane utama.

Komponen Go yang sekarang juga aktif:
- `opt/edge/go/cmd/edge-mux`

Catatan:
- file di sini adalah source repo
- saat provisioning, `setup.sh` menyalin/menaruhnya ke path runtime seperti `/usr/local/bin/...`
- helper non-Xray yang tidak lagi wired ke installer `lite` sudah dibersihkan dari folder ini

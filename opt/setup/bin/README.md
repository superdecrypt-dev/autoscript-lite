# opt/setup/bin

Script executable yang sebelumnya dihasilkan dari heredoc di `setup.sh`
dipindah ke folder ini secara bertahap.

Yang sudah dipindah:
- `sshws-proxy.py`
- `sshws-qac-enforcer.py`
- `xray-speed.py`
- `xray-observe`
- `xray-domain-guard`
- `ovpnws-proxy.py`

Kandidat berikutnya bila masih ada script inline baru:
- utility Python/Bash tambahan yang saat ini masih dibuat langsung dari `setup.sh`

Catatan:
- file di sini adalah source repo
- saat provisioning, `setup.sh` menyalin/menaruhnya ke path runtime seperti
  `/usr/local/bin/...`
- setelah dipindah, file-file ini bisa diuji langsung tanpa ekstraksi heredoc

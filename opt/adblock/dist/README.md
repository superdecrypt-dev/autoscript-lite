# opt/adblock/dist

Direktori ini berisi binary prebuilt `adblock-sync` untuk runtime installer.

Status:
- `adblock-sync-linux-amd64`: dipakai pada host `x86_64/amd64`
- `adblock-sync-linux-arm64`: dipakai pada host `aarch64/arm64`

Catatan:
- Binary dibangun dari source Go di `opt/adblock/go/`.
- `setup.sh` dan `run.sh` menganggap prebuilt ini sebagai artifact wajib.
- Jika source Go berubah, rebuild artifact di direktori ini sebelum commit.

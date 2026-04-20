# Xray Modular Templates

Direktori ini adalah source template modular untuk `conf.d` Xray.

Aturan:
- `write_xray_modular_configs()` merender file di direktori ini ke `/usr/local/etc/xray/conf.d/`.
- Placeholder `__...__` dirender saat bootstrap/install.
- File di sini adalah source of truth untuk runtime modular Xray.
- Jangan isi direktori ini dengan snapshot runtime manual.

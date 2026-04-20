# opt/setup

Struktur ini sekarang aktif dipakai oleh `setup.sh`.
Tujuannya tetap sama: menjaga alur install tetap eksplisit, tetapi memindahkan
implementasi ke modul yang lebih kecil dan mudah diaudit.

Prinsip:
- `setup.sh` tetap menjadi entrypoint provisioning.
- Urutan install tetap eksplisit di `setup.sh`.
- Modul di-`source` dari path repo lokal (`${SCRIPT_DIR}/opt/setup/...`), bukan
  dari `/opt/setup`, agar tetap aman pada flow `run.sh` yang dapat membersihkan
  source repo setelah install.
- Refactor dilakukan bertahap dan harus menjaga idempotency setiap langkah.

## Status Saat Ini

- `setup.sh` sudah menjadi orchestrator tipis.
- Modul aktif:
  - `core/`
  - `install/`
  - `bin/`
  - `templates/`
- `install/edge.sh` sekarang sudah dipakai untuk jalur `Edge Gateway`.
- `install/network.sh` sekarang juga memegang fondasi backend `Zero Trust` berbasis `cloudflare-warp`.
- Full E2E live `run.sh` dengan source lokal repo sudah PASS pada `2026-03-08`.
- Validasi minimum yang sudah lolos:
  - `bash -n setup.sh opt/setup/core/*.sh opt/setup/install/*.sh`
  - `shellcheck -x -S warning setup.sh opt/setup/core/*.sh opt/setup/install/*.sh`
  - `python3 -m py_compile opt/setup/bin/*.py`
  - `go -C opt/edge/go test ./...`

## Target Struktur

```text
opt/setup/
  README.md
  core/
    env.sh
    logging.sh
    helpers.sh
  install/
    bootstrap.sh
    domain.sh
    edge.sh
    nginx.sh
    xray.sh
    network.sh
    domain_guard.sh
    management.sh
  templates/
    README.md
  bin/
    README.md
```

## Mapping Step Install Saat Ini

Urutan aktual `setup.sh` saat ini tetap menjadi sumber kebenaran.

1. `need_root`, `ensure_runtime_lock_dirs`, `ensure_stdin_available`, `check_os`
   - target modul: `core/*.sh`, `install/bootstrap.sh`
2. `install_base_deps`, `install_extra_deps`, `install_speedtest_snap`
   - target modul: `install/bootstrap.sh`
3. `enable_cron_service`, `setup_time_sync_chrony`, `enable_bbr`,
   `setup_swap_2gb`, `tune_ulimit`, `install_fail2ban_aggressive`
   - target modul: `install/network.sh`
4. `install_wgcf`, `setup_wgcf`, `install_wireproxy`, `setup_wireproxy`,
   `install_cloudflare_warp`, `setup_warp_zero_trust_backend`
   - target modul: `install/network.sh`
5. `domain_menu_v2`, Cloudflare helpers, `install_acme_and_issue_cert`
   - target modul: `install/domain.sh`
6. `install_nginx_official_repo`, `write_nginx_main_conf`, `write_nginx_config`
   - target modul: `install/nginx.sh`
7. `install_edge_provider_stack`
   - target modul: `install/edge.sh`
8. `install_xray`, `write_xray_config`, `write_xray_modular_configs`,
   `configure_xray_service_confdir`, `setup_xray_geodata_updater`
   - target modul: `install/xray.sh`
   - template modular: `templates/xray-conf.d/*.json`
9. `install_xray_speed_limiter_foundation`
    - target modul: `install/xray.sh`
10. `setup_logrotate`, `install_domain_cert_guard`
    - target modul: `install/domain_guard.sh`
11. `install_management_scripts`, `sync_manage_modules_layout`,
    `install_bot_installer_if_present`
    - target modul: `install/management.sh`
12. `setup_logrotate`, `sanity_check`, `cleanup`
    - target modul: `install/bootstrap.sh`, `install/domain_guard.sh`

## Tahapan Refactor

### Tahap 1
- Keluarkan heredoc Python dan template besar dari `setup.sh`.
- Tempat tujuan:
  - `opt/setup/bin/`
  - `opt/setup/templates/`
- Risiko rendah, dampak pengurangan ukuran file paling besar.
- Status: selesai.

### Tahap 2
- Pindahkan helper umum ke `core/`.
- Pastikan tidak ada duplikasi fungsi seperti `bool_is_true`, `safe_int`,
  `detect_domain`, dan helper logging.
- Tambahkan scaffold provider edge di `opt/edge/` dan `install/edge.sh`
  tanpa mengaktifkan runtime baru.
- Status: baseline selesai; lanjutkan perapihan hanya jika ditemukan drift baru.

### Tahap 3
- Pindahkan installer besar per domain tanggung jawab ke `install/*.sh`.
- `setup.sh` menjadi orchestrator tipis yang hanya memuat modul dan memanggil
  langkah secara berurutan.
- Status: aktif dipakai.

### Tahap 4
- Jalankan smoke test:
  - `bash -n setup.sh`
  - `shellcheck`
  - `python3 -m py_compile` untuk script Python yang dipisah
  - full E2E `run.sh`
- Status: lolos, dengan domain random `vyxara2.web.id`.

## Catatan Implementasi

- Jangan tarik implementasi besar kembali ke `setup.sh`.
- Pertahankan source of truth per area di modulnya masing-masing.
- Saat menambah langkah install baru:
  - utamakan file di `install/*.sh`
  - letakkan helper generik di `core/*.sh`
  - letakkan asset runtime di `bin/`
  - letakkan config/unit di `templates/`
- Untuk file yang hanya dibutuhkan saat install, cukup simpan di repo lokal.
- Untuk file yang harus hidup setelah install, salin ke `/usr/local/bin`,
  `/etc/systemd/system`, atau path runtime lain saat provisioning.

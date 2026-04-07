# Manage Modules

Direktori ini adalah source modular untuk runtime `manage`.

- Source di repo: `opt/manage/...`
- Target deploy di VPS: `/opt/manage/...`
- Binary entrypoint tetap: `manage.sh` -> `/usr/local/bin/manage`

## Status Arsitektur Saat Ini

Modularisasi CLI masih berjalan bertahap.

- Loader `manage.sh` sekarang me-load module `core/`, aggregator `features/*.sh`,
  router `menus/`, dan entrypoint `app/main.sh`
- `app/main.sh` tetap menjadi entrypoint runtime:
  - tanpa argumen masuk ke menu interaktif
  - dengan argumen action akan mendelegasikan ke `core/router.sh`
- File besar `analytics.sh`, `network.sh`, serta area `users/domain/maintenance`
  kini dipecah ke child module per domain menu
- `manage.sh` masih memegang helper runtime inti lintas-domain, tetapi bukan lagi
  source of truth untuk menu `1` sampai `9`

## Tree Singkat

```text
opt/manage/
├── app/
├── core/
├── features/
│   ├── analytics.sh
│   ├── analytics/
│   ├── domain.sh
│   ├── domain/
│   ├── maintenance.sh
│   ├── maintenance/
│   ├── network.sh
│   ├── network/
│   ├── users.sh
│   └── users/
└── menus/
```

## Peta Source of Truth

- `opt/manage/features/users.sh`: aggregator live untuk `1) Xray Users` dan `2) Xray QAC`
- `opt/manage/features/users/xray_users.sh`: source of truth `Xray Users`
- `opt/manage/features/users/xray_qac.sh`: source of truth `Xray QAC`
- `opt/manage/features/network.sh`: aggregator live untuk `3) Xray Network` dan `5) Speedtest`
- `opt/manage/features/network/warp.sh`: WARP/Tier/runtime WARP
- `opt/manage/features/network/routing.sh`: routing Xray untuk WARP/domain/geosite
- `opt/manage/features/network/dns.sh`: DNS settings dan DNS add-ons
- `opt/manage/features/network/adblock.sh`: adblock DNS runtime/add-ons
- `opt/manage/features/network/diagnostics.sh`: checks/menu network
- `opt/manage/features/network/speedtest.sh`: speedtest
- `opt/manage/features/domain.sh`: aggregator live untuk `4) Domain Control`
- `opt/manage/features/domain/cloudflare.sh`: helper Cloudflare/DNS domain
- `opt/manage/features/domain/control.sh`: source of truth `Domain Control`
- `opt/manage/features/maintenance.sh`: aggregator live untuk `6) Security`, `7) Maintenance`, dan utilitas `9) Tools`
- `opt/manage/features/maintenance/services.sh`: WARP status/restart, Edge, daemon status
- `opt/manage/features/maintenance/logs.sh`: helper log/tail maintenance
- `opt/manage/features/maintenance/security.sh`: source of truth `6) Security`
- `opt/manage/features/maintenance/tools.sh`: source of truth utilitas eksternal (`Telegram Bot`, `License Guard`)
- `opt/manage/features/analytics.sh`: aggregator live untuk `8) Traffic`
- `opt/manage/features/analytics/traffic.sh`: source of truth `8) Traffic`
- `opt/manage/features/backup.sh`: source of truth `9) Tools > Backup/Restore`
- `opt/manage/core/router.sh`: dispatch action CLI non-interaktif
- `opt/manage/menus/main_menu.sh`: router menu utama interaktif
- `opt/manage/menus/user_menu.sh`: wrapper ke handler `Xray Users`
- `opt/manage/menus/network_menu.sh`: wrapper ke handler `Xray Network`
- `opt/manage/menus/domain_menu.sh`: wrapper ke handler `Domain Control`
- `opt/manage/menus/maintenance_menu.sh`: wrapper ke handler `7) Maintenance`
- `opt/manage/app/main.sh`: entrypoint modular runtime `manage`
- `manage.sh`: helper runtime inti lintas-domain, trusted loader, konstanta, dan bootstrap

Gunakan peta ini saat audit atau patch agar perubahan masuk ke child module yang
tepat, bukan kembali menumpuk di aggregator atau `manage.sh`.

## Ringkasan Fitur Manage

- `1) Xray Users`
  CRUD user Xray, expiry, reset credential, listing, dan recovery journal.
- `2) Xray QAC`
  Quota, block, IP limit, speed limit, dan detail metadata user Xray.
- `3) Xray Network`
  WARP, DNS settings/add-ons, dan diagnostics runtime Xray.
- `4) Domain Control`
  Set domain, current domain, guard check/renew, refresh account info, dan repair target DNS.
- `5) Speedtest`
  Run speedtest dan version check.
- `6) Security`
  TLS/cert menu, fail2ban, dan tuning sistem.
- `7) Maintenance`
  Restart/status service, log, dan status daemon.
- `8) Traffic`
  Analytics dan ringkasan traffic runtime.
- `9) Tools`
  Telegram Bot, WARP Tier, dan Backup/Restore.
  `WARP Tier` sekarang dibagi ke status utama berbasis `mode`, submenu `Free/Plus`, dan submenu `Zero Trust`.
  `Zero Trust` memakai backend `cloudflare-warp` untuk proxy lokal Xray; backend WARP lokal tetap kompatibel untuk redirect runtime Xray.
  Fondasi paket/runtime `cloudflare-warp` sekarang dipersiapkan dari `setup.sh`, tetapi mode ini tetap idle sampai diaktifkan operator.
  `manage` startup juga menjalankan guard lisensi IP memakai URL license bawaan; IP expired atau revoked dari portal Cloudflare akan ditolak sebelum panel dibuka.

## Guardrail Maintainer

- Simpan top-level `features/*.sh` tetap tipis sebagai aggregator.
- Tambahan logic baru harus masuk ke child module domain yang relevan.
- Jika ada helper lintas-domain baru, pertimbangkan pindah ke `core/` atau helper
  bersama di `manage.sh`, jangan duplikasi antar child module.
- Lakukan pemindahan per action/menu kecil, bukan menggabungkan kembali monolith.
- Setelah memindah logic ke modul, sinkronkan:
  - router / menu entry
  - validasi runtime
  - dokumentasi handoff / release notes bila behavior user-facing berubah

## Testing Source Lokal di VPS

- Saat `manage.sh` dijalankan dari working tree repo, loader sekarang memprioritaskan
  source lokal `opt/manage/...` lebih dulu dibanding copy runtime `/opt/manage/...`.
- Untuk smoke test atau rerun installer memakai source repo terbaru di host yang sama,
  gunakan:

```bash
RUN_USE_LOCAL_SOURCE=1 bash run.sh
```

- Jika Anda mengubah flow user-facing, verifikasi dua hal:
  - source repo yang sedang diedit memang dipanggil
  - copy runtime di VPS sudah tersinkron bila pengujian dilakukan lewat install aktif

Ini penting supaya hasil audit/live test tidak keliru membaca perilaku copy lama di
`/opt/manage/...` sebagai perilaku source repo terbaru.

## Catatan Transisi

- `manage.sh` masih menyimpan helper runtime inti yang dipakai lintas banyak menu.
- Refactor selanjutnya sebaiknya melanjutkan ekstraksi helper bersama ke `core/`
  bila benar-benar lintas-domain, bukan memindahkan ulang source of truth menu
  yang sudah ada di child module.

# Manage Modules

Direktori ini adalah source modular untuk runtime `manage`.

- Source di repo: `opt/manage/...`
- Target deploy di VPS: `/opt/manage/...`
- Binary entrypoint tetap: `manage.sh` -> `/usr/local/bin/manage`

## Status Arsitektur Saat Ini

Modularisasi CLI masih berjalan bertahap.

- Loader `manage.sh` sekarang me-load module `core/`, aggregator `features/*.sh`,
  router `menus/`, dan entrypoint `app/main.sh`
- File besar `analytics.sh`, `network.sh`, serta area `users/domain/maintenance`
  kini dipecah ke child module per domain menu
- `manage.sh` masih memegang helper runtime inti lintas-domain, tetapi bukan lagi
  source of truth untuk menu `1`, `3`, `8`, `10`, `11`, `12`, `13`, dan area
  besar di `5`

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

- `opt/manage/features/users.sh`: aggregator live untuk `1) Xray Users` dan `3) Xray QAC`
- `opt/manage/features/users/xray_users.sh`: source of truth `Xray Users`
- `opt/manage/features/users/xray_qac.sh`: source of truth `Xray QAC`
- `opt/manage/features/domain.sh`: aggregator live untuk `8) Domain Control`
- `opt/manage/features/domain/cloudflare.sh`: helper Cloudflare/DNS domain
- `opt/manage/features/domain/control.sh`: source of truth `Domain Control`
- `opt/manage/features/network.sh`: aggregator live untuk `5) Xray Network`, `7) Adblocker`, `9) Speedtest`, dan flow `WARP Tier`
- `opt/manage/features/network/warp.sh`: WARP/Tier/runtime WARP
- `opt/manage/features/network/routing.sh`: routing Xray untuk WARP/domain/geosite
- `opt/manage/features/network/adblock.sh`: adblock Xray + SSH
- `opt/manage/features/network/dns.sh`: DNS settings dan DNS add-ons
- `opt/manage/features/network/diagnostics.sh`: checks/menu network
- `opt/manage/features/network/speedtest.sh`: speedtest
- `opt/manage/features/analytics.sh`: aggregator live untuk `2) SSH Users`, `4) SSH QAC`, `6) SSH Network`, `10) Security`, `12) Traffic`, dan layar utilitas di `13) Tools`
- `opt/manage/features/analytics/traffic.sh`: `12) Traffic`
- `opt/manage/features/analytics/security.sh`: `10) Security`
- `opt/manage/features/analytics/runtime_services.sh`: helper runtime SSH/SSHWS
- `opt/manage/features/analytics/ssh_users.sh`: `2) SSH Users`
- `opt/manage/features/analytics/ssh_network.sh`: `6) SSH Network`
- `opt/manage/features/analytics/ssh_qac.sh`: `4) SSH QAC`
- `opt/manage/features/analytics/tools.sh`: `13) Tools > Telegram Bot`
- `opt/manage/features/maintenance.sh`: aggregator live untuk helper `11) Maintenance`
- `opt/manage/features/maintenance/services.sh`: WARP status/restart, Edge, BadVPN, daemon status
- `opt/manage/features/maintenance/logs.sh`: helper log/tail maintenance
- `opt/manage/features/maintenance/diagnostics.sh`: diagnostic menu tambahan maintenance
- `opt/manage/menus/main_menu.sh`: router menu utama
- `opt/manage/menus/maintenance_menu.sh`: router menu `11) Maintenance`
- `manage.sh`: helper runtime inti lintas-domain, trusted loader, konstanta, dan bootstrap

Gunakan peta ini saat audit atau patch agar perubahan masuk ke child module yang
tepat, bukan kembali menumpuk di aggregator atau `manage.sh`.

## Ringkasan Fitur Manage

- `1) Xray Users`
  CRUD user Xray, expiry, reset credential, listing, dan recovery journal.
- `2) SSH Users`
  CRUD user SSH, expiry, reset password, sesi aktif, SSH WS status/restart, dan recovery journal.
- `3) Xray QAC`
  Quota, block, IP limit, speed limit, dan detail metadata user Xray.
- `4) SSH QAC`
  Quota, block, login/IP limit, speed limit, sync/enforcement, dan detail metadata SSH.
- `5) Xray Network`
  WARP, DNS settings/add-ons, dan diagnostics runtime Xray.
- `6) SSH Network`
  DNS steering SSH dan kontrol WARP SSH global/per-user.
- `7) Adblocker`
  Shared source Adblock untuk Xray + SSH, termasuk URL source, auto update, dan rebuild artifact.
- `8) Domain Control`
  Set domain, current domain, guard check/renew, refresh account info, repair compat drift, dan repair target DNS.
- `9) Speedtest`
  Run speedtest dan version check.
- `10) Security`
  TLS/cert menu, fail2ban, dan tuning sistem.
- `11) Maintenance`
  Restart/status service, log, dan status daemon.
- `12) Traffic`
  Analytics dan ringkasan traffic runtime.
- `13) Tools`
  Telegram Bot, WARP Tier, Backup/Restore, dan `License Guard` status.
  `WARP Tier` sekarang dibagi ke status utama berbasis `mode`, submenu `Free/Plus`, dan submenu `Zero Trust`.
  `Zero Trust` memakai backend `cloudflare-warp` untuk proxy lokal Xray; `SSH Network` kompatibel bila backend WARP SSH memakai `Local Proxy`.
  Fondasi paket/runtime `cloudflare-warp` sekarang dipersiapkan dari `setup.sh`, tetapi mode ini tetap idle sampai diaktifkan operator.
  `manage` startup juga menjalankan guard lisensi IP bila `AUTOSCRIPT_LICENSE_API_URL` aktif; IP expired atau revoked dari portal Cloudflare akan ditolak sebelum panel dibuka.

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

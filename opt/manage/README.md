# Manage Modules

Direktori ini adalah source modular untuk runtime `manage`.

- Source di repo: `opt/manage/...`
- Target deploy di VPS: `/opt/manage/...`
- Binary entrypoint tetap: `manage.sh` -> `/usr/local/bin/manage`

## Status Arsitektur Saat Ini

Modularisasi CLI masih berjalan bertahap.

- Loader, menu utama, dan beberapa feature sudah hidup dari `opt/manage/...`
- Sejumlah action besar masih tetap diimplementasikan di `manage.sh`
- Karena itu, `opt/manage/...` belum sepenuhnya menjadi single source of truth

Ini disengaja sebagai fase transisi yang aman. Jangan asumsikan file placeholder di
`opt/manage/features/` sudah memegang logic runtime hanya karena namanya ada.

## Peta Source of Truth

- `opt/manage/features/network.sh`: menu `5) Xray Network`, `7) Adblocker`, `9) Speedtest`, dan flow `WARP Tier` yang kini muncul via `13) Tools`
- `opt/manage/features/analytics.sh`: menu `2) SSH Users`, `4) SSH QAC`, `6) SSH Network`, dan flow TLS/renew
- `manage.sh`: menu `1) Xray Users`, `3) Xray QAC`, `8) Domain Control`, dan banyak helper runtime inti
- `opt/manage/features/analytics.sh`: juga memegang `10) Security`, `12) Traffic`, serta layar `Telegram Bot`/`Discord Bot` yang kini diroute dari `13) Tools`
- `opt/manage/menus/maintenance_menu.sh`: router menu `11) Maintenance`, dengan helper runtime tersebar di `analytics.sh`, `network.sh`, dan `manage.sh`

Gunakan peta ini saat audit atau patch agar tidak salah mengubah file modular yang
ternyata belum memegang logic live.

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
  DNS steering SSH dan routing WARP SSH global/per-user.
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
  Telegram Bot, Discord Bot, dan WARP Tier.
  `WARP Tier` sekarang dibagi ke status utama berbasis `mode`, submenu `Consumer (Free/Plus)`, dan slot `Zero Trust` yang masih placeholder CLI.

## Guardrail Maintainer

- Jika sebuah menu/action masih dipanggil dari `manage.sh`, anggap `manage.sh`
  sebagai source of truth sampai logic-nya benar-benar dipindah.
- Jangan menghapus function lama di `manage.sh` hanya karena ada file modular dengan
  nama mirip.
- Lakukan pemindahan per action/menu kecil, bukan sekaligus.
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

## Placeholder Saat Ini

Beberapa file modular masih placeholder/guardrail:

- `features/users.sh`
- `features/domain.sh`
- `features/maintenance.sh`

Logic live untuk area itu masih berada di `manage.sh` sampai refactor lanjutan
selesai.

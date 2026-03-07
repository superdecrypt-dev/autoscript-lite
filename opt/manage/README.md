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

## Placeholder Saat Ini

Beberapa file modular masih placeholder/guardrail:

- `features/users.sh`
- `features/domain.sh`
- `features/maintenance.sh`

Logic live untuk area itu masih berada di `manage.sh` sampai refactor lanjutan
selesai.

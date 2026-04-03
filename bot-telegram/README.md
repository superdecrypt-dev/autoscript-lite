# Bot Telegram (Standalone)

Bot Telegram ini adalah pelengkap CLI `manage.sh`, berjalan standalone di `/opt/bot-telegram`.

## Tujuan
- Panel Telegram untuk action yang setara menu operasional `manage.sh`.
- Tidak menjalankan `manage.sh` secara langsung dari bot.
- Menggunakan backend API lokal (`backend-py`) + gateway Telegram (`gateway-py`).
- Fokus parity saat ini mencakup area `Accounts`, `QAC`, `Status`, `Domain`, `Network`, dan `Ops`.

## Struktur
- `backend-py/`: FastAPI service action menu operasional Telegram.
- `gateway-py/`: Bot Telegram berbasis `python-telegram-bot`.
- `shared/commands.json`: definisi menu/action.
- `systemd/`: template unit backend/gateway/monitor.
- `scripts/`: gate/smoke/monitor helper.

## Env penting
Dikelola di `/etc/bot-telegram/bot.env`:
- `INTERNAL_SHARED_SECRET`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_BOT_USERNAME` (opsional, advanced)
- `TELEGRAM_DEFAULT_CHAT_ID` (opsional, advanced)
- `TELEGRAM_ADMIN_CHAT_IDS` (opsional, CSV)
- `TELEGRAM_ADMIN_USER_IDS` (opsional, CSV)
- `TELEGRAM_ALLOW_UNRESTRICTED_ACCESS` (default `false`, tidak direkomendasikan)
- `TELEGRAM_ACTION_COOLDOWN_SECONDS` (default `1`)
- `TELEGRAM_CLEANUP_COOLDOWN_SECONDS` (default `30`)
- `TELEGRAM_MAX_INPUT_LENGTH` (default `2048`)
- `BACKEND_BASE_URL`
- `COMMANDS_FILE`

Catatan installer:
- Menu `Configure Bot (.env)` sekarang hanya meminta `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ADMIN_USER_IDS`, dan `TELEGRAM_ALLOW_UNRESTRICTED_ACCESS`.
- `TELEGRAM_BOT_USERNAME`, `TELEGRAM_DEFAULT_CHAT_ID`, dan `TELEGRAM_ADMIN_CHAT_IDS` tetap didukung di env/runtime, tetapi tidak lagi ditanyakan saat setup interaktif. Ubah manual di `bot.env` jika memang dibutuhkan.
- Portal info akun sekarang dipisah ke service mandiri `account-portal`, jadi backend bot tidak lagi melayani route `/account/*`.

## Ringkasan Menu
Menu bot Telegram sekarang mengikuti urutan `CLI Menu` di `manage.sh` untuk top-level utama:
- `1) Xray Users`
- `2) SSH Users`
- `3) Xray QAC`
- `4) SSH QAC`
- `5) Xray Network`
- `6) SSH Network`
- `7) Adblocker`
- `8) Domain Control`
- `9) Speedtest`
- `10) Security`
- `11) Maintenance`
- `12) Traffic`
- `13) WARP Tier`

Catatan parity:
- `13) Tools` sengaja tidak dibawa ke bot Telegram; untuk bot, slot itu dipakai `WARP Tier`.
- Domain `SSH Network` sudah muncul sebagai menu tersendiri agar susunan bot konsisten dengan CLI.
- `SSH Network` sekarang disederhanakan menjadi `DNS for SSH`, `WARP SSH Global`, dan `WARP SSH Per-User`.
- `WARP Tier` sekarang dibagi jadi root `Show Overall Status`, submenu `Free/Plus`, dan submenu `Zero Trust`.

Catatan perilaku:
- Callback stale untuk action sensitif tetap ditolak aman oleh gateway.
- `Xray Network`, `Adblocker`, dan `WARP Tier` dipisah supaya domain action-nya lebih jelas seperti di CLI.
- `Maintenance`, `Traffic`, dan `Speedtest` juga tampil sebagai domain utama tersendiri, bukan lagi digabung di `Ops`.
- `Domain Control` dan `Security` tetap mempertahankan action sensitif yang sama, tetapi mengikuti penamaan dan urutan CLI.
- `WARP SSH Per-User` tetap memakai state metadata SSH yang sama (`network.route_mode`) seperti di CLI.

## Backup/Restore
Fitur `Backup/Restore` dipakai untuk membuat arsip backup lokal, melihat daftar backup, restore backup lokal terbaru, dan restore dari upload `.tar.gz`. Pada struktur baru, fitur ini diakses lewat kategori `Ops`.

Scope file yang dibackup:
- `/usr/local/etc/xray/conf.d` (seluruh file konfigurasi Xray)
- `/etc/nginx/conf.d/xray.conf`
- `/opt/account`
- `/opt/quota`
- `/opt/speed`
- `/etc/xray-speed/config.json`
- `/var/lib/xray-speed/state.json`
- `/var/lib/xray-manage/network_state.json`
- `/etc/wireproxy/config.conf`
- `/etc/xray/domain`
- `/opt/cert/fullchain.pem`
- `/opt/cert/privkey.pem`

Catatan penting:
- Backup tidak menyertakan env bot (token Telegram, shared secret, ACL chat/user).
- Restore bekerja sebagai rollback ke kondisi backup (bukan merge data incremental).
- Akun yang dibuat setelah titik backup bisa hilang, dan akun lama yang terhapus setelah backup bisa muncul lagi.
- Restore menulis file dari arsip ke path yang diizinkan dan tidak melakukan purge massal direktori.
- Setiap restore membuat safety snapshot lebih dulu. Jika validasi/restart service gagal, sistem mencoba rollback otomatis.
- Action restore/create backup tetap termasuk aksi sensitif dan hanya bisa dipakai oleh admin yang lolos ACL.

## Operasional cepat
- Installer menu: `sudo /usr/local/bin/install-telegram-bot menu`
- Status: `sudo /usr/local/bin/install-telegram-bot status`
- Smoke: `sudo /opt/bot-telegram/scripts/smoke-test.sh`

## Hardening Tambahan
- Gateway menyensor token sensitif pada log startup/runtime agar URL Bot API tidak tercatat mentah di journal baru.
- `Wireproxy Status` dibuat lebih defensif terhadap `BindAddress` yang diberi komentar atau format tidak rapi, sehingga action observability tidak mudah berubah menjadi error backend.

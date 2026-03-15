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
- `TELEGRAM_ADMIN_CHAT_IDS` (opsional, CSV)
- `TELEGRAM_ADMIN_USER_IDS` (opsional, CSV)
- `TELEGRAM_ALLOW_UNRESTRICTED_ACCESS` (default `false`, tidak direkomendasikan)
- `TELEGRAM_ACTION_COOLDOWN_SECONDS` (default `1`)
- `TELEGRAM_CLEANUP_COOLDOWN_SECONDS` (default `30`)
- `TELEGRAM_MAX_INPUT_LENGTH` (default `128`)
- `BACKEND_BASE_URL`
- `COMMANDS_FILE`

## Ringkasan Menu
Menu bot Telegram tahap ini memakai kategori utama:
- `1) Status`
- `2) Accounts`
- `3) QAC`
- `4) Domain`
- `5) Network`
- `6) Ops`

Submenu internal yang dipakai di balik kategori:
- `Accounts` -> `Xray Users`, `SSH Users`
- `QAC` -> `Xray QAC`, `SSH QAC`
- `Domain` -> action langsung untuk `Domain Info`, `TLS`, `Set Domain`, `Refresh Accounts`, `Renew Cert`, plus submenu `Security Tools`
- `Ops` -> action langsung untuk status operasional, speedtest, traffic overview, restart inti, dan backup, plus submenu `Speedtest Tools`, `Traffic Tools`, `Service Tools`, dan `Backup Tools`

Catatan perilaku:
- Callback stale untuk action sensitif tetap ditolak aman oleh gateway.
- `Status` fokus ke ringkasan host, TLS, validasi Xray, dan status runtime inti.
- `Network` mencakup `WARP`, `DNS`, dan `Adblock` termasuk status, source list, update, enable/disable, serta auto update.
- `Domain` memusatkan action domain yang paling sering dipakai langsung di satu layar, sementara tool yang lebih teknis dipindah ke `Security Tools`.
- `Ops` memusatkan aksi operasional yang paling sering dipakai langsung di satu layar, sementara tool yang lebih detail dipisah ke submenu yang lebih spesifik.

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
- `Wireproxy Status` dibuat lebih defensif terhadap `BindAddress` yang diberi komentar atau format tidak rapi, sehingga action read-only tidak mudah berubah menjadi error backend.

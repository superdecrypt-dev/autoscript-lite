# Release Notes

## Rilis 2026-03-06 (SSH WebSocket Share Port 80/443)

### Ringkasan
Rilis ini menambahkan SSH WebSocket TLS/non-TLS dengan model port share `80/443` tanpa memutus jalur Xray existing.

### Perubahan Utama
1. Integrasi SSH WS di `setup.sh`
- Install dependency baru: `dropbear` dan `stunnel4`.
- Tambah service systemd:
  - `sshws-dropbear` (local-only `127.0.0.1:22022`)
  - `sshws-stunnel` (TLS bridge local `127.0.0.1:22443`)
  - `sshws-proxy` (custom Python websocket tunnel `127.0.0.1:10015`)
  - `sshws-qac-enforcer.timer` (enforcement SSH QAC tiap 1 menit)
- `sanity_check` sekarang memverifikasi ketiga service SSH WS, timer enforcer SSH QAC, dan listener port `80/443`.

2. Integrasi nginx share port
- Redirect global HTTP->HTTPS dihapus.
- Endpoint SSH WS memakai `location = /`:
  - `ws://<domain>:80/`
  - `wss://<domain>:443/`
- Path Xray existing (`/vless-ws`, `/vmess-ws`, `/trojan-ws`, `/shadowsocks-ws`, `-hup`, `-grpc`) tetap dipertahankan.

3. Operasional menu `manage`
- Maintenance menu menambah:
  - `SSH WS Status (dropbear/stunnel/proxy)`
  - `Restart SSH WS Stack`
- Main Menu menambah top-level `3) SSH Management` dengan fitur:
  - add/delete akun SSH Linux
  - extend/set expiry
  - reset password
  - list akun terkelola
  - shortcut status/restart stack SSH WS
- Main Menu sekarang juga menambah `5) SSH Quota & Access Control`:
  - opsi detail mirip quota Xray (view JSON, set quota, reset used, manual block, IP/login limit, speed policy)
  - enforcement lock akun Linux via `passwd -l/-u`
  - lock otomatis limit sesi/login via timer `sshws-qac-enforcer.timer`
- Nomor menu lama bergeser (Network jadi `6`, Maintenance `10`, installer bot menjadi `12` dan `13`).
- Runtime dropbear untuk SSH WS kini password-enabled (flag disable password dihapus).

### Hasil Validasi
- `bash -n setup.sh manage.sh run.sh install-discord-bot.sh install-telegram-bot.sh` -> PASS
- `python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py')` -> PASS
- `python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')` -> PASS

## Rilis 2026-03-02 (Bot Auth Hardening + Installer Validation Guard)

### Ringkasan
Rilis ini memfokuskan hardening akses admin bot Discord/Telegram dan memastikan flow installer fail-closed saat konfigurasi env belum valid.

### Perubahan Utama
1. Hardening authz gateway Discord
- Gateway sekarang fail-closed bila `DISCORD_ADMIN_ROLE_IDS` dan `DISCORD_ADMIN_USER_IDS` sama-sama kosong.
- Fallback otorisasi berbasis permission `Administrator` saat ACL kosong dihapus.
- Handler auth di interaction Discord diperkuat agar aman terhadap variasi bentuk `interaction.member` (termasuk member partial/API object), tanpa cast `as any`.

2. Hardening backend secret check
- Verifikasi shared secret backend memakai `hmac.compare_digest`.
- Endpoint health backend bot Discord/Telegram kini tetap berada di jalur ber-auth secret.

3. Guard installer Discord/Telegram (env validation)
- Default `ENABLE_DANGEROUS_ACTIONS` diset ke `false`.
- `configure-env` sekarang mengembalikan gagal jika env belum valid (tidak lagi menampilkan sukses palsu).
- `start/restart services` sekarang hard-block jika env belum valid.
- Installer Telegram kini fail-closed saat ACL admin kosong (kecuali `TELEGRAM_ALLOW_UNRESTRICTED_ACCESS=true`).

### Hasil Validasi
- `bash -n manage.sh setup.sh install-discord-bot.sh install-telegram-bot.sh` -> PASS
- `python3 -m py_compile` backend/gateway bot Discord/Telegram -> PASS
- `cd bot-discord/gateway-ts && npm run -s build` -> PASS
- `bot-discord/scripts/gate-all.sh local` -> PASS
- `bot-telegram/scripts/gate-all.sh` -> PASS

## Rilis 2026-03-02 (Hysteria2 UDP 443 Integration)

### Ringkasan
Rilis ini memindahkan Hysteria2 menjadi fitur terintegrasi di jalur CLI (`setup.sh` + `manage.sh`) tanpa installer terpisah.

### Perubahan Utama
1. Integrasi Hysteria2 ke `setup.sh`
- `setup.sh` kini otomatis:
  - install binary `hysteria`
  - menulis config `/etc/hysteria/config.yaml`
  - mengaktifkan `hysteria-server` dan `xray-hy2-sync`
- Default setup:
  - listen `UDP :443`
  - TLS cert dari `/opt/cert/fullchain.pem` + `/opt/cert/privkey.pem`
  - auth mode `command` (`/usr/local/bin/hy2-auth`)
  - traffic API secret + sinkronisasi quota/ip-limit/expired (`/usr/local/bin/hy2-sync-users`)

2. Integrasi Hysteria2 ke `manage.sh`
- `2) User Management > Add user` untuk `vless/vmess/trojan` otomatis membuat bonus akun Hysteria2.
- `XRAY ACCOUNT INFO` kini menampilkan:
  - `HY2 User`
  - `HY2 Pass`
  - `HY2 URI`
- Hapus/extend user dan perubahan quota/ip-limit ikut sinkron ke Hysteria2 (`hy2-sync-users once`).

3. Cleanup jalur installer terpisah
- Referensi installer standalone `install-hysteria2.sh` di menu bootstrap dihapus.
- Main menu `manage` kembali fokus ke 11 item operasional utama.

### Hasil Validasi
- `bash -n setup.sh manage.sh run.sh` -> PASS
- Hasil patch memastikan setup memanggil `install_hysteria2_integrated()` dan `sanity_check` memverifikasi `hysteria-server` + `xray-hy2-sync`.

## Rilis 2026-03-02 (SS Multi-User + Bot Coexist Stability)

### Ringkasan
Rilis ini menambahkan dukungan multi-user untuk Shadowsocks dan Shadowsocks 2022 di jalur CLI dan bot, sekaligus menstabilkan deploy bot Telegram/Discord agar bisa aktif bersamaan tanpa konflik port.

### Perubahan Utama
1. Dukungan Shadowsocks + Shadowsocks 2022 multi-user
- Protokol `shadowsocks` dan `shadowsocks2022` aktif di `setup.sh`, `manage.sh`, backend bot Discord/Telegram, serta command schema gateway.
- Method default:
  - `shadowsocks`: `aes-128-gcm`
  - `shadowsocks2022`: `2022-blake3-aes-128-gcm`
- Generator account info/link dan validasi protocol diperluas agar mencakup kedua protokol baru.

2. Pembersihan transport legacy non-default
- Jalur transport non-default (termasuk `xhttp` dan `wireguard`) dibersihkan dari stack default provisioning/runtime.
- Tujuan: menjaga kompatibilitas domain fronting dan mengurangi noise konfigurasi yang tidak dipakai default.

3. Stabilitas installer Telegram (hasil temuan E2E)
- Default checksum `bot_telegram.zip` diperbarui agar sesuai artefak terbaru.
- Default env Telegram backend dipindah ke `127.0.0.1:8081` agar tidak bentrok dengan Discord backend `127.0.0.1:8080`.
- Template systemd Telegram backend tidak lagi hardcode port, melainkan memakai `${BACKEND_HOST}` dan `${BACKEND_PORT}`.

### Commit
- `5d0a08c` — `feat: add ss multi-user support and stabilize bot e2e`

### Hasil Validasi
- E2E `run.sh` sampai setup domain: PASS.
- Deploy bot Discord:
  - `xray-discord-backend` -> `active`
  - `xray-discord-gateway` -> `active`
- Deploy bot Telegram:
  - `xray-telegram-backend` -> `active`
  - `xray-telegram-gateway` -> `active`
- Health backend:
  - `http://127.0.0.1:8080/health` -> `200` (Discord)
  - `http://127.0.0.1:8081/health` + `X-Internal-Shared-Secret` -> `200` (Telegram)

## Rilis 2026-02-25 (Telegram WARP Parity + Hardening)

### Ringkasan
Rilis ini menambahkan full parity WARP untuk bot Telegram agar setara kontrol network di CLI, sekaligus hardening akses, output, dan runtime gateway.

### Perubahan Utama
1. Full parity WARP di bot Telegram (menu 4)
- Action baru:
  - `warp_status`, `warp_restart`
  - `set_warp_global_mode`
  - `set_warp_user_mode`
  - `set_warp_inbound_mode`
  - `set_warp_domain_mode`
  - `warp_tier_status`
  - `warp_tier_switch_free`
  - `warp_tier_switch_plus`
  - `warp_tier_reconnect`
- Endpoint opsi dinamis ditambahkan untuk picker `inbound_tag` dan `domain/geosite` agar input minim typo.

2. Hardening backend + gateway Telegram
- Endpoint backend `/health` kini wajib header `X-Internal-Shared-Secret`.
- Verifikasi shared secret memakai pembandingan aman (`hmac.compare_digest`).
- Gateway menerapkan default-deny ACL:
  - wajib `TELEGRAM_ADMIN_CHAT_IDS` atau `TELEGRAM_ADMIN_USER_IDS`
  - override hanya via `TELEGRAM_ALLOW_UNRESTRICTED_ACCESS=true`.
- Ditambahkan action cooldown + cleanup cooldown untuk mencegah spam/double-trigger.
- Sanitasi output/konfirmasi action agar token/secret/license tersamarkan.
- Polling update dipersempit ke `message` dan `callback_query` untuk mengurangi attack surface.

3. Hardening installer dan skrip operasional Telegram
- `install-telegram-bot.sh` menambah env default:
  - `TELEGRAM_ALLOW_UNRESTRICTED_ACCESS=false`
  - `TELEGRAM_ACTION_COOLDOWN_SECONDS=1`
  - `TELEGRAM_CLEANUP_COOLDOWN_SECONDS=30`
  - `TELEGRAM_MAX_INPUT_LENGTH=128`
- `smoke-test.sh`, `monitor-lite.sh`, dan `gate-all.sh` disesuaikan ke health endpoint ber-auth secret.

### Commit
- `af6aabe` — `feat(telegram): full warp parity and hardening baseline`

### Hasil Validasi
- `python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')` -> PASS
- `bash -n install-telegram-bot.sh bot-telegram/scripts/smoke-test.sh bot-telegram/scripts/monitor-lite.sh bot-telegram/scripts/gate-all.sh` -> PASS
- `shellcheck install-telegram-bot.sh bot-telegram/scripts/smoke-test.sh bot-telegram/scripts/monitor-lite.sh bot-telegram/scripts/gate-all.sh` -> PASS
- `bash bot-telegram/scripts/gate-all.sh` -> PASS
- Runtime deploy:
  - `systemctl is-active xray-telegram-backend xray-telegram-gateway` -> `active active`
  - smoke Telegram -> PASS

## Rilis 2026-02-25 (Update Malam)

### Ringkasan
Update ini menutup dua pekerjaan besar: penyempurnaan UX bot Telegram untuk operasi harian, dan pembersihan transport legacy dari stack default karena tidak stabil untuk mode domain fronting.

### Perubahan Utama
1. Bot Telegram: UX flow dipoles untuk operasional nyata
- Perbaikan alur panel interaktif (button/select/manual fallback) agar input minim typo.
- `Add User` sekarang mendukung speed limit saat create akun:
  - `speed_limit_enabled`
  - `speed_down_mbit`
  - `speed_up_mbit`
- `Delete User` memakai picker protocol + daftar username, jadi admin tidak perlu mengetik username manual.
- `/cleanup` diperbarui agar mode default membersihkan chat dan menyisakan 1 pesan hasil cleanup.

2. Penghapusan Transport Legacy dari Stack Default
- `setup.sh`:
  - inbound legacy dihapus dari template Xray
  - route/mapping/location legacy di template Nginx dihapus
- `manage.sh`:
  - generator link account tidak lagi membuat link transport legacy
  - compat checker account info diperbarui (basis validasi ke baris `gRPC`)
- Bot backend (`bot-discord` + `bot-telegram`):
  - generator link account tidak lagi memasukkan transport legacy
  - output account info tidak lagi menampilkan baris transport legacy
- `opt/manage/features/network.sh`:
  - deteksi tag default Xray disesuaikan tanpa suffix transport legacy

3. Sinkronisasi Runtime Live
- Konfigurasi runtime ikut dibersihkan:
  - `/usr/local/etc/xray/conf.d/10-inbounds.json`
  - `/etc/nginx/conf.d/xray.conf`
- Validasi runtime setelah patch:
  - `xray run -test -confdir /usr/local/etc/xray/conf.d` -> `Configuration OK`
  - `nginx -t` -> syntax valid
  - `systemctl is-active xray nginx` -> `active`

### Commit
- `b86e6d8` — `feat(bot-telegram): polish panel flows and add user speed-limit fields`
- `8bcf1d4` — `fix(xray): cleanup legacy transport paths in setup/manage/bot links`

### Hasil Validasi
- Shell:
  - `bash -n setup.sh manage.sh run.sh install-discord-bot.sh` -> PASS
  - `shellcheck setup.sh manage.sh opt/manage/features/network.sh` -> PASS
- Python:
  - `python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py') $(find bot-telegram/backend-py/app -name '*.py')` -> PASS
- Runtime:
  - `xray run -test -confdir /usr/local/etc/xray/conf.d` -> PASS
  - `nginx -t` -> PASS

## Rilis 2026-02-25

### Ringkasan
Rilis ini memfinalkan integrasi fitur baru bot Discord untuk operasional staging, sekaligus menyiapkan dokumentasi handoff agar agent berikutnya dapat melanjutkan aktivitas tanpa kehilangan konteks.

### Perubahan Utama
1. Integrasi Fitur Bot (menu 1, 5, 12)
- Menu `1) Status & Diagnostics` ditambah action:
  - `observe_snapshot`
  - `observe_status`
  - `observe_alert_log`
- Menu `5) Domain Control` ditambah action:
  - `domain_guard_check`
  - `domain_guard_status`
  - `domain_guard_renew`
- Menu baru `12) Traffic Analytics`:
  - `overview`
  - `top_users`
  - `search_user`
  - `export_json` (attachment file JSON)

2. Standardisasi Label UX Bot
- Label tombol pada menu gateway diseragamkan dengan pola:
  - `View ...`
  - `Run ...`
  - `Set ...`
  - `Toggle ...`
- Sinkronisasi label juga diterapkan ke `shared/commands.json`.

3. Penguatan Gate Testing Bot
- `bot-discord/scripts/gate-all.sh` diperbarui agar:
  - mengenali kehadiran menu `12`
  - menambah smoke check `observe_status` dan `menu12.overview`
  - memperluas regression read-only smoke hingga menu `12`.

4. Dokumentasi Continuity Agent
- Dokumen handoff/arsitektur/testing/release diperbarui dengan status aktivitas terbaru, ringkasan jalur uji, dan panduan kelanjutan untuk agent baru.

### Commit
- Commit ter-push: `fec6834`
- Pesan: `feat(bot): add menu 12 analytics and observability/domain-guard controls`

### Hasil Validasi
- Validasi lokal:
  - `python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py')` -> PASS
  - `(cd bot-discord/gateway-ts && npm run build)` -> PASS
  - `bash -n bot-discord/scripts/gate-all.sh` -> PASS
- Validasi staging:
  - service `xray-discord-backend` dan `xray-discord-gateway` -> active
  - checklist action `/panel` untuk menu `1`, `5`, `12` -> PASS semua (18/18 action).

## Rilis 2026-02-24

### Ringkasan
Rilis ini memfokuskan finalisasi bot Discord untuk penggunaan produksi dan hardening operasional shell di staging: konsistensi mode select, output hasil yang lebih ringkas, sinkronisasi domain control, serta penguatan runtime quota watcher.

### Perubahan Utama
1. Konsistensi UX Select di Bot Discord
- Alur yang membutuhkan pemilihan protokol/user dipindahkan ke mode select agar minim typo.
- Alur ini mencakup `Add User`, `Extend/Set Expiry`, `Account Info`, dan aksi select-based di `Network Controls`.

2. Output User Management Lebih Ringkas
- `Add User` sukses kini menampilkan embed ringkasan + lampiran `username@protokol.txt`.
- `Account Info` menampilkan embed ringkasan + lampiran `username@protokol.txt`.
- `Account Info` ditingkatkan dengan fallback summary dari file account ketika file quota tidak tersedia.

3. Penyederhanaan Domain Control
- Nama aksi diperjelas menjadi:
  - `Set Domain Manual`
  - `Set Domain Auto (API Cloudflare)`
- Root domain Cloudflare dipilih via select (`vyxara1.web.id`, `vyxara2.web.id`, `vyxara1.qzz.io`, `vyxara2.qzz.io`).
- Perilaku boolean invalid di wizard Cloudflare tidak lagi silent: tetap fallback aman, tetapi sekarang memberi warning eksplisit.

4. Hardening Shell Runtime & Staging
- `run.sh` menambah kompatibilitas path canonical `/opt/autoscript` dengan alias legacy `/root/xray-core_discord`.
- `install-discord-bot.sh` merapikan source archive URL agar konsisten memakai `BOT_SOURCE_OWNER/BOT_SOURCE_REPO/BOT_SOURCE_REF`.
- Generator `xray-quota` di `setup.sh` sekarang mendukung fallback endpoint API (`127.0.0.1:10080` dan `127.0.0.1:10085`) untuk mengurangi warning transien `statsquery`.

### Hasil Validasi
- Validasi lokal:
  - `bash -n setup.sh manage.sh run.sh install-discord-bot.sh` -> PASS
  - `python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py')` -> PASS
  - `(cd bot-discord/gateway-ts && npm run build)` -> PASS
  - `bot-discord/scripts/gate-all.sh local` -> PASS
- Validasi staging (24 Februari 2026):
  - smoke + negative untuk `manage.sh`/`install-discord-bot.sh` -> PASS
  - `xray run -test -confdir /usr/local/etc/xray/conf.d` -> `Configuration OK`
  - setelah update `xray-quota`, audit `journalctl -u xray-quota -p warning` pada window uji tidak menemukan warning baru.

## Update Handoff 2026-02-23

### Ringkasan
Update ini mencatat perubahan identitas proyek ke `autoscript`, pembaruan source path installer, dan perapihan UX bot Discord agar lebih profesional dan minim spam output.

### Perubahan Utama
1. Rebranding Proyek ke Autoscript
- Remote/identitas repo dipindah ke `superdecrypt-dev/autoscript`.
- Referensi URL source pada `run.sh`, `install-discord-bot.sh`, dan `README.md` disesuaikan.

2. Perubahan Source Working Directory Installer
- `run.sh` kini memakai source kerja persist di `/opt/autoscript`.
- Pola clone/update source diperbarui untuk mode deploy server yang lebih konsisten.

3. Perapihan UX Bot Discord
- Gateway interaction memakai `flags: MessageFlags.Ephemeral` (mengganti opsi lama yang deprecated).
- Output result dipotong agar tidak spam panjang di Discord mobile.
- Copywriting menu/error dipoles agar lebih profesional dan ringkas.

4. Dokumentasi SOP Testing
- Ditambahkan `TESTING_PLAYBOOK.md` sebagai panduan tunggal pengujian:
  preflight, smoke, negative/failure, integration, dan gate bot Discord.
- Dokumen ini dijadikan referensi utama untuk proses handoff agent baru.

### Validasi Tambahan
- `bash -n run.sh install-discord-bot.sh`: PASS.
- Build gateway TypeScript: PASS.
- Gate staging yang terakhir dijalankan:
  - Gate 4 (Negative/Failure): PASS
  - Gate 5 (Discord command check): PASS
  - Gate 6 (Regression read-only menu smoke): PASS

### Catatan Operasional
- Baseline handoff saat ini mengacu pada repo `autoscript`.
- Deploy bot tetap di `/opt/bot-discord`; env di `/etc/xray-discord-bot/bot.env`.

## Rilis 2026-02-23

### Ringkasan
Rilis ini memfinalkan paket stabilisasi bot Discord standalone dan alur operasional installer. Fokus utama: penguatan keamanan token, rollback safety, otomasi pengujian gate, dan monitoring runtime ringan.

### Perubahan Utama
1. Rotasi Token Discord (Security)
- Token bot produksi telah diganti (regenerate) dan diverifikasi aktif.
- Ditambahkan script rotasi aman: `bot-discord/scripts/rotate-discord-token.sh`.
- Token tetap disimpan di env file deploy: `/etc/xray-discord-bot/bot.env`.

2. Snapshot Rollback
- Snapshot pra-perubahan dibuat untuk rollback cepat:
  `xray-itg-1771777921/pre-gate123-20260224-011832`.

3. Otomasi Pengujian Gate
- Ditambahkan script orkestrasi test gate:
  `bot-discord/scripts/gate-all.sh`.
- Profil yang tersedia:
  - `local` -> Gate 1,2,3
  - `prod` -> Gate 3.1,5,6
  - `all` -> Gate 1-6 (Gate 4 via `STAGING_INSTANCE`)

4. Monitoring Ringan
- Ditambahkan health monitor:
  `bot-discord/scripts/monitor-lite.sh`.
- Ditambahkan unit systemd:
  - `xray-discord-monitor.service`
  - `xray-discord-monitor.timer` (interval 5 menit)
- Log monitor:
  `/var/log/xray-discord-bot/monitor-lite.log`.

### Hasil Validasi
- `bash -n` dan `shellcheck` untuk script terkait: lulus.
- Gate produksi (`gate-all.sh prod`) pada 2026-02-23:
  - Gate 3.1: PASS
  - Gate 5: PASS
  - Gate 6: PASS
- Status runtime produksi:
  - `xray-discord-backend`: active
  - `xray-discord-gateway`: active
  - `xray-discord-monitor.timer`: active

### Risiko Diketahui (Accepted Risk)
- Hardcoded Cloudflare token di lokasi legacy diperlakukan sebagai by design/accepted risk sesuai kebijakan proyek saat ini.
- Logika penghapusan A record lain pada IP yang sama tetap dipertahankan sesuai desain operasional.

### Catatan Operasional
- Lokasi deploy bot: `/opt/bot-discord`.
- Installer: `/usr/local/bin/install-discord-bot`.
- Untuk rollback darurat, gunakan snapshot LXC yang disebutkan pada bagian Snapshot Rollback.

# Release Notes

## Rilis 2026-03-09 (SSH Edge QAC Kini Termasuk Speed Lintas Transport)

### Ringkasan
Rilis ini menyatukan perilaku QAC SSH di jalur yang berada di belakang `Edge Gateway (go)`. Setelah patch ini, `quota`, `IP/Login limit`, dan `speed limit` tidak lagi eksklusif ke `SSH WS`, tetapi juga bekerja pada `SSH Direct` dan `SSH SSL/TLS`.

### Perubahan Utama
1. Quota SSH lintas transport edge
- `quota_used` sekarang bertambah untuk:
  - `SSH WS`
  - `SSH Direct`
  - `SSH SSL/TLS`
- Jika limit terlampaui, login berikutnya ditolak oleh enforcer SSH.

2. Speed limit SSH lintas transport edge
- `speed_down_mbit` dan `speed_up_mbit` sekarang diterapkan juga ke:
  - `SSH Direct`
  - `SSH SSL/TLS`
- Aktivasi berlaku saat provider utama yang aktif adalah `Edge Gateway (go)`.
- Perilaku realistisnya:
  - koneksi boleh auth dulu
  - bulk traffic sesudah auth ditahan sesuai policy user

3. IP/Login limit tetap lintas semua transport SSH edge
- `IP/Login limit` tetap berlaku pada:
  - `SSH WS`
  - `SSH Direct`
  - `SSH SSL/TLS`

### Hasil Validasi
- Uji live quota lintas transport SSH:
  - `SSH Direct` -> `quota_used` bertambah
  - `SSH SSL/TLS` -> `quota_used` bertambah
  - setelah limit terlampaui, login berikutnya ditolak
- Uji live speed limit `1 Mbps`:
  - `DIRECT_UPLOAD=8.068s`
  - `DIRECT_DOWNLOAD=8.014s`
  - `SSLTLS_UPLOAD=8.212s`
  - `SSLTLS_DOWNLOAD=8.029s`

### Catatan
- `sshd:22` native tetap bukan target traffic enforcement ini.
- Jika failover ke provider selain `go`, perilaku `speed limit` perlu dianggap provider-dependent.

## Rilis 2026-03-09 (SSH Direct di 80/443 via Edge Gateway)

### Ringkasan
Rilis ini menambahkan surface resmi `SSH Direct` di port `80` dan `443` lewat provider utama `Edge Gateway (go)`, tetap berdampingan dengan `SSH WS` dan `SSH SSL/TLS`.

### Perubahan Utama
1. Edge Gateway kini mengenali trafik SSH plaintext
- `edge-mux` sekarang bisa membedakan:
  - HTTP / WebSocket
  - TLS client hello
  - SSH plaintext (`SSH-`)
- Hasilnya:
  - `SSH Direct` bisa dipakai di `80`
  - `SSH Direct` juga bisa dipakai di `443`

2. Error handling edge dibuat lebih jelas
- Request HTTP yang terfragmentasi tidak lagi salah jatuh ke backend SSH.
- Jalur HTTP backend down sekarang membalas status yang jelas:
  - `408 Request Timeout`
  - `502 Bad Gateway`

3. Surface akun SSH diperluas
- `SSH ACCOUNT INFO` sekarang menampilkan:
  - `SSH WS`
  - `SSH WS Alt`
  - `SSH WS Port`
  - `SSH SSL/TLS`
  - `SSH Direct`

### Hasil Validasi
- Login nyata `SSH Direct` ke `127.0.0.1:80` -> `PASS`
- Login nyata `SSH Direct` ke `127.0.0.1:443` -> `PASS`
- `SSH SSL/TLS` tetap hidup di `443`
- `SSH WS` invalid token tetap `403`

## Rilis 2026-03-09 (Xray Shadowsocks Shorthand Path Only)

### Ringkasan
Rilis ini merapikan surface path publik Xray untuk `shadowsocks` dan `shadowsocks2022` agar mengikuti penamaan singkat yang searah dengan konsep `SSH WS`.

### Perubahan Utama
1. Path lama `shadowsocks*` dihapus
- Path publik lama berikut tidak lagi dipakai:
  - `/shadowsocks-ws`
  - `/shadowsocks-hup`
  - `/shadowsocks-grpc`
  - `/shadowsocks2022-ws`
  - `/shadowsocks2022-hup`
  - `/shadowsocks2022-grpc`

2. Path baru `ss*` dan `ss2022*` menjadi baseline
- Path resmi sekarang:
  - `/ss-ws`
  - `/ss-hup`
  - `/ss-grpc`
  - `/ss2022-ws`
  - `/ss2022-hup`
  - `/ss2022-grpc`
- Prefix opsional satu segmen juga didukung:
  - `/<bebas>/ss-ws`
  - `/<bebas>/ss-hup`
  - `/<bebas>/ss-grpc`
  - `/<bebas>/ss2022-ws`
  - `/<bebas>/ss2022-hup`
  - `/<bebas>/ss2022-grpc`

3. Loader render `nginx` ikut dibuat tahan transisi
- Pembaca context route live di `nginx.sh` sekarang bisa mengenali bentuk route lama maupun baru saat rerender.
- Ini mencegah render `nginx` gagal saat host sedang berada di tengah transisi path lama -> path baru.

### Hasil Validasi
- Path lama `shadowsocks*` -> `404`
- Path baru `ss*` / `ss2022*` -> tetap match handler yang benar
- Reload `nginx` live -> PASS

## Rilis 2026-03-08 (Provider `nginx-stream` Experimental Implemented)

### Ringkasan
Rilis ini menyelesaikan implementasi provider `nginx-stream` sebagai opsi experimental untuk edge, lalu memvalidasinya pada:

- high-port test
- cutover live
- restore kembali ke provider `go`

### Perubahan Utama
1. Provider `nginx-stream`
- `nginx` sekarang bisa menjalankan mode stream edge:
  - publik `:80/:443`
  - backend HTTP internal `127.0.0.1:18080`
  - backend HTTPS internal `127.0.0.1:18443`
  - backend SSH TLS internal `127.0.0.1:22443`
- helper operasional baru:
  - `edge-provider-switch nginx-stream`

2. Template dan render runtime
- `nginx.conf` sekarang mendukung include `stream-conf.d/*.conf`
- `stream-edge.conf` kini benar-benar dipakai untuk memisahkan:
  - HTTP/plaintext vs TLS pada `:80`
  - ALPN HTTP vs non-HTTP pada `:443`

3. Validasi perilaku runtime
- HTTP -> backend HTTP `nginx`
- `SSH WS` invalid token -> `403 Forbidden`
- `SSH SSL/TLS` -> banner `dropbear`
- restore kembali ke `go` dan topologi standby `haproxy` tetap sehat

### Hasil Validasi
- high-port validation `nginx-stream` -> PASS
- cutover live `nginx-stream` -> PASS
- restore live ke `go` -> PASS

## Rilis 2026-03-08 (Edge Gateway Primary + HAProxy Standby Fallback)

### Ringkasan
Rilis ini mematangkan topologi edge menjadi:

- `Edge Gateway (go)` sebagai frontend publik utama
- `HAProxy` sebagai standby fallback
- `nginx` sebagai backend internal HTTP

### Perubahan Utama
1. Topologi primary + standby
- `edge-mux` tetap memegang publik `:80/:443`
- `haproxy` kini dapat tetap hidup sebagai standby di:
  - `:18082`
  - `:18444`
- `nginx` tetap hidup di backend internal `127.0.0.1:18080`

2. Failover helper operasional
- helper baru:
  - `edge-provider-switch haproxy`
  - `edge-provider-switch go`
- helper ini digunakan untuk:
  - promote `HAProxy` ke `80/443`
  - restore kembali ke `Edge Gateway`

3. Maintenance menu
- maintenance sekarang punya aksi eksplisit untuk:
  - failover ke `HAProxy`
  - restore ke `Edge Gateway (go)`

### Hasil Validasi
- failover live ke `HAProxy` -> PASS
- restore live ke `Edge Gateway` -> PASS
- `HTTP` publik tetap hidup pada dua mode -> PASS
- `SSH SSL/TLS` dan `SSH WS` tetap tidak regress -> PASS

### Commit
- `9d55920` — `feat(edge): add haproxy standby failover flow`

## Rilis 2026-03-08 (Edge Gateway Live + SSH Surface Refresh)

### Ringkasan
Rilis ini mengaktifkan `Edge Gateway` sebagai frontend publik `80/443`, memindahkan `nginx` ke backend internal, lalu merapikan surface user-facing untuk `SSH WS` dan `SSH SSL/TLS`.

### Perubahan Utama
1. Edge Gateway live cutover
- Provider aktif saat ini: `go`
- `edge-mux` kini memegang publik `:80` dan `:443`
- `nginx` dipindah ke backend internal `127.0.0.1:18080`
- `SSH WS` dan `SSH SSL/TLS` sekarang berbagi domain dan port publik yang sama lewat Edge Gateway

2. Surface operasional baru
- Maintenance menu sekarang punya:
  - `Edge Gateway Status`
  - `Restart Edge Gateway`
  - `Edge Gateway Info`
- Rollback operasional singkat didokumentasikan di `EDGE_ROLLBACK.md`

3. Refresh output akun SSH
- `SSH ACCOUNT INFO` sekarang menampilkan:
  - `ISP`
  - `Country`
  - `SSH WS`
  - `SSH WS Alt`
  - `SSH WS Port`
  - `SSH SSL/TLS`
- Penamaan user-facing disederhanakan menjadi:
  - `SSH WS`
  - `SSH SSL/TLS`

### Commit
- `5356202` — `docs: add edge provider architecture design`
- `fed9458` — `chore(edge): add provider scaffold`
- `a1fbdb6` — `feat(edge): add go provider build and staging flow`
- `8617fe7` — `feat(edge): add guarded runtime activation flow`
- `e96dc37` — `feat(edge): cut over public ports to provider`
- `3c0662d` — `feat(edge): add cli maintenance tools and rollback note`
- `8e1c990` — `chore(edge): rename user-facing labels to Edge Gateway`
- `562832c` — `feat(ssh): update ssh ws account info and docs`

### Hasil Validasi
- Edge Gateway high-port systemd validation -> PASS
- HTTP/HTTPS publik diteruskan ke backend HTTP internal -> PASS
- `SSH WS` valid token -> `101 Switching Protocols`
- `SSH SSL/TLS` di `80` dan `443` -> banner `SSH-2.0-dropbear_2022.83`

## Rilis 2026-03-08 (Modular Installer + Playbook & Preflight Hardening)

### Ringkasan
Rilis ini memecah `setup.sh` menjadi installer modular yang lebih mudah diaudit, lalu merapikan guard operasional di `run.sh`, `TESTING_PLAYBOOK.md`, dan `AUDIT_PLAYBOOK.md` agar sesuai dengan arsitektur repo terbaru.

### Perubahan Utama
1. Modularisasi installer `setup.sh`
- `setup.sh` sekarang menjadi orchestrator tipis.
- Implementasi installer dipindah ke:
  - `opt/setup/core`
  - `opt/setup/install`
  - `opt/setup/bin`
  - `opt/setup/templates`
- Asset runtime besar yang sebelumnya inline kini dipisah, termasuk:
  - `sshws-proxy.py`
  - `sshws-qac-enforcer.py`
  - `xray-speed.py`
  - `xray-observe`
  - `xray-domain-guard`
  - template `nginx`, `systemd`, dan config pendukung

2. Hardening `run.sh`
- Preflight source lokal/repo sekarang lebih ketat sebelum host disentuh.
- Jalur `RUN_USE_LOCAL_SOURCE=1` kini memverifikasi layout repo modular, bukan hanya `setup.sh` dan `manage.sh`.
- Sinkronisasi `/opt/manage` dibuat staged/atomic untuk mengurangi skew antara binary `manage` dan modulnya saat install/upgrade gagal di tengah.

3. Sinkronisasi playbook operasional
- `TESTING_PLAYBOOK.md` kini sinkron dengan:
  - SSH WS token path `/<token>` dan `/<bebas>/<token>`
  - smoke Telegram runtime
  - ACL whitelist/non-whitelist
  - hidden dangerous actions
  - log hygiene gateway Telegram
- `AUDIT_PLAYBOOK.md` kini sinkron dengan:
  - repo modular `opt/setup/*` dan `opt/manage/*`
  - quick audit bot
  - format audit dengan `Residual Risks / Testing Gaps`

### Commit
- `b8e82a6` — `refactor(setup): modularize installer and tune sshws restart`
- `921a03e` — `chore: drop generated python cache files`
- `f4fa613` — `fix(run): harden local source preflight and add audit playbook`
- `812cf06` — `docs: refine audit and testing playbooks`

### Hasil Validasi
- `bash -n setup.sh opt/setup/core/*.sh opt/setup/install/*.sh` -> PASS
- `shellcheck -x -S warning setup.sh opt/setup/core/*.sh opt/setup/install/*.sh opt/setup/bin/xray-observe opt/setup/bin/xray-domain-guard` -> PASS
- `python3 -m py_compile opt/setup/bin/sshws-proxy.py opt/setup/bin/sshws-qac-enforcer.py opt/setup/bin/xray-speed.py` -> PASS
- Full E2E modular installer `run.sh -> setup.sh -> manage.sh` live -> PASS

## Rilis 2026-03-07 (SSH WS Token Path + QAC Hardening + Telegram Parity)

### Ringkasan
Rilis ini mengubah baseline SSH WS menjadi token path per-user yang fail-close, memperketat QAC SSH WS di runtime nyata, dan mendekatkan parity bot Telegram ke CLI sambil menutup beberapa gap operasional.

### Perubahan Utama
1. SSH WS token path per-user
- Jalur resmi SSH WS sekarang:
  - `/<token>`
  - `/<bebas>/<token>`
- Token dibuat per-user dan dipakai untuk mengidentifikasi user sejak awal koneksi.
- Respons fail-close kini menjadi baseline:
  - tanpa token -> `401 Unauthorized`
  - token tidak valid -> `403 Forbidden`
  - backend internal down -> `502 Bad Gateway`
  - token valid + backend siap -> `101 Switching Protocols`

2. QAC SSH WS runtime lebih ketat
- `quota` dan `speed limit` menempel ke user dari awal lewat token path.
- `IP/Login limit` dipindahkan lebih dekat ke admission runtime, bukan hanya menunggu timer.
- Runtime session SSH WS kini melacak:
  - `client_ip`
  - `updated_at`
  - heartbeat sesi
- Session stale dibersihkan agar `Active SSH WS Sessions` dan QAC tidak menghitung ghost session.
- `manage.sh` dan `analytics.sh` ikut disinkronkan untuk refresh account info, alt path, dan viewer sesi aktif.

3. Bot Telegram parity + hardening
- Menu Telegram makin dekat ke CLI untuk area:
  - `Xray Management`
  - `SSH Management`
  - `Xray Quota & Access Control`
  - `SSH Quota & Access Control`
  - `Security`
  - `Maintenance`
- Action dangerous sekarang otomatis disembunyikan saat `ENABLE_DANGEROUS_ACTIONS=false`.
- Logging gateway Telegram di-hardening agar URL Bot API yang memuat token tidak lagi masuk ke journal baru.
- Archive `bot_telegram.zip` dan checksum installer disegarkan agar deploy konsisten.

### Commit
- `18df265` — `fix(sshws): track client ip for qac enforcement`
- `771a5d5` — `fix(sshws): apply speed limits per direction`
- `c4f829e` — `fix(sshws): warm up user attribution for speed limits`
- `56a41b6` — `feat(sshws): require per-user token paths`
- `7595127` — `fix(manage): sync ssh account info refresh flows`
- `3a800bc` — `feat(sshws): support short token prefixes`
- `9542703` — `fix(sshws): harden admission and session tracking`
- `40c2825` — `feat(telegram): sync ssh menu parity and refresh archive`
- `e116d2d` — `feat(telegram): expand bot parity and refresh archive`
- `b7a6522` — `fix(telegram): hide disabled dangerous actions`
- `350fe32` — `docs: sync sshws runtime notes`

### Hasil Validasi
- `bash -n setup.sh manage.sh opt/manage/features/analytics.sh` -> PASS
- `python3 -m py_compile opt/setup/bin/sshws-proxy.py opt/setup/bin/sshws-qac-enforcer.py` -> PASS
- Runtime SSH WS:
  - path tanpa token -> `401`
  - token invalid -> `403`
  - backend down -> `502`
  - token valid -> `101`
- Bot Telegram:
  - backend/gateway active
  - archive terbaru terdeploy
  - smoke runtime PASS

## Rilis 2026-03-06 (SSH WS Autoscript-Stream Mode + Runtime Guard)

### Ringkasan
Update ini menyelaraskan perilaku SSH WS ke mode autoscript-stream, lalu menambah guard runtime agar tidak menghasilkan false-positive koneksi saat backend internal tidak siap.

### Perubahan Utama
1. SSH WS full autoscript-stream mode (tanpa `Sec-WebSocket-*` wajib)
- Proxy SSH WS kini menerima payload autoscript-stream minimal (`Upgrade: websocket`) tanpa framing WebSocket RFC6455.
- Respons handshake memakai pola autoscript-stream:
  - `HTTP/1.1 101 Switching Protocols`
  - `Content-Length: 104857600000`
- Normalisasi target request diperluas agar kompatibel untuk:
  - `/`
  - `/?ed=...`
  - `wss://host/path?...`

2. Runtime guard SSH WS (hindari false-positive 101)
- Proxy sekarang membuka koneksi backend (`sshws-stunnel`) terlebih dahulu.
- Jika backend gagal diakses, proxy mengembalikan `502 Bad Gateway` (bukan `101`).
- Tujuan: memperjelas troubleshooting saat backend internal down/restart.

3. Hardening loader modul `manage.sh`
- Pemilihan source modul kini berbasis `ready` check:
  - direktori trusted
  - seluruh modul wajib tersedia
  - file modul trusted
- Prioritas source:
  - `/opt/manage`
  - `/opt/autoscript/opt/manage`
  - local repo `opt/manage`
- `MANAGE_MODULES_DIR` override sekarang juga wajib lolos validasi ready.

4. UX SSH Management
- Flow `Add SSH User` kini meminta `Masa aktif SSH (hari)` secara eksplisit.
- Input `0` pada prompt masa aktif kini konsisten berfungsi sebagai `back`.

### Commit
- `87b43fb` — `fix(ssh): enforce SSH active-days and switch sshws mode`
- `edd9852` — `fix(runtime): harden sshws handshake and manage module loading`

### Hasil Validasi
- `bash -n setup.sh manage.sh opt/manage/features/analytics.sh` -> PASS
- `python3 -m py_compile` untuk script `sshws-proxy` hasil heredoc -> PASS
- Runtime check SSH WS:
  - backend down -> `HTTP/1.1 502 Bad Gateway`
  - backend up -> `HTTP/1.1 101 Switching Protocols`
- Smoke `manage.sh` (`0` keluar menu) -> PASS

## Rilis 2026-03-06 (SSH WS Share Port 80/443)

### Ringkasan
Rilis ini menambahkan SSH WS TLS/non-TLS dengan model port share `80/443` tanpa memutus jalur Xray existing.

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
- Path Xray existing (`/vless-ws`, `/vmess-ws`, `/trojan-ws`, `-hup`, `-grpc`) tetap dipertahankan.
- Catatan: baseline `shadowsocks*` kemudian berubah pada rilis `2026-03-09`, yang mengganti surface publik ke path singkat `ss*` dan `ss2022*`.

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
- Nomor menu sebelumnya bergeser (Network jadi `6`, Maintenance `10`, installer bot menjadi `12` dan `13`).
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

2. Pembersihan transport terdepresiasi non-default
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
Update ini menutup dua pekerjaan besar: penyempurnaan UX bot Telegram untuk operasi harian, dan pembersihan transport terdepresiasi dari stack default karena tidak stabil untuk mode domain fronting.

### Perubahan Utama
1. Bot Telegram: UX flow dipoles untuk operasional nyata
- Perbaikan alur panel interaktif (button/select/manual fallback) agar input minim typo.
- `Add User` sekarang mendukung speed limit saat create akun:
  - `speed_limit_enabled`
  - `speed_down_mbit`
  - `speed_up_mbit`
- `Delete User` memakai picker protocol + daftar username, jadi admin tidak perlu mengetik username manual.
- `/cleanup` diperbarui agar mode default membersihkan chat dan menyisakan 1 pesan hasil cleanup.

2. Penghapusan Transport Terdepresiasi dari Stack Default
- `setup.sh`:
  - inbound terdepresiasi dihapus dari template Xray
  - route/mapping/location terdepresiasi di template Nginx dihapus
- `manage.sh`:
  - generator link account tidak lagi membuat link transport terdepresiasi
  - compat checker account info diperbarui (basis validasi ke baris `gRPC`)
- Bot backend (`bot-discord` + `bot-telegram`):
  - generator link account tidak lagi memasukkan transport terdepresiasi
  - output account info tidak lagi menampilkan baris transport terdepresiasi
- `opt/manage/features/network.sh`:
  - deteksi tag default Xray disesuaikan tanpa suffix transport terdepresiasi

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
- `8bcf1d4` — `fix(xray): cleanup old transport paths in setup/manage/bot links`

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
- `run.sh` menambah kompatibilitas path canonical `/opt/autoscript` dengan alias kompatibilitas historis `/root/xray-core_discord`.
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
- Gateway interaction memakai `flags: MessageFlags.Ephemeral` (mengganti opsi sebelumnya yang deprecated).
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
- Hardcoded Cloudflare token di lokasi historis diperlakukan sebagai by design/accepted risk sesuai kebijakan proyek saat ini.
- Logika penghapusan A record lain pada IP yang sama tetap dipertahankan sesuai desain operasional.

### Catatan Operasional
- Lokasi deploy bot: `/opt/bot-discord`.
- Installer: `/usr/local/bin/install-discord-bot`.
- Untuk rollback darurat, gunakan snapshot LXC yang disebutkan pada bagian Snapshot Rollback.

# Release Notes

## Rilis 2026-03-19 (Manage Menu Rebalance + Tools/WARP Tier Surface)

### Ringkasan
Rilis ini merapikan surface user-facing `manage.sh` agar menu utama lebih seimbang dan alur fitur pendukung lebih mudah dicari. `WARP Tier` dipindah ke `Tools`, `SSH Network` dan `Adblocker` naik ke area utama, lalu `Traffic` dipisah sebagai menu analytics mandiri.

### Perubahan Utama
1. Main menu diseimbangkan ulang
- susunan utama kini menjadi:
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
  - `13) Tools`

2. Tools menu baru untuk utilitas non-core
- `13) Tools` sekarang memuat:
  - `Telegram Bot`
  - `WARP Tier`
- `WARP Tier` kini menampilkan status utama berbasis mode, submenu `Consumer (Free/Plus)`, dan submenu `Zero Trust`.
- `Zero Trust` sudah punya backend engine di `manage`; yang dirapikan pada working tree ini adalah fondasi installer/runtime `cloudflare-warp` dan health path-nya.

3. Surface operasional dipertegas
- `6) SSH Network` sekarang muncul sebagai menu utama sendiri.
- `12) Traffic` kini menjadi layar analytics/export terpisah.
- `11) Maintenance` fokus ke status, restart, dan log service; `Normalize Quota Dates` tidak lagi muncul di surface user-facing terbaru.

### Hasil Validasi
- `bash -n manage.sh opt/manage/app/main.sh opt/manage/features/network.sh opt/manage/features/analytics.sh opt/manage/menus/main_menu.sh opt/manage/menus/maintenance_menu.sh` -> PASS
- smoke `printf '0\n' | bash manage.sh` -> PASS
- smoke `printf '13\n2\n0\n0\n' | bash manage.sh` -> PASS
- smoke `printf '11\n0\n12\n0\n6\n0\n7\n0\n9\n0\n10\n0\n0\n' | bash manage.sh` -> PASS
- judul live `WARP Tier` saat diakses dari menu baru -> `13) Tools > WARP Tier`
- runtime header saat validasi:
  - domain aktif: `d77bq.vyxara2.web.id`
  - `WARP Status` -> `Active (FREE)`
  - service ringkas -> `Edge Mux ✅`, `Nginx ✅`, `Xray ✅`, `SSH ✅`

## Rilis 2026-03-16 (Bot UX Refresh + Live E2E Revalidation)

### Ringkasan
Rilis ini merapikan peran bot Telegram agar lebih masuk akal untuk operasional harian: Telegram menjadi menu-first, lalu `run.sh` divalidasi ulang penuh di host live memakai source lokal repo.

### Perubahan Utama
1. Telegram kini menu-first
- entry point utama sekarang `/menu`
- `/panel` sudah dihapus total
- kategori utama Telegram kini:
  - `Status`
  - `Accounts`
  - `QAC`
  - `Domain`
  - `Network`
  - `Ops`
- flow `Accounts` kini picker-first
- flow `QAC` kini user-first dengan summary per-user
- `Domain` dan `Ops` diringkas agar lebih enak dipakai dari HP

2. Naming dan hardening bot
- naming legacy `xray-telegram-*` sudah dibersihkan ke:
  - `bot-telegram-*`
- flag dangerous actions sudah dihapus dari desain Telegram

### Commit
- `3c85652` — `refactor(bot-telegram): streamline menu-first flows`

### Hasil Validasi
- Full E2E live `run.sh` pada `2026-03-16` -> PASS
- domain aktif hasil rerun: `k8i2j.vyxara1.web.id`
- `xray run -test -confdir /usr/local/etc/xray/conf.d` -> `Configuration OK`
- `nginx -t` -> PASS
- sertifikat live yang disajikan untuk `k8i2j.vyxara1.web.id` valid sampai `Jun 13 2026`
- smoke SSH WS:
  - tokenless websocket -> `401 Unauthorized`
  - token invalid -> `403 Forbidden`
  - token valid -> `101 Switching Protocols`

## Rilis 2026-03-09 (BadVPN UDPGW Sebagai Fitur Tambahan SSH)

### Ringkasan
Rilis ini menambahkan `badvpn-udpgw` sebagai fitur tambahan untuk ekosistem SSH. Distribusi memakai binary prebuilt lintas arsitektur, dipasang lewat `setup.sh`, dan diekspos ke operator lewat menu maintenance serta `SSH ACCOUNT INFO`.

### Perubahan Utama
1. Distribusi prebuilt `badvpn-udpgw`
- Binary resmi proyek sekarang tersedia di repo:
  - `opt/badvpn/dist/badvpn-udpgw-linux-amd64`
  - `opt/badvpn/dist/badvpn-udpgw-linux-arm64`
- Installer memilih binary sesuai arsitektur lalu memasangnya langsung dari bundle repo.

2. Integrasi setup modular
- `setup.sh` sekarang memasang:
  - `/usr/local/bin/badvpn-udpgw`
  - `/etc/default/badvpn-udpgw`
  - `badvpn-udpgw.service`
- Runtime default:
  - listen lokal di `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900`

3. Surface operasional
- `Maintenance` sekarang punya:
  - `BadVPN UDPGW Status`
  - `Restart BadVPN UDPGW`
- `SSH ACCOUNT INFO` sekarang menampilkan:
  - `BadVPN UDPGW : 7300, 7400, 7500, 7600, 7700, 7800, 7900`

### Hasil Validasi
- `badvpn-udpgw.service` -> `active`
- listener lokal `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900` -> `LISTENING`
- menu maintenance live berhasil membaca status service dan port runtime

## Rilis 2026-03-09 (SSH Edge QAC Kini Termasuk Speed Lintas Transport)

### Ringkasan
Rilis ini menyatukan perilaku SSH QAC di jalur yang berada di belakang `Edge Gateway (go)`. Setelah patch ini, `quota`, `IP/Login limit`, dan `speed limit` tidak lagi eksklusif ke `SSH WS`, tetapi juga bekerja pada `SSH Direct` dan `SSH SSL/TLS`.

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
- restore kembali ke `go` tetap sehat

### Hasil Validasi
- high-port validation `nginx-stream` -> PASS
- cutover live `nginx-stream` -> PASS
- restore live ke `go` -> PASS

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
- Recovery operasional singkat didokumentasikan di `EDGE_RECOVERY.md`

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
  - `cmd/sshws-proxy/main.go` (`Websocket Proxy (Go)`)
  - `sshws-qac-enforcer.py`
  - `xray-speed.py`
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
- `shellcheck -x -S warning setup.sh opt/setup/core/*.sh opt/setup/install/*.sh opt/setup/bin/xray-domain-guard` -> PASS
- `go -C opt/edge/go test ./cmd/sshws-proxy` -> PASS
- `python3 -m py_compile opt/setup/bin/sshws-qac-enforcer.py opt/setup/bin/xray-speed.py` -> PASS
- Full E2E modular installer `run.sh -> setup.sh -> manage.sh` live -> PASS

## Rilis 2026-03-07 (SSH WS Token Path + QAC Hardening + Telegram Parity)

### Ringkasan
Rilis ini mengubah baseline SSH WS menjadi token path per-user yang fail-close, memperketat SSH QAC pada runtime nyata, dan mendekatkan parity bot Telegram ke CLI sambil menutup beberapa gap operasional.

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

2. Runtime SSH QAC lebih ketat
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
  - `Xray QAC`
  - `SSH QAC`
  - `Security`
  - `Maintenance`
- Action dangerous sekarang otomatis disembunyikan saat `ENABLE_DANGEROUS_ACTIONS=false`.
- Logging gateway Telegram di-hardening agar URL Bot API yang memuat token tidak lagi masuk ke journal baru.
- Archive `bot_telegram.zip` disegarkan agar deploy bawaan tetap konsisten.

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
- `go -C opt/edge/go test ./cmd/sshws-proxy` -> PASS
- `python3 -m py_compile opt/setup/bin/sshws-qac-enforcer.py` -> PASS
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
- `go -C opt/edge/go test ./cmd/sshws-proxy` -> PASS
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
  - `sshws-proxy` (`Websocket Proxy (Go)` di `127.0.0.1:10015`)
- `sshws-qac-enforcer.timer` (enforcement SSH QAC tiap 1 menit)
- `sanity_check` sekarang memverifikasi ketiga service SSH WS, timer enforcer SSH QAC, dan listener port `80/443`.

2. Integrasi nginx share port
- Redirect global HTTP->HTTPS dihapus.
- Endpoint SSH WS memakai `location = /`:
  - `ws://<domain>:80/`
  - `wss://<domain>:443/`
- Path Xray existing (`/vless-ws`, `/vmess-ws`, `/trojan-ws`, `-hup`, `-grpc`) tetap dipertahankan.

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
- Main Menu sekarang juga menambah `5) SSH QAC`:
  - opsi detail mirip quota Xray (view JSON, set quota, reset used, manual block, IP/login limit, speed policy)
  - enforcement lock akun Linux via `passwd -l/-u`
  - lock otomatis limit sesi/login via timer `sshws-qac-enforcer.timer`
- Nomor menu sebelumnya bergeser (Network jadi `6`, Maintenance `10`, installer bot menjadi `12` dan `13`).
- Runtime dropbear untuk SSH WS kini password-enabled (flag disable password dihapus).

### Hasil Validasi
- `bash -n setup.sh manage.sh run.sh install-telegram-bot.sh` -> PASS
- `python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')` -> PASS

## Rilis 2026-03-02 (Bot Auth Hardening + Installer Validation Guard)

### Ringkasan
Rilis ini memfokuskan hardening akses admin bot Telegram dan memastikan flow installer fail-closed saat konfigurasi env belum valid.

### Perubahan Utama
1. Hardening backend secret check
- Verifikasi shared secret backend memakai `hmac.compare_digest`.
- Endpoint health backend bot Telegram kini tetap berada di jalur ber-auth secret.

2. Guard installer Telegram (env validation)
- Installer Telegram kini fail-closed saat ACL admin kosong (kecuali `TELEGRAM_ALLOW_UNRESTRICTED_ACCESS=true`).

### Hasil Validasi
- `bash -n manage.sh setup.sh install-telegram-bot.sh` -> PASS
- `python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')` -> PASS
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

- Deploy bot Telegram:
  - `bot-telegram-backend` -> `active`
  - `bot-telegram-gateway` -> `active`
- Health backend:
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
  - `systemctl is-active bot-telegram-backend bot-telegram-gateway` -> `active active`
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
- Bot backend (`bot-telegram`):
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
  - `bash -n setup.sh manage.sh run.sh install-telegram-bot.sh` -> PASS
  - `shellcheck setup.sh manage.sh opt/manage/features/network.sh` -> PASS
- Python:
  - `python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')` -> PASS
- Runtime:
  - `xray run -test -confdir /usr/local/etc/xray/conf.d` -> PASS
  - `nginx -t` -> PASS

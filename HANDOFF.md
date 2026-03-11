# Handoff Proyek

## Baseline Konteks (Wajib)
Gunakan repo `superdecrypt-dev/autoscript` sebagai source of truth proyek ini.

Agent AI baru wajib memulai dari baseline konteks di atas.

## Baseline Saat Ini
- Repo utama: `https://github.com/superdecrypt-dev/autoscript`
- Workspace aktif (Codex): `/root/project/autoscript`
- Source kerja installer `run.sh`: `/opt/autoscript` (alias kompatibilitas historis: `/root/xray-core_discord`)
- Deploy bot Discord: `/opt/bot-discord`
- Deploy bot Telegram: `/opt/bot-telegram`

## Status Operasional Terkini (2026-03-09)
- Commit terbaru di `main`:
  - `110552f` — `feat(ssh): apply edge qac across all edge transports`
  - `c3b87e5` — `feat(edge): add ssh direct on 80 and 443`
  - `aac822a` — `refactor(edge): remove haproxy provider support`
  - `27194cc` — `docs(edge): rename rollback guide to recovery`
  - `9d55920` — `feat(edge): add haproxy standby failover flow`
  - `0b795dc` — `feat(edge): add nginx-stream provider support`
  - `1b451b2` — `feat(xray): use shorthand shadowsocks paths only`
  - `f1bf684` — `fix(setup): avoid tty warning in non-interactive runs`
  - `da09ee0` — `fix(edge): clean dynamic env export`
  - `ca066dc` — `fix(edge): improve request classification and error handling`
  - `f191110` — `fix: harden edge persistence and discord deploy`
  - `609e173` — `fix(nginx): resolve cert path before template render`
  - `562832c` — `feat(ssh): update ssh ws account info and docs`
  - `8e1c990` — `chore(edge): rename user-facing labels to Edge Gateway`
  - `3c0662d` — `feat(edge): add cli maintenance tools and rollback note`
  - `e96dc37` — `feat(edge): cut over public ports to provider`
  - `8617fe7` — `feat(edge): add guarded runtime activation flow`
  - `a1fbdb6` — `feat(edge): add go provider build and staging flow`
  - `fed9458` — `chore(edge): add provider scaffold`
  - `5356202` — `docs: add edge provider architecture design`
  - `812cf06` — `docs: refine audit and testing playbooks`
  - `f4fa613` — `fix(run): harden local source preflight and add audit playbook`
  - `b8e82a6` — `refactor(setup): modularize installer and tune sshws restart`
  - `921a03e` — `chore: drop generated python cache files`
  - Perubahan penting terbaru:
  - Topologi edge live sekarang diposisikan sebagai:
    - `edge-mux` aktif di publik `80/443`
    - `nginx` backend internal di `127.0.0.1:18080`
    - helper switch:
      - `edge-provider-switch go`
      - `edge-provider-switch nginx-stream`
  - Edge Gateway kini aktif live:
    - provider aktif: `go`
    - `edge-mux` memegang publik `80/443`
    - `nginx` berjalan di backend internal `127.0.0.1:18080`
    - SSH Direct kini tersedia sebagai surface resmi `SSH Direct` di `80/443`
    - SSH klasik TLS kini tersedia sebagai surface resmi `SSH SSL/TLS` di `80/443`
    - BadVPN UDPGW kini tersedia sebagai fitur tambahan SSH di `127.0.0.1:7300`
  - Surface operasional baru:
    - `Maintenance > Edge Gateway Status`
    - `Maintenance > Restart Edge Gateway`
    - `Maintenance > Edge Gateway Info`
    - `Maintenance > BadVPN UDPGW Status`
    - `Maintenance > Restart BadVPN UDPGW`
  - Refactor modular installer sudah commit + push:
    - `setup.sh` kini menjadi orchestrator tipis
    - implementasi installer dipindah ke `opt/setup/core`, `opt/setup/install`, `opt/setup/bin`, dan `opt/setup/templates`
    - full E2E modular installer sudah lolos live
  - SSH WS mode runtime sekarang autoscript-stream compatible (tanpa `Sec-WebSocket-*` wajib), diselaraskan untuk payload klien kompatibilitas.
  - Surface publik Xray untuk `shadowsocks` dan `shadowsocks2022` sekarang memakai path singkat saja:
    - `ss-ws`, `ss-hup`, `ss-grpc`
    - `ss2022-ws`, `ss2022-hup`, `ss2022-grpc`
    - bentuk lama `shadowsocks*` dan `shadowsocks2022*` tidak dipakai lagi
  - Guardrail audit: konsep SSH WS ini harus dipertahankan; referensi perilaku: `https://github.com/nanotechid/supreme` (tanpa menyalin identitas/penamaan repo referensi).
  - SSH WS kini memakai token path per-user 10 hex chars:
    - `/<token>`
    - `/<bebas>/<token>`
    - path tanpa token tidak dipakai lagi
  - SSH WS handshake kini fail-close:
    - path tanpa token -> `401 Unauthorized`
    - token tidak dikenal -> `403 Forbidden`
    - backend internal down -> `502 Bad Gateway`
    - token valid + backend ready -> `101 Switching Protocols`
  - SSH QAC terbaru:
    - quota dan speed limit menempel ke user dari awal lewat token path
    - `IP/Login limit` sekarang dicek sebelum `101`, bukan hanya menunggu timer enforcer
    - active session SSH WS dihitung dari runtime session files
    - runtime session memakai heartbeat `updated_at` dan stale session dibersihkan saat discan
  - `manage.sh` module loader di-hardening:
    - source modul dipilih hanya jika `trusted + lengkap` (semua modul wajib tersedia)
    - urutan source: `/opt/manage` -> `/opt/autoscript/opt/manage` -> local repo `opt/manage`
  - `SSH Management > Add SSH User` kini:
    - mewajibkan input masa aktif (hari)
    - menerima `0` sebagai `back` pada prompt masa aktif
  - Scope enforcement SSH perlu dianggap eksplisit:
    - `SSH WS`, `SSH Direct`, dan `SSH SSL/TLS` sekarang berbagi satu sistem SSH QAC pada jalur edge aktif
    - login SSH native via `sshd`/port `22` belum dihitung atau di-throttle oleh SSH QAC
    - masa aktif dan manual block tetap berlaku pada akun SSH native
  - Edge provider yang aktif kembali dipertegas:
    - `go` adalah provider utama
    - `nginx-stream` tetap experimental
    - dukungan `haproxy` sudah dihapus dari baseline proyek
  - Bot Telegram kini memiliki parity menu yang lebih dekat ke CLI pada area:
    - `Xray Management`
    - `SSH Management`
    - `Xray QAC`
    - `SSH QAC`
    - `Security`
    - `Maintenance`
  - Action dangerous pada bot Telegram sekarang disembunyikan saat `ENABLE_DANGEROUS_ACTIONS=false`; callback stale tetap ditolak aman.
  - Logging gateway Telegram sudah di-hardening agar URL Bot API yang memuat token tidak lagi tercatat di journal baru.
  - `Wireproxy Status` bot Telegram sudah lebih defensif terhadap `BindAddress` yang diberi komentar atau format manual yang tidak rapi.
  - Full E2E `run.sh` live sudah pernah lolos dengan domain random pada `vyxara2.web.id`, dan `/etc/xray/domain` kini disinkronkan konsisten oleh `setup.sh` + `manage.sh`.
  - Full E2E terbaru untuk refactor modular installer juga lolos live:
    - domain final: `dlj8u.vyxara2.web.id`
    - `run.sh` dijalankan dengan `RUN_USE_LOCAL_SOURCE=1 KEEP_REPO_AFTER_INSTALL=1`
    - `xray`, `nginx`, `sshws-dropbear`, `sshws-stunnel`, `sshws-proxy`, `xray-speed`, dan `xray-domain-guard.timer` aktif
    - `/<token>` dan `/<bebas>/<token>` sama-sama lolos `101`
  - Cutover Edge Gateway sudah lolos live:
    - HTTP/HTTPS publik diteruskan ke backend HTTP internal
    - `SSH WS` valid token -> `101`
    - `SSH SSL/TLS` di `443` dan `80` -> banner `dropbear`
  - Provider `nginx-stream` sekarang sudah diimplementasikan dan tervalidasi:
    - high-port validation -> PASS
    - cutover live -> PASS
    - restore kembali ke `go` -> PASS
- Validasi runtime terakhir:
  - `bash -n setup.sh manage.sh opt/manage/features/analytics.sh` -> PASS
  - `python3 -m py_compile opt/setup/bin/sshws-proxy.py opt/setup/bin/sshws-qac-enforcer.py` -> PASS
  - `printf "0\n" | timeout 20 bash manage.sh` -> PASS
  - runtime SSH WS:
    - path tanpa token -> `HTTP/1.1 401 Unauthorized`
    - token tidak valid -> `HTTP/1.1 403 Forbidden`
    - backend down -> `HTTP/1.1 502 Bad Gateway`
    - token valid + backend up -> `HTTP/1.1 101 Switching Protocols`
  - runtime Edge Gateway:
    - `edge-mux.service` -> `active`
    - listener publik di `:80/:443`
    - `nginx` backend di `127.0.0.1:18080`
    - `nginx-stream` sudah lolos smoke high-port dan cutover live, tetapi tetap diposisikan experimental/non-default
  - runtime BadVPN:
    - `badvpn-udpgw.service` -> `active`
    - listener lokal di `127.0.0.1:7300`
  - Validasi modular installer terbaru:
    - `bash -n setup.sh opt/setup/core/*.sh opt/setup/install/*.sh` -> PASS
    - `shellcheck -x -S warning setup.sh opt/setup/core/*.sh opt/setup/install/*.sh opt/setup/bin/xray-domain-guard` -> PASS
    - `python3 -m py_compile opt/setup/bin/sshws-proxy.py opt/setup/bin/sshws-qac-enforcer.py opt/setup/bin/xray-speed.py` -> PASS
  - Validasi playbook terbaru:
    - `TESTING_PLAYBOOK.md` sudah sinkron dengan SSH WS token path dan pengujian bot Telegram
    - `AUDIT_PLAYBOOK.md` sudah sinkron dengan repo modular, bot, dan format audit terbaru

## Riwayat Aktivitas Yang Sudah Dilalui (Ringkas)
1. Sinkronisasi UX bot agar alur pilih protocol/user minim typo.
2. Perapihan output `Add User` / `Account Info` menjadi ringkas + lampiran file akun.
3. Penyederhanaan Domain Control (`Manual` vs `Auto`) dengan root domain select.
4. Penambahan Observability + Domain Guard + Traffic Analytics.
5. Penambahan installer Telegram (`install-telegram-bot.sh`) sebagai pelengkap menu CLI.
6. Penghapusan jalur transport terdepresiasi untuk menstabilkan skenario domain fronting.
7. Full parity WARP + hardening baseline bot Telegram.
8. Split menu bot Telegram antara Xray vs SSH untuk user management dan quota/access control.
9. Ekspansi parity bot Telegram untuk `SSH`, `Security`, dan `Maintenance`.
10. UI bot Telegram sekarang menyembunyikan action dangerous saat runtime policy mematikannya.
11. SSH WS sekarang memakai token path per-user dan QAC session tracking yang lebih ketat.
12. Edge Gateway (`go`) sekarang aktif live dan menjadi frontend publik `80/443`.
13. BadVPN UDPGW sekarang terpasang sebagai fitur tambahan SSH dengan surface status/restart di `Maintenance`.

## Catatan Working Tree Saat Handoff
- Selalu verifikasi kondisi terbaru dengan `git status --short` sebelum mulai.
- Perubahan SSH WS autoscript-stream, token-path SSH WS, SSH WS QAC enforcement, Edge Gateway live cutover, parity/hardening bot Telegram, modular installer, dan playbook docs sudah commit + push ke `main`.
- Jangan mengasumsikan working tree kotor; cek kondisi aktual tiap mulai sesi.

## Prinsip Operasional
- Gunakan `staging` untuk test/R&D; production hanya setelah validasi.
- Bot Discord dan Telegram harus tetap standalone (tidak mengeksekusi `manage.sh` langsung).
- Kedua bot diposisikan sebagai pelengkap CLI `manage.sh`, bukan pengganti penuh.
- Pertahankan `setup.sh` sebagai orchestrator tipis; jangan satukan kembali implementasi besar ke satu file.

## Checklist Mulai Agent Baru
1. Baca `AGENTS.md`, `RELEASE_NOTES.md`, `TESTING_PLAYBOOK.md`, dan file ini.
   - Jika tugasnya audit, baca juga `AUDIT_PLAYBOOK.md`.
2. Konfirmasi anchor konteks repo `superdecrypt-dev/autoscript`.
3. Jalankan `git status --short` dan pastikan baseline jelas.
4. Validasi minimum sebelum perubahan lanjutan:
   - `bash -n setup.sh manage.sh run.sh install-discord-bot.sh install-telegram-bot.sh`
   - `shellcheck -x -S warning run.sh setup.sh manage.sh opt/setup/core/*.sh opt/setup/install/*.sh opt/manage/app/*.sh opt/manage/core/*.sh opt/manage/features/*.sh opt/manage/menus/*.sh`
   - `python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py')`
   - `python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')`
   - `bash bot-telegram/scripts/gate-all.sh`
   - jika tugasnya testing/audit, ikuti `TESTING_PLAYBOOK.md` atau `AUDIT_PLAYBOOK.md` secara penuh
5. Jika menyentuh runtime Xray/Nginx, wajib cek:
   - `xray run -test -confdir /usr/local/etc/xray/conf.d`
   - `nginx -t`
   - `systemctl is-active xray nginx`

## Command Cepat Lanjutan Agent
- Gate bot Discord:
  - `bot-discord/scripts/gate-all.sh local`
- Build gateway Discord:
  - `cd bot-discord/gateway-ts && npm run build`
- Cek service bot (sesuaikan environment):
  - Discord: `systemctl is-active xray-discord-backend xray-discord-gateway`
  - Telegram: `systemctl is-active xray-telegram-backend xray-telegram-gateway`

## SOP Testing Wajib
- Semua pengujian shell script (`run.sh`, `setup.sh`, `manage.sh`, installer bot) dan bot mengacu ke `TESTING_PLAYBOOK.md`.
- Jika ada konflik langkah uji antar dokumen, prioritaskan `TESTING_PLAYBOOK.md` lalu sinkronkan dokumen lain.

## Catatan Risiko Diterima
- Hardcoded Cloudflare token pada lokasi historis diperlakukan sebagai accepted risk/by design, kecuali ada instruksi eksplisit untuk mengubah.

# Handoff Proyek

## Baseline Konteks (Wajib)
Gunakan repo `superdecrypt-dev/autoscript` sebagai source of truth proyek ini.

Agent AI baru wajib memulai dari baseline konteks di atas.

## Baseline Saat Ini
- Repo utama: `https://github.com/superdecrypt-dev/autoscript`
- Workspace aktif (Codex): `/root/project/autoscript`
- Source kerja installer `run.sh`: `/opt/autoscript` (alias kompatibilitas historis: `/root/xray-core_discord`)
- Path deploy bot default jika diinstal:
  - Discord: `/opt/bot-discord`
  - Telegram: `/opt/bot-telegram`

## Status Operasional Terkini (refresh 2026-03-19)
- Commit terbaru di `main`:
  - `e1c198c` — `Seed WARP tier state on setup`
  - `5f52520` — `Restore same-IP DNS cleanup and expand Zero Trust label`
  - `ae4272b` — `fix(ssh): harden WARP runtime status and Zero Trust guard`
  - `4347a22` — `feat(ssh): add Zero Trust-aware WARP routing backend`
  - `9b7d704` — `fix(warp): report Zero Trust proxy ownership accurately`
  - `b9d46ae` — `feat(warp): provision Zero Trust backend foundation`
  - `b5343e0` — `refactor(manage): rebalance main menu and tools flow`
  - `24a2c40` — `Restore embedded Cloudflare token flow`
- Baseline runtime live:
  - provider edge aktif: `go`
  - `edge-mux` memegang publik `:80/:443`
  - `nginx` backend internal di `127.0.0.1:18080`
  - `SSH WS`, `SSH Direct`, dan `SSH SSL/TLS` berbagi satu surface SSH edge
  - `badvpn-udpgw` aktif di `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900`
- Full E2E live terbaru:
  - `run.sh` dijalankan dengan `RUN_USE_LOCAL_SOURCE=1`
  - log: `/var/log/autoscript/setup-20260316-062536.log`
  - domain aktif: `k8i2j.vyxara1.web.id`
  - sertifikat live yang disajikan: `CN = k8i2j.vyxara1.web.id`, valid sampai `Jun 13 2026`
- Validasi runtime terakhir:
  - `systemctl is-active nginx xray edge-mux sshws-dropbear sshws-stunnel sshws-proxy sshws-qac-enforcer.timer badvpn-udpgw xray-speed xray-domain-guard.timer zivpn` -> `active`
  - `xray run -test -confdir /usr/local/etc/xray/conf.d` -> `Configuration OK`
  - `nginx -t` -> `successful`
  - SSH WS live:
    - path tanpa token + websocket -> `401 Unauthorized`
    - token invalid -> `403 Forbidden`
    - token valid -> `101 Switching Protocols`
- Baseline bot di source repo:
  - Telegram kini menu-first dengan `/menu`; `/panel` sudah dihapus total
  - Discord kini hybrid dengan slash publik `/menu`, `/status`, `/notify`
  - flag dangerous actions sudah tidak dipakai lagi sebagai mekanisme utama pada bot
- State bot di host live saat handoff ini:
  - unit file `bot-discord*` dan `bot-telegram*` saat ini tidak terpasang
  - `systemctl list-unit-files 'bot-discord*' 'bot-telegram*'` -> `0 unit files listed`

## Update Refactor Menu Manage (2026-03-19)
- Working tree saat ini memuat modular split CLI `manage` yang belum di-commit; cek `git status --short` sebelum melanjutkan.
- Main menu user-facing yang aktif:
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
- Split source of truth terbaru:
  - `opt/manage/features/users/xray_users.sh` -> `1) Xray Users`
  - `opt/manage/features/users/xray_qac.sh` -> `3) Xray QAC`
  - `opt/manage/features/domain/control.sh` + `domain/cloudflare.sh` -> `8) Domain Control`
  - `opt/manage/features/maintenance/*` -> helper live `11) Maintenance`
  - `opt/manage/features/analytics/*` -> `2) SSH Users`, `4) SSH QAC`, `6) SSH Network`, `10) Security`, `12) Traffic`, `13) Tools` bot installers
  - `opt/manage/features/network/*` -> `5) Xray Network`, `7) Adblocker`, `9) Speedtest`, `13) Tools > WARP Tier`
- Top-level `opt/manage/features/*.sh` sekarang aggregator tipis; jangan menambah logic baru ke sana jika child module domain yang tepat sudah ada.
- `13) Tools` sekarang menjadi rumah untuk `Telegram Bot`, `Discord Bot`, dan `WARP Tier`.
- `WARP Tier` diroute dari `Tools`; judul user-facing yang diharapkan adalah `13) Tools > WARP Tier`.
- `WARP Tier > Zero Trust` sudah punya engine runtime di `manage`, termasuk config state, apply/connect, disconnect, dan return-to-Free/Plus.
- Fondasi install/runtime `cloudflare-warp` + `warp-cli` sedang dirapikan di working tree ini agar setup host tidak lagi bergantung pada instalasi manual untuk backend Zero Trust.
- `SSH Network` tetap belum kompatibel dengan mode `Zero Trust`; guard SSH masih sengaja memblok aktivasi jika effective SSH WARP users masih ada.
- `11) Maintenance` tidak lagi menampilkan `Normalize Quota Dates` pada surface user-facing terbaru.
- Smoke test live terbaru pada `2026-03-19` yang sudah lolos:
  - `printf '0\n' | bash manage.sh`
  - `printf '1\n0\n0\n' | bash manage.sh`
  - `printf '3\n0\n0\n' | bash manage.sh`
  - `printf '5\n0\n0\n' | bash manage.sh`
  - `printf '8\n0\n0\n' | bash manage.sh`
  - `printf '10\n0\n0\n' | bash manage.sh`
  - `printf '11\n0\n0\n' | bash manage.sh`
  - `printf '12\n0\n0\n' | bash manage.sh`
  - `printf '13\n3\n0\n0\n0\n' | bash manage.sh`
- Runtime yang terlihat saat smoke test:
  - domain aktif: `wtlnj.vyxara2.web.id`
  - `WARP Status` ringkas: `Active (Zero Trust)`
  - ringkasan service utama di header menu: `Edge Mux ✅`, `Nginx ✅`, `Xray ✅`, `SSH ✅`

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
10. Bot Telegram kini memakai flow menu-first `/menu` dengan `Status`, `Accounts`, `QAC`, `Domain`, `Network`, `Ops`.
11. Bot Discord kini memakai model hybrid `/menu`, `/status`, `/notify`.
12. SSH WS sekarang memakai token path per-user dan QAC session tracking yang lebih ketat.
13. Edge Gateway (`go`) sekarang aktif live dan menjadi frontend publik `80/443`.
14. BadVPN UDPGW sekarang terpasang sebagai fitur tambahan SSH dengan surface status/restart di `Maintenance`.
15. Refactor menu manage terbaru sedang merapikan ulang numbering surface user-facing, memindahkan `WARP Tier` ke `13) Tools`, dan memisahkan `12) Traffic` sebagai menu analytics mandiri.

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
   - `find opt/manage -type f -name '*.sh' -print0 | xargs -0 shellcheck -x -S warning`
   - `shellcheck -x -S warning run.sh setup.sh manage.sh opt/setup/core/*.sh opt/setup/install/*.sh`
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
  - Discord: `systemctl is-active bot-discord-backend bot-discord-gateway`
  - Telegram: `systemctl is-active bot-telegram-backend bot-telegram-gateway`

## SOP Testing Wajib
- Semua pengujian shell script (`run.sh`, `setup.sh`, `manage.sh`, installer bot) dan bot mengacu ke `TESTING_PLAYBOOK.md`.
- Jika ada konflik langkah uji antar dokumen, prioritaskan `TESTING_PLAYBOOK.md` lalu sinkronkan dokumen lain.

## Catatan Risiko Diterima
- Hardcoded Cloudflare token pada lokasi historis diperlakukan sebagai accepted risk/by design, kecuali ada instruksi eksplisit untuk mengubah.

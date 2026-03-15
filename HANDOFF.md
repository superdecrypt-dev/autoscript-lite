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

## Status Operasional Terkini (2026-03-16)
- Commit terbaru di `main`:
  - `e1d827e` — `fix(bot-discord): tighten domain modal validation`
  - `7737dd9` — `fix(bot-discord): avoid duplicate menu custom ids`
  - `faab408` — `fix(bot-discord): improve hybrid picker and purge flows`
  - `87de35f` — `refactor(bot-discord): adopt hybrid menu workflow`
  - `3c85652` — `refactor(bot-telegram): streamline menu-first flows`
  - `478a081` — `refactor(bot-discord): migrate to slash-native actions`
  - `dcc93ce` — `refactor(bot): remove xray legacy naming`
  - `5865052` — `fix(bot-discord): stabilize backend startup`
  - `203ae87` — `feat(bot-discord): expand parity and fix account refresh`
  - `56e7768` — `refine(bot-telegram): improve parity and startup flow`
  - `0b9f6ea` — `refine(bot-telegram): align account info with cli`
  - `c9149d6` — `refactor(bot-telegram): remove dangerous actions flag`
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
  - Discord: `systemctl is-active bot-discord-backend bot-discord-gateway`
  - Telegram: `systemctl is-active bot-telegram-backend bot-telegram-gateway`

## SOP Testing Wajib
- Semua pengujian shell script (`run.sh`, `setup.sh`, `manage.sh`, installer bot) dan bot mengacu ke `TESTING_PLAYBOOK.md`.
- Jika ada konflik langkah uji antar dokumen, prioritaskan `TESTING_PLAYBOOK.md` lalu sinkronkan dokumen lain.

## Catatan Risiko Diterima
- Hardcoded Cloudflare token pada lokasi historis diperlakukan sebagai accepted risk/by design, kecuali ada instruksi eksplisit untuk mengubah.

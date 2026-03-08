# Repository Guidelines

## Identitas Proyek (Terkini)
- Nama proyek/repo aktif: `autoscript`
- Remote utama: `https://github.com/superdecrypt-dev/autoscript`
- Source kerja installer `run.sh` di VPS: `/opt/autoscript` (alias kompatibilitas historis: `/root/xray-core_discord`)
- Deploy bot Discord tetap: `/opt/bot-discord`
- Deploy bot Telegram tetap: `/opt/bot-telegram`

## Struktur Proyek & Organisasi Modul
Repositori ini memiliki area root untuk skrip operasional server: `setup.sh` (provisioning awal), `manage.sh` (menu harian), `run.sh` (bootstrap installer), `install-discord-bot.sh`, dan `install-telegram-bot.sh`. Source modular `manage.sh` berada di `opt/manage/` (sinkron ke `/opt/manage` di VPS).  
Source modular `setup.sh` sekarang berada di `opt/setup/`:
- `opt/setup/core/` untuk helper umum
- `opt/setup/install/` untuk langkah provisioning per domain tanggung jawab
- `opt/setup/bin/` untuk asset runtime/script yang di-install saat setup
- `opt/setup/templates/` untuk template config dan unit systemd  
Area `bot-discord/` adalah stack bot Discord standalone (`gateway-ts/`, `backend-py/`, `shared/`, `systemd/`, `scripts/`).  
Area `bot-telegram/` adalah stack bot Telegram standalone (`gateway-py/`, `backend-py/`, `shared/`, `systemd/`, `scripts/`).

## Build, Test, dan Command Pengembangan
- `bash -n setup.sh manage.sh run.sh install-discord-bot.sh install-telegram-bot.sh`: validasi syntax skrip shell.
- `bash -n setup.sh opt/setup/core/*.sh opt/setup/install/*.sh`: validasi syntax modular installer.
- `shellcheck *.sh`: lint shell di root.
- `shellcheck -x -S warning setup.sh opt/setup/core/*.sh opt/setup/install/*.sh`: lint modular installer.
- `sudo bash run.sh`: instalasi cepat (pasang `manage` + `install-discord-bot` ke `/usr/local/bin` lalu jalankan setup).
- `sudo manage`: buka menu operasional utama.
- `sudo /usr/local/bin/install-discord-bot menu`: buka installer bot Discord.
- `sudo /usr/local/bin/install-telegram-bot menu`: buka installer bot Telegram.
- `python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py')`: cek syntax backend bot Discord.
- `python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')`: cek syntax backend+gateway bot Telegram.
- `cd bot-discord/gateway-ts && npm run build`: validasi build gateway TypeScript.
- `bash bot-discord/scripts/gate-all.sh local`: gate test bot Discord.
- `bash bot-telegram/scripts/gate-all.sh`: gate test bot Telegram.
- `TESTING_PLAYBOOK.md`: SOP pengujian lengkap untuk shell script + bot Discord/Telegram (preflight, smoke, negative, integration, gate).
- `AUDIT_PLAYBOOK.md`: SOP audit untuk entrypoint, modular installer, SSH WS/QAC, template runtime, dan bot.

## Gaya Kode & Konvensi Penamaan
Gunakan Bash strict mode (`set -euo pipefail`) dan pola defensif yang sudah ada (`ok`, `warn`, `die`). Indentasi utama 2 spasi untuk shell. Nama fungsi `snake_case`, konstanta/env `UPPER_SNAKE_CASE`, nama skrip `kebab-case.sh`. Untuk Python/TypeScript bot, gunakan nama modul yang deskriptif per domain menu (`menu_1_status`, `menu_8_maintenance`, dst).

## Panduan Testing
Minimum sebelum merge: syntax check + lint shell + smoke check layanan terkait. Untuk perubahan runtime Xray, verifikasi `systemctl status xray xray-expired xray-quota xray-limit-ip xray-speed --no-pager` dan `xray run -test -confdir /usr/local/etc/xray/conf.d`. Untuk bot Discord, uji `backend-py` health endpoint dan alur `/panel` -> button -> modal di server Discord staging.
Untuk bot Telegram, uji `backend-py` health endpoint ber-auth secret dan flow `/panel` + `/cleanup`.  
Untuk SSH WS, verifikasi handshake `101` saat backend siap dan `502` saat backend internal (`sshws-stunnel`) down.  
Gunakan `TESTING_PLAYBOOK.md` sebagai sumber langkah testing baku sebelum rilis.

## Environment Separation (Wajib)
Gunakan pemisahan environment agar perubahan aman:
- `Staging environment`: khusus test/R&D, validasi gate, smoke, failure, dan eksperimen.
- `Production environment`: khusus layanan running/live user.
- Alur rilis wajib: uji di staging dulu, baru promote ke production.
- Selalu siapkan snapshot/rollback sebelum perubahan besar di production.

## Commit & Pull Request
Ikuti konvensi commit yang sudah dipakai: `feat`, `fix`, `docs`, `chore`, `refactor`, `style`, `security` (opsional dengan scope, contoh `feat(bot): ...`). PR wajib memuat ringkasan perubahan, risiko/rollback, command validasi yang dijalankan, serta bukti hasil (log/screenshot) untuk perubahan interaksi menu.

## Keamanan & Konfigurasi
Jangan commit token/secret/key. Simpan rahasia pada env file (contoh: `/etc/xray-discord-bot/bot.env`) dan gunakan masking saat ditampilkan. Semua skrip diasumsikan berjalan sebagai root; selalu uji dulu di VPS non-produksi sebelum rollout ke produksi.
Standar OAuth2 invite bot Discord: gunakan scope `bot` + `applications.commands`, dengan permissions minimum `View Channels`, `Send Messages`, `Embed Links`, `Read Message History` (permission integer `84992`). Hindari permission `Administrator`; tambahkan `Attach Files` hanya jika fitur kirim file log memang dipakai.
Catatan khusus proyek ini: temuan hardcoded Cloudflare token pada lokasi historis tertentu diperlakukan sebagai by design (accepted risk) dan diabaikan dalam review rutin, kecuali ada instruksi eksplisit untuk mengubahnya.

## Catatan Handoff (Ringkas)
- Bot Discord dijaga standalone dan tidak mengeksekusi `manage.sh` secara langsung.
- Bot Telegram juga dijaga standalone dan tidak mengeksekusi `manage.sh` secara langsung.
- Kedua bot diposisikan sebagai pelengkap CLI `manage.sh`, bukan pengganti penuh alur CLI.
- Target UX bot: profesional, minim teks tidak perlu, dan anti-spam output panjang.
- SSH WS saat ini berjalan pada konsep autoscript-stream (non-hybrid, tanpa `Sec-WebSocket-*` wajib).
- `setup.sh` harus dipertahankan sebagai orchestrator tipis; implementasi installer baru ditempatkan di `opt/setup/*`.
- Jalur SSH WS resmi sekarang wajib token path per-user:
  - `/<token>`
  - `/<bebas>/<token>`
- Fail-close SSH WS yang harus dipertahankan:
  - tanpa token -> `401`
  - token tidak dikenal -> `403`
  - backend internal tidak siap -> `502`
  - token valid + backend siap -> `101`
- Baseline audit SSH WS: pertahankan konsep ini sebagai desain resmi; referensi konsep perilaku: `https://github.com/nanotechid/supreme` (tanpa wajib meniru penamaan/struktur repo referensi).
- Scope enforcement SSH saat ini harus dianggap by design:
  - `quota_used`, quota traffic, IP/login limit, dan speed limit SSH berlaku pada jalur SSH WS.
  - Login SSH native via `sshd`/port `22` belum dihitung atau di-throttle oleh SSH QAC.
  - Masa aktif akun dan manual block tetap berlaku pada SSH native.
- QAC SSH WS terbaru yang perlu dipertahankan:
  - identitas user ditentukan dari token path, bukan infer sesi login
  - `IP/Login limit` dicek sebelum `101`
  - active session dibaca dari runtime session files SSH WS
  - runtime session memakai heartbeat `updated_at` dan stale session dibersihkan saat discan
- Loader modul `manage.sh` kini memilih source modul hanya jika `trusted + lengkap`.
- Full E2E modular installer (`run.sh` dengan source lokal repo) sudah lolos live pada `2026-03-08`.
- Rilis dilakukan lewat staging terlebih dulu; production hanya setelah validasi gate/smoke selesai.
- SOP validasi lintas shell+bot terpusat di `TESTING_PLAYBOOK.md`.
- SOP audit terpusat di `AUDIT_PLAYBOOK.md`.

## Aktivitas Terkini (Update 2026-03-08)
- Fokus sprint terbaru: hardening admission/session tracking SSH WS + sinkronisasi dokumentasi + parity bot Telegram.
- Refactor modular installer aktif:
  - `setup.sh` turun menjadi orchestrator tipis
  - modul installer aktif di `opt/setup/*`
  - full E2E live untuk jalur modular terbaru sudah PASS
- Perubahan besar yang sudah dilalui:
  - SSH WS berpindah ke mode autoscript-stream penuh untuk kompatibilitas payload klien.
  - SSH WS sekarang memakai token path per-user `/<token>` dan `/<bebas>/<token>`.
  - Guard runtime SSH WS: tanpa token -> `401`, token tidak valid -> `403`, backend down -> `502`, token valid -> `101`.
  - `Add SSH User` kini wajib input masa aktif (hari) dan mendukung `0` sebagai `back`.
  - Resolver source modul `manage.sh` di-hardening dengan validasi `trusted + lengkap`.
  - Struktur modular `setup.sh` kini aktif dipakai:
    - `opt/setup/core`
    - `opt/setup/install`
    - `opt/setup/bin`
    - `opt/setup/templates`
  - QAC SSH WS sekarang lebih ketat:
    - user resolve dari token path
    - `IP/Login limit` dicek sebelum handshake sukses
    - active session memakai runtime session files dengan heartbeat/freshness cleanup
- Commit terbaru yang sudah di-push:
  - `9542703` (`fix(sshws): harden admission and session tracking`)
  - `87b43fb` (`fix(ssh): enforce SSH active-days and switch sshws mode`)
  - `edd9852` (`fix(runtime): harden sshws handshake and manage module loading`)
  - `71a21a4` (`docs: sync markdown with latest sshws runtime behavior`)
- Validasi runtime terbaru:
  - `bash -n setup.sh manage.sh opt/manage/features/analytics.sh` -> PASS
  - `python3 -m py_compile` heredoc `sshws-proxy` dan `sshws-qac-enforcer` -> PASS
  - smoke `manage.sh` -> PASS
  - uji SSH WS tokenless/invalid/down/up -> PASS (`401` / `403` / `502` / `101`)
- Catatan workspace saat handoff ini ditulis:
  - Perubahan utama runtime + docs sudah tercatat commit dan push.
  - Selalu cek `git status --short` sebelum mulai perubahan baru.

## Checklist Agent Baru (Praktis)
1. Jalankan `git status --short` untuk cek perubahan lokal sebelum mulai.
2. Baca `HANDOFF.md` bagian "Status Operasional Terkini".
3. Validasi cepat runtime shell:
   - `bash -n setup.sh manage.sh run.sh install-discord-bot.sh install-telegram-bot.sh`
   - `bash -n setup.sh opt/setup/core/*.sh opt/setup/install/*.sh`
   - `shellcheck -x -S warning setup.sh opt/setup/core/*.sh opt/setup/install/*.sh`
   - `printf "0\n" | timeout 20 bash manage.sh`
4. Validasi cepat bot:
   - `python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py')`
   - `python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')`
   - `cd bot-discord/gateway-ts && npm run build`
5. Uji staging sebelum perubahan baru:
   - `bot-discord/scripts/gate-all.sh local`
   - `bash bot-telegram/scripts/gate-all.sh`
   - lanjut E2E manual `/panel` sesuai `TESTING_PLAYBOOK.md`.
6. Jika tugasnya audit/review, ikuti urutan dan format temuan di `AUDIT_PLAYBOOK.md`.

## Baseline Konteks Owner (Wajib Lanjutkan Dari Sini)
- Baseline konteks wajib: gunakan repo `superdecrypt-dev/autoscript` sebagai source of truth proyek ini.
- Semua agent baru harus menganggap kalimat di atas sebagai baseline konteks proyek.

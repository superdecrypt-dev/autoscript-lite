# Handoff Proyek

## Anchor Konteks (Wajib)
"oke saat ini kamu mengingatnya bahwa menggunakan repo superdecrypt-dev/autoscript"

Agent AI baru wajib memulai dari konteks di atas.

## Baseline Saat Ini
- Repo utama: `https://github.com/superdecrypt-dev/autoscript`
- Workspace aktif (Codex): `/project/autoscript`
- Source kerja installer `run.sh`: `/opt/autoscript` (alias kompatibilitas historis: `/root/xray-core_discord`)
- Deploy bot Discord: `/opt/bot-discord`
- Deploy bot Telegram: `/opt/bot-telegram`

## Status Operasional Terkini (2026-03-06)
- Commit terbaru di `main`:
  - `edd9852` — `fix(runtime): harden sshws handshake and manage module loading`
  - `87b43fb` — `fix(ssh): enforce SSH active-days and switch sshws mode`
  - `5d0a08c` — `feat: add ss multi-user support and stabilize bot e2e`
  - `af6aabe` — `feat(telegram): full warp parity and hardening baseline`
- Perubahan penting terbaru:
  - SSHWS mode runtime sekarang autoscript-stream compatible (tanpa `Sec-WebSocket-*` wajib), diselaraskan untuk payload klien kompatibilitas.
  - Guardrail audit: konsep SSHWS ini harus dipertahankan; referensi perilaku: `https://github.com/nanotechid/supreme` (tanpa menyalin identitas/penamaan repo referensi).
  - SSHWS handshake kini fail-close:
    - backend internal down -> `502 Bad Gateway`
    - backend internal ready -> `101 Switching Protocols`
  - Normalisasi request-target SSHWS mendukung:
    - `/`
    - `/?ed=...`
    - `wss://host/path?...`
  - `manage.sh` module loader di-hardening:
    - source modul dipilih hanya jika `trusted + lengkap` (semua modul wajib tersedia)
    - urutan source: `/opt/manage` -> `/opt/autoscript/opt/manage` -> local repo `opt/manage`
  - `SSH Management > Add SSH User` kini:
    - mewajibkan input masa aktif (hari)
    - menerima `0` sebagai `back` pada prompt masa aktif
  - Scope enforcement SSH perlu dianggap eksplisit:
    - `quota_used`, quota traffic, IP/login limit, dan speed limit saat ini berlaku pada jalur SSHWS
    - login SSH native via `sshd`/port `22` belum dihitung atau di-throttle oleh SSH QAC
    - masa aktif dan manual block tetap berlaku pada akun SSH native
  - Hardening bot + parity Telegram/WARP + dukungan SS multi-user dari rilis 2026-03-02 tetap berlaku.
- Validasi runtime terakhir:
  - `bash -n setup.sh manage.sh opt/manage/features/analytics.sh` -> PASS
  - `python3 -m py_compile` untuk heredoc `sshws-proxy` -> PASS
  - `printf "0\n" | timeout 20 bash manage.sh` -> PASS
  - runtime SSHWS:
    - backend down -> `HTTP/1.1 502 Bad Gateway`
    - backend up -> `HTTP/1.1 101 Switching Protocols`

## Riwayat Aktivitas Yang Sudah Dilalui (Ringkas)
1. Sinkronisasi UX bot agar alur pilih protocol/user minim typo.
2. Perapihan output `Add User` / `Account Info` menjadi ringkas + lampiran file akun.
3. Penyederhanaan Domain Control (`Manual` vs `Auto`) dengan root domain select.
4. Penambahan Observability + Domain Guard + Traffic Analytics.
5. Penambahan installer Telegram (`install-telegram-bot.sh`) sebagai pelengkap menu CLI.
6. Penghapusan jalur transport terdepresiasi untuk menstabilkan skenario domain fronting.
7. Full parity WARP + hardening baseline bot Telegram.

## Catatan Working Tree Saat Handoff
- Selalu verifikasi kondisi terbaru dengan `git status --short` sebelum mulai.
- Perubahan SSHWS autoscript-stream + runtime hardening loader module sudah commit + push ke `main` (`87b43fb`, `edd9852`).

## Prinsip Operasional
- Gunakan `staging` untuk test/R&D; production hanya setelah validasi.
- Bot Discord dan Telegram harus tetap standalone (tidak mengeksekusi `manage.sh` langsung).
- Kedua bot diposisikan sebagai pelengkap CLI `manage.sh`, bukan pengganti penuh.

## Checklist Mulai Agent Baru
1. Baca `AGENTS.md`, `RELEASE_NOTES.md`, `TESTING_PLAYBOOK.md`, dan file ini.
2. Konfirmasi anchor konteks repo `superdecrypt-dev/autoscript`.
3. Jalankan `git status --short` dan pastikan baseline jelas.
4. Validasi minimum sebelum perubahan lanjutan:
   - `bash -n setup.sh manage.sh run.sh install-discord-bot.sh install-telegram-bot.sh`
   - `shellcheck setup.sh manage.sh`
   - `python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py')`
   - `python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')`
   - `bash bot-telegram/scripts/gate-all.sh`
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

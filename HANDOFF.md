# Handoff Proyek

## Anchor Konteks (Wajib)
"oke saat ini kamu mengingatnya bahwa menggunakan repo superdecrypt-dev/autoscript"

Agent AI baru wajib memulai dari konteks di atas.

## Baseline Saat Ini
- Repo utama: `https://github.com/superdecrypt-dev/autoscript`
- Workspace aktif (Codex): `/project/autoscript`
- Source kerja installer `run.sh`: `/opt/autoscript` (alias kompatibilitas lama: `/root/xray-core_discord`)
- Deploy bot Discord: `/opt/bot-discord`
- Deploy bot Telegram: `/opt/bot-telegram`

## Status Operasional Terkini (2026-03-02)
- Commit terbaru di `main`:
  - `5d0a08c` — `feat: add ss multi-user support and stabilize bot e2e`
  - `af6aabe` — `feat(telegram): full warp parity and hardening baseline`
  - `b86e6d8` — `feat(bot-telegram): polish panel flows and add user speed-limit fields`
  - `8bcf1d4` — `fix(xray): cleanup legacy transport paths in setup/manage/bot links`
- Perubahan penting terbaru:
  - Hardening auth bot Discord:
    - gateway fail-closed jika ACL admin kosong (`DISCORD_ADMIN_ROLE_IDS` / `DISCORD_ADMIN_USER_IDS` wajib minimal salah satu)
    - fallback izin `Administrator` saat ACL kosong dihapus
    - parser role interaction diperkuat untuk member partial/API object (tanpa cast `as any`).
  - Hardening flow installer bot Discord/Telegram:
    - default `ENABLE_DANGEROUS_ACTIONS=false`
    - `configure-env` kini gagal jika env belum valid
    - `start/restart services` hard-block jika env belum valid
    - Telegram installer fail-closed saat ACL admin kosong (kecuali override eksplisit `TELEGRAM_ALLOW_UNRESTRICTED_ACCESS=true`).
  - Hysteria2 sekarang terintegrasi di `setup.sh` (tanpa installer terpisah) dengan default `UDP 443`.
  - `setup.sh` mengaktifkan `hysteria-server` + `xray-hy2-sync` untuk sync quota/ip-limit/expired.
  - `manage.sh` `2) User Management` menambahkan bonus akun Hysteria2 saat add user `vless/vmess/trojan`.
  - `XRAY ACCOUNT INFO` kini menampilkan `HY2 User`, `HY2 Pass`, `HY2 URI` untuk akun bonus.
  - Dukungan protocol account sekarang mencakup `shadowsocks` dan `shadowsocks2022` (multi-user) di CLI + bot.
  - Method default SS:
    - `shadowsocks`: `aes-128-gcm`
    - `shadowsocks2022`: `2022-blake3-aes-128-gcm`
  - Telegram installer distabilkan:
    - checksum archive default diperbarui
    - default backend Telegram ke `127.0.0.1:8081`
    - unit backend Telegram memakai `${BACKEND_HOST}`/`${BACKEND_PORT}` (tidak hardcoded).
  - Bot Telegram sekarang punya full parity WARP di menu `4) Network Controls` (status/restart/global/per-user/per-inbound/per-domain/tier/reconnect).
  - Hardening Telegram aktif:
    - backend health butuh secret header
    - ACL default-deny (admin IDs wajib, kecuali override eksplisit)
    - cooldown action/cleanup
    - masking output sensitif.
  - UX bot Telegram dipoles (flow panel, picker user delete, cleanup, Add User speed limit).
  - Transport legacy non-default dibersihkan dari template `setup.sh`, generator `manage.sh`, dan backend bot Discord/Telegram.
  - Menu CLI saat ini: `9) Traffic Analytics`, `10) Install BOT Discord`, `11) Install BOT Telegram`.
- Validasi runtime terakhir:
  - `xray run -test -confdir /usr/local/etc/xray/conf.d` -> `Configuration OK`
  - `nginx -t` -> valid
  - `systemctl is-active xray nginx` -> `active`
  - `systemctl is-active xray-discord-backend xray-discord-gateway` -> `active active`
  - `systemctl is-active xray-telegram-backend xray-telegram-gateway` -> `active active`
  - `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health` -> `200`
  - `curl -s -o /dev/null -w '%{http_code}' -H "X-Internal-Shared-Secret: <secret>" http://127.0.0.1:8081/health` -> `200`
  - `set -a; . /etc/xray-telegram-bot/bot.env; set +a; /opt/bot-telegram/scripts/smoke-test.sh` -> PASS

## Riwayat Aktivitas Yang Sudah Dilalui (Ringkas)
1. Sinkronisasi UX bot agar alur pilih protocol/user minim typo.
2. Perapihan output `Add User` / `Account Info` menjadi ringkas + lampiran file akun.
3. Penyederhanaan Domain Control (`Manual` vs `Auto`) dengan root domain select.
4. Penambahan Observability + Domain Guard + Traffic Analytics.
5. Penambahan installer Telegram (`install-telegram-bot.sh`) sebagai pelengkap menu CLI.
6. Penghapusan jalur transport legacy untuk menstabilkan skenario domain fronting.
7. Full parity WARP + hardening baseline bot Telegram.

## Catatan Working Tree Saat Handoff
- Selalu verifikasi kondisi terbaru dengan `git status --short` sebelum mulai.
- Perubahan utama SS multi-user + stabilisasi E2E bot sudah commit + push ke `main` (`5d0a08c`).

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
- Hardcoded Cloudflare token pada lokasi legacy diperlakukan sebagai accepted risk/by design, kecuali ada instruksi eksplisit untuk mengubah.

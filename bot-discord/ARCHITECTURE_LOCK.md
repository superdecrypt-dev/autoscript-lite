# Kunci Arsitektur Bot Discord

Dokumen ini menjadi acuan tetap implementasi bot Discord standalone pada repo ini.

## 0) Status Baseline Terkini
- Identitas repo utama: `superdecrypt-dev/autoscript`.
- Bootstrap source server oleh `run.sh`: clone/update ke `/opt/autoscript`.
- Deploy runtime bot tetap terpisah di `/opt/bot-discord` (tidak berubah).
- Installer bot default mengunduh archive dari repo `autoscript`.

## 1) Prinsip Dasar
- Bot Discord berdiri sendiri dan **tidak mengeksekusi `manage.sh`**.
- Perilaku menu mengikuti struktur CLI `manage.sh` (menu 1-8 + 12), tetapi eksekusi action dilakukan oleh backend bot.
- UI Discord memakai model hybrid: slash publik tetap sedikit, sedangkan flow utama berjalan lewat button/select/modal.

## 2) Struktur Direktori Bot
```text
bot-discord/
├─ gateway-ts/
│  ├─ package.json
│  ├─ tsconfig.json
│  ├─ .env.example
│  └─ src/
│     ├─ index.ts
│     ├─ config.ts
│     ├─ authz.ts
│     ├─ api_client.ts
│     ├─ interactions/
│     └─ slash/
├─ backend-py/
│  ├─ requirements.txt
│  ├─ .env.example
│  └─ app/
│     ├─ main.py
│     ├─ config.py
│     ├─ auth.py
│     ├─ routes/
│     ├─ services/
│     ├─ adapters/
│     └─ utils/
├─ runtime/
│  ├─ logs/
│  ├─ locks/
│  └─ tmp/
├─ systemd/
│  ├─ bot-discord-backend.service.tpl
│  ├─ bot-discord-gateway.service.tpl
│  ├─ bot-discord-monitor.service.tpl
│  └─ bot-discord-monitor.timer.tpl
└─ scripts/
   ├─ dev-up.sh
   ├─ dev-down.sh
   ├─ smoke-test.sh
   ├─ gate-all.sh
   ├─ rotate-discord-token.sh
   └─ monitor-lite.sh
```

## 3) Kontrak Menu Installer
Installer utama: `install-discord-bot.sh` dengan mode `menu`.

```text
1) Quick Setup Bot Discord (All-in-One)
2) Install Dependencies
3) Configure Bot (.env)
4) Ganti Discord Bot Token
5) Deploy/Update Bot Files
6) Install/Update systemd Services
7) Start/Restart Services
8) Status Services
9) View Logs
10) Uninstall Bot
0) Back
```

Ringkasan fungsi:
- `1` menjalankan alur penuh: dependency -> env/token -> deploy -> systemd -> start -> verifikasi.
- `4` update token aman (`read -s`, konfirmasi ulang, permission file env 600).
- `5` deploy dari archive GitHub lalu `rsync` ke target.
- `6` memasang template systemd untuk backend dan gateway.
- `6` juga memasang monitor ringan (`bot-discord-monitor.timer`).
- `7-9` operasional service (restart/status/log) termasuk status monitor timer.

Script test otomatis:
- `scripts/gate-all.sh local` menjalankan Gate 1-3.
- `scripts/gate-all.sh prod` menjalankan Gate 3.1, 5, 6.
- `scripts/gate-all.sh all` menjalankan Gate 1-6 (Gate 4 via `STAGING_INSTANCE`).
- SOP lengkap pengujian lintas shell script + bot Discord terdokumentasi di `../TESTING_PLAYBOOK.md`.

Script keamanan:
- `scripts/rotate-discord-token.sh` untuk rotasi `DISCORD_BOT_TOKEN` via prompt tersembunyi, update env file, lalu restart gateway.

Script monitoring:
- `scripts/monitor-lite.sh` mengecek backend/gateway/health dan mencatat ringkas ke `/var/log/bot-discord/monitor-lite.log`.

Ketentuan UX gateway (terkini):
- Respons private interaction menggunakan `flags: MessageFlags.Ephemeral` (menghindari warning deprecate).
- Output action panjang dipotong per chunk agar tidak spam di perangkat mobile.
- Slash publik: `/menu`, `/status`, `/notify`.
- Kategori operasional utama tersedia dari `/menu`: `Accounts`, `QAC`, `Domain`, `Network`, `Ops`.

## 4) Update Arsitektur Terkini (2026-02-25)
1. Menu dan kapabilitas baru:
   - Menu `12) Traffic Analytics` ditambahkan ke gateway router + backend service.
   - Menu `5)` mendapat action domain guard:
     - `domain_guard_check`
     - `domain_guard_status`
     - `domain_guard_renew`
2. Standar UX terbaru:
   - Label tombol diseragamkan dengan pola `View/Run/Set/Toggle`.
   - Action yang memiliki dampak tinggi tetap memakai konfirmasi (`confirm`).
3. Kontrak data:
   - Gateway Discord memakai schema slash internal TypeScript sebagai sumber navigasi aktif.
   - Export analytics memakai `data.download_file` dengan payload base64 untuk attachment Discord.
4. Jalur eksekusi runtime:
   - Gateway (`discord.js`) -> backend FastAPI -> adapter system/mutations -> respon terstruktur (`ok/code/title/message/data`).
5. Status validasi terbaru:
   - Build gateway + compile backend PASS.
   - Entry point aktif: `/menu`, `/status`, `/notify`.
   - `/panel` dan flow legacy tidak dipakai.

## 5) Lokasi Deploy & Integrasi Root Script
- Lokasi bot terpasang: `/opt/bot-discord`
- Env produksi: `/etc/bot-discord/bot.env`
- Runtime data/log: `/var/lib/bot-discord`, `/var/log/bot-discord`
- Launcher installer: `/usr/local/bin/install-discord-bot`

Integrasi:
- `run.sh` memasang `install-discord-bot.sh` ke `/usr/local/bin/install-discord-bot`
- `manage.sh` menu `9) Install BOT Discord` menjalankan `/usr/local/bin/install-discord-bot menu`

## 6) Mekanisme Deploy di VPS (Tanpa Repo Lokal)
1. Unduh archive source (`tar.gz`) dengan `REF` terpin.
2. Extract ke staging `/tmp`.
3. Validasi struktur wajib (`gateway-ts/package.json`, `backend-py/requirements.txt`, template systemd).
4. Sinkronisasi ke `/opt/bot-discord` menggunakan `rsync -a --delete` (exclude `.env`, `.venv`, `node_modules`, `__pycache__`, `*.pyc`).
5. Install dependency backend + gateway, build gateway, pasang/update systemd, lalu restart service.

Dokumen ini dianggap baseline hingga ada perubahan arsitektur yang disepakati.

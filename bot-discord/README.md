# Bot Discord Standalone (Hybrid Slash + Interactive Menu)

Bot ini berdiri sendiri dan tidak menjalankan `manage.sh`. Perilaku menunya dibuat mirip struktur `manage.sh`, tetapi seluruh aksi dieksekusi lewat backend sendiri.

## Arsitektur
- `gateway-ts/`: Discord gateway (`discord.js`) untuk slash entrypoint, tombol, select menu, modal, dan konfirmasi.
- `backend-py/`: API internal (`FastAPI`) untuk operasi sistem/Xray.
- `systemd/`: template service untuk deployment.

## Alur Interaksi
1. Admin membuka `/menu` untuk dashboard utama, atau memakai `/status` dan `/notify` untuk aksi cepat.
2. Gateway memproses command lalu melanjutkan flow lewat tombol, select menu, modal, dan konfirmasi.
3. Gateway memanggil backend domain action (`/api/{domain}/action`) dengan secret internal.
4. Backend menjalankan aksi dan mengembalikan hasil ke Discord.

## Slash Command Aktif
- `/menu`
- `/status`
- `/notify`

Bot ini tidak lagi memakai `/panel`. Jalur aktif sekarang memakai model hybrid:
- `/menu` membuka dashboard `Accounts`, `QAC`, `Domain`, `Network`, dan `Ops`
- `/status` dipakai untuk cek cepat
- `/notify` dipakai untuk konfigurasi notifikasi

## UX Terkini
- `/menu` membuka 5 kategori utama: `Accounts`, `QAC`, `Domain`, `Network`, `Ops`
- `Accounts` memakai button/select/modal untuk:
  - `Add User`
  - `Account Info`
  - `Delete User`
  - `Extend Expiry`
  - `Reset Password` (SSH)
- `QAC` memakai picker user lalu panel aksi per-user
- `Domain`, `Network`, dan `Ops` juga sudah bisa dijalankan dari `/menu`
- Output panjang seperti `ACCOUNT INFO` dan export tetap dikirim sebagai teks + attachment
- Semua interaction operasional memakai `flags: MessageFlags.Ephemeral`

## Jalankan Lokal
```bash
cd bot-discord
cp .env.example .env

# Backend
python3 -m venv .venv
. .venv/bin/activate
pip install -r backend-py/requirements.lock.txt
uvicorn backend-py.app.main:app --host 127.0.0.1 --port 7080 --reload

# Gateway (terminal lain)
cd gateway-ts
npm install
npm run dev
```

## Otomasi Pengujian Gate
Satu command untuk menjalankan paket uji bertahap:

```bash
cd bot-discord
./scripts/gate-all.sh local   # Gate 1,2,3 (local/staging non-produksi)
./scripts/gate-all.sh prod    # Gate 3.1,5,6 (produksi via LXC)
./scripts/gate-all.sh all     # Gate 1-6 (Gate 4 pakai STAGING_INSTANCE)
```

Override target instance jika perlu:

```bash
PROD_INSTANCE=xray-itg-1771777921 STAGING_INSTANCE=xray-stg-gate3-1771864485 ./scripts/gate-all.sh all
```

## Rotasi Token Discord (Aman)
Jalankan langsung di VPS agar token tidak terkirim ke chat/log:

```bash
cd /opt/bot-discord
./scripts/rotate-discord-token.sh
```

Script akan:
- meminta token baru dengan input tersembunyi,
- update `DISCORD_BOT_TOKEN` di env file deploy,
- restart `bot-discord-gateway`,
- menampilkan status service setelah restart.

## Monitoring Ringan (Timer)
Deploy terbaru memasang timer `bot-discord-monitor.timer` (interval 5 menit) yang menjalankan:

```bash
/opt/bot-discord/scripts/monitor-lite.sh
```

Cakupan cek:
- status `bot-discord-backend`,
- status `bot-discord-gateway`,
- endpoint `GET /health` backend.

Lihat status timer:

```bash
systemctl status bot-discord-monitor.timer --no-pager
tail -n 50 /var/log/bot-discord/monitor-lite.log
```

## Arah UX
- Slash command publik dibuat tetap pendek: `/menu`, `/status`, `/notify`
- Flow utama berjalan lewat button, select menu, modal, dan konfirmasi
- `/panel` tidak dipakai lagi

## Catatan Keamanan
- Simpan token hanya di env file (`/etc/bot-discord/bot.env` saat deploy).
- Secret API internal wajib diset (`INTERNAL_SHARED_SECRET`).
- Wajib isi minimal salah satu ACL admin: `DISCORD_ADMIN_ROLE_IDS` atau `DISCORD_ADMIN_USER_IDS` (gateway fail-closed jika keduanya kosong).
- Action mutasi aktif untuk admin yang lolos ACL.
- Beberapa aksi maintenance (restart service) butuh root/sudo dan sebaiknya dibatasi role admin Discord.

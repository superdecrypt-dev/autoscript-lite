# Autoscript License Portal

Portal ini adalah sistem lisensi IP untuk autoscript yang ditujukan untuk deploy di:
- `Cloudflare Worker` sebagai API lisensi publik dan endpoint check untuk VPS
- `Cloudflare D1` sebagai source of truth entry lisensi, audit log, dan rate limit bucket
- `Cloudflare Pages` sebagai website publik self-service

## Mode Operasi
- halaman root Pages `/` bersifat publik untuk `aktifkan/perpanjang IP` dan `check status`
- request dari autoscript VPS ke `POST /api/v1/license/check` diputuskan berdasarkan source IP request (`CF-Connecting-IP`), bukan token client
- route `/admin/` tidak dipakai; halaman itu hanya menampilkan info bahwa portal berjalan tanpa admin panel

## Aturan v1
- masa aktif default izin IP adalah `14 hari`
- input IP baru akan membuat entry aktif 14 hari
- input IP yang sama lagi akan memperpanjang masa aktif 14 hari dari `max(now, expires_at)`
- jika IP berstatus `revoked`, aktivasi publik akan ditolak

## Struktur
- `worker/src/index.js`: API Worker publik
- `migrations/`: schema D1
- `pages/index.html`: website publik self-service
- `pages/admin/index.html`: halaman info bahwa admin panel dinonaktifkan
- `pages/public.js` dan `pages/public.css`: frontend publik
- `pages/config.js`: fallback lokal untuk preview static tanpa build GitHub
- `scripts/build-pages.mjs`: generate `dist/config.js` dari env build Cloudflare Pages
- `dist/`: output build Pages untuk deploy GitHub/manual
- `wrangler.toml`: konfigurasi Worker + binding D1

## Endpoint

### Public
- `GET /api/public/config`
- `POST /api/public/license/activate`
- `POST /api/public/license/status`

### Autoscript Client
- `POST /api/v1/license/check`

## Secret dan Vars

### `wrangler.toml`
- `CACHE_TTL_SEC_DEFAULT`
- `PUBLIC_LICENSE_DURATION_DAYS`
- `PUBLIC_UI_ORIGIN`
- `PUBLIC_CREATE_LIMIT_MAX`
- `PUBLIC_CREATE_WINDOW_SEC`
- `PUBLIC_STATUS_LIMIT_MAX`
- `PUBLIC_STATUS_WINDOW_SEC`
- `PUBLIC_RENEW_LIMIT_MAX`
- `PUBLIC_RENEW_WINDOW_SEC`

### Environment Build Pages
- `PAGES_API_BASE_URL`

`PAGES_API_BASE_URL` dipakai saat `npm run build:pages` untuk menghasilkan `dist/config.js`, jadi tidak perlu commit nilai produksi ke [`pages/config.js`](/root/project/autoscript/cloudflare/autoscript-license-portal/pages/config.js).

## Deploy Dengan Connect GitHub
1. Buat D1 database lalu isi `database_id` di [`wrangler.toml`](/root/project/autoscript/cloudflare/autoscript-license-portal/wrangler.toml).
2. Jalankan migrasi:
   - `npm run d1:migrate:remote`
3. Isi vars di [`wrangler.toml`](/root/project/autoscript/cloudflare/autoscript-license-portal/wrangler.toml):
   - `PUBLIC_UI_ORIGIN`
4. Buat project `Pages` via `Connect to Git`, lalu pakai konfigurasi ini:
   - `Production branch`: branch utama repo Anda
   - `Root directory`: `cloudflare/autoscript-license-portal`
   - `Build command`: `npm run build:pages`
   - `Build output directory`: `dist`
5. Tambahkan environment variable di Pages:
   - `PAGES_API_BASE_URL=https://<worker-host>`
6. Buat atau connect project `Worker` ke repo GitHub yang sama dan pastikan name-nya `autoscript`.
7. Isi vars Worker di dashboard Cloudflare agar sesuai dengan [`wrangler.toml`](/root/project/autoscript/cloudflare/autoscript-license-portal/wrangler.toml).

## Deploy Manual Lokal
- Build Pages:
  - `npm run build:pages`
- Deploy Pages:
  - `npm run deploy:pages`
- Deploy Worker:
  - `npm run deploy:worker`

## Alur Publik
1. Pengguna membuka halaman `/`.
2. Pengguna memasukkan `IPv4 VPS`.
3. Worker membuat entry aktif `14 hari` jika IP belum ada.
4. Jika IP sudah ada dan tidak direvoke, Worker memperpanjang masa aktif `14 hari`.
5. Jika pengguna ingin memastikan hasilnya, gunakan form `Check Status`.

## Integrasi Autoscript
Autoscript sekarang bisa memakai URL built-in ini tanpa env manual di VPS:

```bash
export AUTOSCRIPT_LICENSE_DEFAULT_API_URL="https://autoscript.temp10sgt.workers.dev/api/v1/license/check"
```

Di repo ini URL itu sudah ditanam sebagai default bawaan. `run.sh`, `setup.sh`, `manage.sh`, dan runtime enforcer autoscript akan memakai endpoint yang sama dan Worker akan mengecek izin berdasarkan IP sumber request VPS.

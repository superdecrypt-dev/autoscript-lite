# Interactive Test Checklist

## Tujuan

Checklist ini dipakai saat menguji flow operator yang tidak cukup divalidasi oleh test non-interaktif, terutama menu `manage.sh`, installer bot, dan bot Telegram.

## Persiapan

- Jalankan host uji yang sudah selesai provisioning.
- Jika ingin menguji source repo lokal, pakai `RUN_USE_LOCAL_SOURCE=1 bash run.sh`.
- Siapkan satu chat Telegram admin nyata bila area bot ikut diuji.

## 1. CLI `manage.sh`

Jalankan:

```bash
bash manage.sh
```

Verifikasi minimum:
- menu utama tampil tanpa warning fatal
- bisa masuk dan kembali dari menu `1` sampai `13`
- input tidak valid ditolak aman lalu kembali ke menu
- action sensitif tetap meminta konfirmasi bila flow-nya memang destruktif

Flow yang wajib dicoba bila area terkait berubah:
- `1) Xray Users`: create, detail, extend expiry, delete
- `2) SSH Users`: create, reset password, delete
- `4) SSH & OpenVPN QAC`: quota/speed/sync metadata
- `8) Domain Control`: set domain, renew/check cert, refresh `ACCOUNT INFO`
- `11) Maintenance`: status, restart service, lihat log
- `13) Tools`: Telegram Bot, WARP Tier, Backup/Restore

## 2. Installer Bot Telegram

Jalankan:

```bash
bash install-telegram-bot.sh
```

Verifikasi:
- menu installer terbuka normal
- flow konfigurasi `.env` bisa dilalui
- nilai kosong/invalid ditolak dengan aman
- kembali ke menu tidak merusak state installer

## 3. Bot Telegram

Jika bot aktif, uji dari chat admin nyata:
- `/start` atau `/menu` menampilkan menu utama
- navigasi submenu tetap sinkron dengan backend
- callback lama/stale ditolak aman
- action sensitif hanya bisa dipakai admin yang sah
- flow input username/quota/domain/restore upload tetap terkendali

## 4. Backup, Domain, dan Recovery

Untuk perubahan di area kritis, uji manual tambahan:
- backup create, list, restore
- cleanup DNS A record tetap berjalan saat IP VPS sama
- service yang direstart dari maintenance benar-benar kembali aktif
- jika restore atau domain flow gagal, sistem tetap kembali ke kondisi aman

## 5. Catatan Hasil

Catat minimal:
- host/OS yang diuji
- area yang diuji
- langkah yang PASS/FAIL
- error atau output penting yang perlu ditindaklanjuti

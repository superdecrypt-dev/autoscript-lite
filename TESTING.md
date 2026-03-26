# Testing Guide

## Tujuan

Repo `autoscript` mengelola provisioning dan operasi VPS untuk `Xray`, `SSH WS`, `OpenVPN`, `WARP`, `edge-mux`, dan bot `Telegram`. Karena perubahan bisa berdampak langsung ke host produksi, pengujian harus mencakup validasi statis, smoke test, regression test per domain, dan E2E di VPS bersih.

## Level Pengujian

- `Level 0 - Sanity`: syntax check, lint, compile check, dan unit test Go.
- `Level 1 - Component`: validasi komponen yang diubah tanpa flow operator penuh.
- `Level 2 - Non-Interactive Runtime`: install/rerun/health check runtime tanpa interaksi manual.
- `Level 3 - Interactive Operator Flow`: uji menu CLI, installer bot, dan flow Telegram yang dipakai admin.
- `Level 4 - End-to-End VPS Bersih`: install dari nol di host baru, reboot, lalu uji service dan koneksi nyata.
- `Level 5 - Failure & Recovery`: uji skenario gagal dan pemulihan sistem.

## Matriks Level Minimum

| Jenis perubahan | Level minimum |
| --- | --- |
| Dokumentasi saja (`README`, `AGENTS`, `TESTING`) | `Level 0` |
| Perubahan kecil helper shell/Python/Go tanpa ubah flow user | `Level 0-1` |
| Perubahan module Go (`opt/edge/go`, `opt/adblock/go`) | `Level 0-2` |
| Perubahan bot Telegram UI, callback, ACL, atau form input | `Level 0-3` |
| Perubahan menu `manage.sh` atau `opt/manage/` yang user-facing | `Level 0-3` |
| Perubahan `install-telegram-bot.sh` | `Level 0-3` |
| Perubahan `run.sh` atau `setup.sh` | `Level 0-5` |
| Perubahan domain, cert, DNS flow, atau cleanup DNS A record | `Level 0-5` |
| Perubahan network, WARP, SSH Network, routing, atau service runtime | `Level 0-5` |
| Perubahan backup/restore, rollback, atau data mutation penting | `Level 0-5` |

## 1. Validasi Statis

Jalankan ini setelah mengubah script shell, Python, atau Go:

```bash
bash tools/test-noninteractive.sh
go -C opt/edge/go test ./...
go -C opt/adblock/go test ./...
bash bot-telegram/scripts/gate-all.sh
```

`tools/test-noninteractive.sh` adalah baseline cepat untuk menjalankan syntax check shell, compile check Python, gate bot Telegram, dan Go test yang tersedia dengan satu perintah.

## 2. Smoke Test Repo Lokal

Pakai source repo yang sedang diedit:

```bash
RUN_USE_LOCAL_SOURCE=1 bash run.sh
```

Lalu verifikasi:
- `bash manage.sh` menampilkan menu utama tanpa error.
- `bash install-telegram-bot.sh` atau `install-telegram-bot menu` tetap bisa dibuka.
- Jika bot sudah terpasang di host, jalankan `sudo /opt/bot-telegram/scripts/smoke-test.sh`.

Untuk uji manual/operator flow, gunakan checklist di [tools/test-interactive-checklist.md](/root/project/autoscript/tools/test-interactive-checklist.md).

## 3. Regression Test Per Domain

Setelah mengubah area tertentu, uji minimal flow berikut:
- Domain: set domain, renew cert, cleanup DNS A record, refresh `ACCOUNT INFO`.
- Xray/SSH users: create, extend expiry, reset credential/password, delete.
- QAC: quota, speed, block/unblock, IP/login limit.
- OpenVPN: sinkron metadata dengan akun SSH dan QAC.
- WARP dan SSH Network: mode global, per-user, apply runtime.
- Backup/Restore: create backup, list backup, restore, validasi rollback saat gagal.
- Telegram bot: menu render, callback aman, ACL admin, upload restore bila diubah.

## 4. End-to-End di VPS Bersih

Wajib untuk perubahan installer, domain, network, atau runtime service.

Target minimum:
- Ubuntu 20.04 atau 22.04
- Debian 11 atau 12

Checklist:
- Install dari nol.
- Reboot host.
- Pastikan `xray`, `nginx`, `edge-mux`, `sshws`, `openvpn`, dan service bot aktif sesuai fitur yang dipasang.
- Uji koneksi nyata untuk `VLESS/VMess/Trojan`, `SSH WS`, dan `OpenVPN`.
- Jalankan installer lagi untuk cek idempotency.

## 5. Skenario Negatif

Jangan hanya menguji happy path. Coba juga:
- domain tidak resolve
- issue cert gagal
- port bentrok
- env bot tidak lengkap
- backup/restore gagal
- service mati lalu dipulihkan lewat menu maintenance

## 6. Catatan Praktis

- Untuk perubahan user-facing, verifikasi jalur repo lokal dan copy runtime terpasang.
- Jangan hilangkan flow cleanup DNS A record saat IP VPS sama; itu perlu ikut diuji bila menyentuh domain flow.
- Jangan tambahkan verifikasi SHA256 ke flow test kecuali maintainer meminta secara eksplisit.

# Autoscript

> Installer dan panel operasional harian untuk Xray-core di VPS Linux.

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/superdecrypt-dev/autoscript/main/run.sh)
```

Catatan penting:
- Metadata aktif SSH berada di `/opt/quota/ssh/<username>@ssh.json`.
- Host lama yang masih memakai flow lain di luar menu resmi sebaiknya recreate akun dari panel saat upgrade besar.

## Inti Install
- `Xray-core`
- `Edge Gateway` provider `go` sebagai ingress utama `80/443`
- `nginx` backend internal `127.0.0.1:18080`
- `SSH WS`, `SSH SSL/TLS`, dan `SSH Direct`
- `VLESS TCP+TLS` dan `Trojan TCP+TLS` via `Edge Gateway`
- `WARP`, `BadVPN UDPGW`, TLS, dan `xray-domain-guard`
- `manage.sh` untuk operasional harian
- installer bot `Discord` dan `Telegram`

## Protokol
- `VLESS`, `VMess`, `Trojan`
- transport `WS`, `HTTPUpgrade`, `gRPC`, `TCP+TLS` (khusus `VLESS` dan `Trojan`)
- `SSH WS`, `SSH SSL/TLS`, `SSH Direct`

## Port Utama
- publik `80/443`: ditangani `edge-mux` untuk `Xray` dan `SSH`
- `nginx` backend: `127.0.0.1:18080`
- `SSH dropbear`: `127.0.0.1:22022`
- `SSH stunnel`: `127.0.0.1:22443`
- `SSH WS proxy`: `127.0.0.1:10015`
- `BadVPN UDPGW`: `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900`

## Service Utama
- `edge-mux`
- `nginx`
- `xray`
- `sshws-dropbear`
- `sshws-stunnel`
- `sshws-proxy`
- `badvpn-udpgw`
- `xray-domain-guard`

## Catatan Operasional
- Pergantian domain lewat `6) Domain Control > Set Domain` akan me-refresh `XRAY ACCOUNT INFO` dan `SSH ACCOUNT INFO` ke domain baru.
- `SSH QAC` mengatur `quota`, `IP/Login limit`, `speed limit`, dan `expiry` khusus untuk SSH.
- `Recover Pending Txn` di `Xray Users` dan `SSH Users` adalah menu repair untuk journal transaksi yang putus di tengah, bukan menu harian. Jika `pending = 0`, menu itu bisa diabaikan.
- `5) Xray Network > DNS Settings` memakai model `staged changes`, sedangkan `5) Xray Network > DNS Add-ons > Open DNS config with nano` adalah jalur `full replace` untuk perubahan advanced.
- `5) Xray Network > WARP Tier` dapat menampilkan status `unknown/estimasi` saat probe `Cloudflare trace` tidak konklusif walau `wireproxy` tetap sehat.
- `7) Speedtest` memakai CLI Ookla (`speedtest`) jika binary tersedia di host.

## Menu Utama
```text
1) Xray Users
2) SSH Users
3) Xray QAC
4) SSH QAC
5) Xray Network
6) Domain Control
7) Speedtest
8) Security
9) Maintenance
10) Traffic
11) Discord Bot
12) Telegram Bot
13) Adblocker
14) SSH Network
0) Keluar
```

## Fitur CLI Per Menu
- `1) Xray Users`
  Add user, delete user, set expiry, reset `UUID/password`, list users, dan `Recover Pending Txn` untuk journal `add/delete/reset` yang putus di tengah.
- `2) SSH Users`
  Add user, delete user, set expiry, reset password, list users, `SSH WS Status`, `Restart SSH WS`, `Active Sessions`, dan `Recover Pending Txn` untuk journal `add/delete`.
- `3) Xray QAC`
  View JSON, set/reset quota, toggle block, toggle/set/unlock IP limit, set speed download/upload, dan enforcement metadata user Xray.
- `4) SSH QAC`
  View JSON, set/reset quota, toggle block, toggle/set/unlock login limit, set speed download/upload, dan sinkronisasi/enforcement metadata SSH.
- `5) Xray Network`
  `WARP` (`status`, `restart`, `global`, `per-user`, `per-inbound`, `per-domain`, `tier free/plus`), `DNS Settings` staged, `DNS Add-ons` advanced editor, dan `Checks` routing/config/service.
- `6) Domain Control`
  `Set Domain`, `Current Domain`, `Guard Check`, `Guard Renew`, `Refresh Account Info`, `Repair Compat Domain Drift`, dan `Repair Target DNS Record`.
- `7) Speedtest`
  Jalankan speedtest live dan lihat versi binary `speedtest`.
- `8) Security`
  TLS/certificate (`cert info`, `check expiry`, `renew`, `reload nginx`, `recover pending renew`), `Fail2ban`, dan tuning sistem seperti `BBR`, `swap`, `ulimit`, dan `chrony`.
- `9) Maintenance`
  `Core Check`, restart service utama (`xray`, `nginx`, `core`, `WARP`, `SSH WS`, `Edge`, `BadVPN`), log service, status runtime, status daemon Xray, dan `Normalize Quota Dates`.
- `10) Traffic`
  Ringkasan analytics/traffic dan utilitas operasional terkait pemakaian runtime.
- `11) Discord Bot`
  Installer dan wiring bot Discord sebagai pelengkap operasi dari luar CLI host.
- `12) Telegram Bot`
  Installer dan wiring bot Telegram dengan flow menu-first untuk status, account, QAC, domain, network, dan ops.
- `13) Adblocker`
  Source adblock gabungan untuk `Xray` dan `SSH`: enable/disable runtime, manual domain, URL source, bound users, auto update, dan rebuild artifact.
- `14) SSH Network`
  DNS steering user SSH (`dnsmasq` + `nftables`) dan routing `WARP` SSH global/per-user berbasis `fwmark`, `ip rule`, dan `wg-quick`.

## Fitur Installer dan Runtime
- `run.sh`
  Bootstrap host, memilih source lokal atau remote, lalu meneruskan ke `setup.sh`.
- `setup.sh`
  Install/update komponen inti, deploy runtime, sinkronisasi cert/domain, dan menyiapkan service operasional harian.
- `manage`
  Entry point panel CLI untuk operasi harian setelah install selesai.
- `edge-mux`
  Ingress utama `80/443` untuk trafik `Xray` dan `SSH`.
- `xray-domain-guard`
  Guardrail untuk health check domain/TLS dan renew helper.
- `wireproxy` + `wgcf`
  Runtime WARP untuk route global/per-user/per-inbound/per-domain dan tier `free/plus`.
- `BadVPN UDPGW`
  UDPGW lokal untuk kebutuhan payload/game tertentu.

## Flow Live Tervalidasi
- `run.sh` dan `setup.sh` sudah berhasil di-rerun live di host produksi dengan domain aktif baru.
- CRUD `Xray Users` sudah diuji live: `Add`, `List`, `Set Expiry`, `Reset UUID/Password`, `Delete`, dan `Recover Pending Txn`.
- CRUD `SSH Users` sudah diuji live: `Add`, `List`, `Set Expiry`, `Reset Password`, `Delete`, `SSH WS Status`, `Restart SSH WS`, `Active Sessions`, dan `Recover Pending Txn`.
- `Xray QAC` dan `SSH QAC` sudah diuji live untuk flow `view/detail`, `quota`, `block`, `IP/login limit`, `speed limit`, dan `sync/enforcement`.
- `5) Xray Network`, `6) Domain Control`, `7) Speedtest`, `13) Adblocker`, dan `14) SSH Network` sudah disweep live sampai seluruh submenu utama terpilih. Jalur mutasi berisiko tinggi seperti edit DNS full-replace atau ganti domain diuji sampai prompt dan dibatalkan dengan sadar bila tidak dibutuhkan.

## Bot
### Telegram
- Entry point: `/menu`, `/cleanup`, `/start`
- UX sekarang menu-first dengan kategori `Status`, `Accounts`, `QAC`, `Domain`, `Network`, `Ops`
- Action mutasi dikendalikan lewat ACL admin Telegram, bukan lagi flag dangerous terpisah
- Detail: `bot-telegram/README.md`

### Discord
- Entry point utama: `/menu`
- Slash publik ringkas: `/menu`, `/status`, `/notify`
- Flow utama hybrid lewat button, select menu, modal, dan konfirmasi
- Pelengkap CLI, bukan pengganti penuh

## Command Cepat
```bash
bash run.sh
RUN_USE_LOCAL_SOURCE=1 bash run.sh
manage
install-discord-bot
install-telegram-bot
edge-provider-switch go
edge-provider-switch nginx-stream
```

## Dokumen Lanjutan
- `TESTING_PLAYBOOK.md`: SOP pengujian
- `AUDIT_PLAYBOOK.md`: SOP audit dan prioritas review
- `EDGE_PROVIDER_DESIGN.md`: desain teknis Edge Gateway

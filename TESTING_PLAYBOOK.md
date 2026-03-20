# Testing Playbook

Dokumen ini adalah SOP pengujian untuk proyek `autoscript` (baseline konteks: gunakan repo `superdecrypt-dev/autoscript` sebagai source of truth).

## 1. Prinsip Utama
- Wajib uji di `staging` terlebih dulu, baru `production`.
- Jangan lakukan perubahan live tanpa snapshot/rollback plan.
- Jangan commit token/secret; gunakan env file runtime.

## 2. Preflight
Jalankan sebelum semua paket uji:

```bash
AUTO_SCRIPT_ROOT="${AUTO_SCRIPT_ROOT:-/opt/autoscript}"
cd "${AUTO_SCRIPT_ROOT}"

git status --short
bash -n setup.sh manage.sh run.sh install-telegram-bot.sh
shellcheck *.sh \
  opt/setup/core/*.sh \
  opt/setup/install/*.sh \
  opt/setup/bin/xray-domain-guard
find opt/manage -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
find opt/manage -type f -name '*.sh' -print0 | xargs -0 shellcheck -x -S warning
python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')
bash bot-telegram/scripts/gate-all.sh
```

Catatan:
- Top-level `opt/manage/features/*.sh` sekarang aggregator tipis; child module live berada di `opt/manage/features/*/*.sh`, jadi lint/syntax check harus rekursif.

Kriteria lulus:
- Tidak ada syntax error.
- `shellcheck` tidak menghasilkan error kritikal.
- Compile Python sukses.

## 3. Pengujian 4 File Shell

### 3.1 Static & Lint
Sudah tercakup di bagian preflight.

### 3.2 Smoke (menu dasar)

```bash
printf "0\n" | timeout 20 bash manage.sh
printf "1\n0\n0\n" | timeout 30 bash manage.sh
printf "2\n5\n0\n0\n" | timeout 30 bash manage.sh
printf "3\n0\n0\n" | timeout 30 bash manage.sh
printf "4\n0\n0\n" | timeout 30 bash manage.sh
printf "5\n0\n0\n" | timeout 30 bash manage.sh
printf "8\n0\n0\n" | timeout 30 bash manage.sh
printf "10\n0\n0\n" | timeout 30 bash manage.sh
printf "11\n0\n0\n" | timeout 30 bash manage.sh
printf "12\n0\n0\n" | timeout 30 bash manage.sh
printf "13\n2\n0\n0\n" | timeout 30 bash manage.sh
bash install-telegram-bot.sh status
printf "0\n" | timeout 20 bash install-telegram-bot.sh menu
```

Kriteria lulus:
- Menu bisa terbuka dan keluar normal via `0/back`.
- Command `status` berjalan tanpa crash.
- Menu `Xray Users` (`1)`) bisa dibuka dan kembali normal.
- Menu `SSH Users` (`2)`) bisa dibuka, `List Users` tampil aman walau data kosong.
- Menu `Xray QAC` (`3)`) bisa dibuka walau data user masih kosong.
- Menu `SSH QAC` (`4)`) bisa dibuka walau data user masih kosong.
- Menu `Xray Network` (`5)`) dan `Domain Control` (`8)`) bisa dibuka lalu kembali normal tanpa crash.
- `13) Tools > WARP Tier` bisa dibuka dan kembali normal.
- Menu hasil rebalance (`11) Maintenance`, `12) Traffic`, `6) SSH Network`, `7) Adblocker`, `9) Speedtest`, `10) Security`) bisa dibuka lalu kembali normal tanpa crash.

### 3.3 Negative/Failure

Uji root guard:

```bash
setpriv --reuid 65534 --regid 65534 --clear-groups bash run.sh
setpriv --reuid 65534 --regid 65534 --clear-groups bash setup.sh
```

Kriteria lulus:
- Kedua script menolak eksekusi non-root dengan pesan error jelas.

Uji input invalid:

```bash
printf "xyz\n0\n" | timeout 20 bash manage.sh
printf "xyz\n0\n" | timeout 20 bash install-telegram-bot.sh menu
```

Kriteria lulus:
- Input invalid ditangani aman.
- Alur tetap bisa kembali ke menu/keluar.

### 3.4 Integration (staging)
Contoh pola (sesuaikan environment staging):

```bash
systemctl status xray xray-expired xray-quota xray-limit-ip xray-speed --no-pager
xray run -test -confdir /usr/local/etc/xray/conf.d
systemctl status sshws-dropbear sshws-stunnel sshws-proxy sshws-qac-enforcer.timer --no-pager
systemctl status edge-mux --no-pager || true
systemctl status badvpn-udpgw --no-pager || true
systemctl status warp-svc --no-pager || true
```

Kriteria lulus:
- Service utama aktif.
- Konfigurasi Xray valid.
- Service SSH WS aktif (`sshws-dropbear`, `sshws-stunnel`, `sshws-proxy`).
- Timer enforcer `SSH QAC` aktif (`sshws-qac-enforcer.timer`).
- Jika Edge Gateway aktif, `edge-mux` harus `active` dan listener publik tetap ada di `:80/:443`.
- Jika BadVPN dipasang, `badvpn-udpgw` harus `active` dan listen di `127.0.0.1:7300, 7400, 7500, 7600, 7700, 7800, 7900`.
- Jika backend Zero Trust dipasang, `warp-svc` harus terdeteksi; status `inactive` tetap valid selama mode runtime masih `Free/Plus`, tetapi saat mode runtime `Zero Trust` aktif service dan proxy lokalnya harus `active/listening`.

Khusus `SSH Network -> WARP SSH` backend `Local Proxy` (`Free/Plus` / `Zero Trust`):
- Jangan berhenti di status menu `Backend Applied: Local Proxy`; status itu belum membuktikan trafik SSH benar-benar masuk WARP.
- Siapkan 1 akun SSH yang effective `warp`, buka tunnel SOCKS lewat surface publik SSH yang relevan (`SSH Direct :443` direkomendasikan; bila perubahan menyentuh jalur WS, ulangi juga lewat `SSH WS` token path).
- Dalam mode host `Zero Trust`, sumber proxy host yang diuji boleh berasal dari `warp-svc`; bukti lulus tetap harus diambil dari trace tunnel SSH, bukan status host.
- Verifikasi egress dari tunnel dengan:

```bash
curl --max-time 20 \
  --socks5-hostname 127.0.0.1:<local_socks_port> \
  https://www.cloudflare.com/cdn-cgi/trace
```

- Kriteria lulus tambahan:
  - output trace memuat `warp=on`
  - counter `iptables -t mangle -vnL AUTOSCRIPT_SSH_WARP_MARK_V4` atau `ip6tables -t mangle -vnL AUTOSCRIPT_SSH_WARP_MARK_V6` benar-benar naik
  - menu status saja tidak boleh dijadikan bukti lulus

Khusus SSH WS (staging):
- Implementasi target adalah konsep autoscript-stream: tanpa hybrid framing, cukup `Upgrade: websocket`, lalu raw stream.
- Saat audit/review, konsep ini dianggap baseline tetap; referensi konsep perilaku: `https://github.com/nanotechid/supreme`.
- Jalur resmi SSH WS sekarang berbasis token path per-user:
  - `/<token>`
  - `/<bebas>/<token>`
- Siapkan satu akun SSH terkelola lebih dulu, lalu ambil `sshws_token` dari metadata/account info.

Jika Edge Gateway aktif, tambahkan juga cek singkat:

```bash
ss -ltn | rg ':(80|443|18080)\\b'
```

Kriteria lulus tambahan:
- `edge-mux` memegang publik `:80` dan `:443`.
- `nginx` berjalan di backend internal `127.0.0.1:18080`.
- saat provider aktif adalah `Edge Gateway (go)`, `SSH Direct`, `SSH SSL/TLS`, dan `SSH WS` diperlakukan sebagai satu sistem SSH untuk `quota`, `speed limit`, dan `IP/Login limit`.
- jika BadVPN terpasang, `SSH ACCOUNT INFO` harus menampilkan `BadVPN UDPGW : 7300, 7400, 7500, 7600, 7700, 7800, 7900`.

Jika provider `nginx-stream` diuji, tambahkan juga:

```bash
edge-provider-switch nginx-stream
ss -ltn | rg ':(80|443|18080|18443)\\b'
printf 'GET / HTTP/1.1\r\nHost: <domain>\r\n\r\n' | timeout 5 nc 127.0.0.1 80 | sed -n '1,2p'
printf 'GET /deadbeef00 HTTP/1.1\r\nHost: <domain>\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n' | timeout 5 openssl s_client -quiet -connect 127.0.0.1:443 -servername <domain> -alpn http/1.1 2>/dev/null | sed -n '1,2p'
python3 - <<'PY'
import socket, ssl
s = socket.create_connection(("127.0.0.1", 443), timeout=5)
c = ssl.create_default_context().wrap_socket(s, server_hostname="<domain>")
print(c.recv(64).decode("utf-8", "replace").strip())
c.close()
PY
edge-provider-switch go
```

Kriteria lulus tambahan:
- `nginx-stream` memegang publik `:80` dan `:443`.
- `nginx` tetap sehat di `127.0.0.1:18080`.
- backend HTTPS internal aktif di `127.0.0.1:18443`.
- `SSH WS` invalid token tetap `403 Forbidden`.
- `SSH SSL/TLS` tetap memberi banner `dropbear`.
- `SSH Direct` di `80` memberi banner `dropbear`.
- `SSH Direct` di `443` memberi banner `dropbear`.
- restore ke `go` kembali sehat.

```bash
# Handshake check non-TLS root path (curl akan timeout setelah 101 karena tunnel tetap terbuka)
curl -i -N --http1.1 --max-time 5 \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  "http://<domain>/<token>"

# Handshake check TLS prefixed path
curl -k -i -N --http1.1 --max-time 5 \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  "https://<domain>/<bebas>/<token>"

# Negative check: path tanpa token harus 401
curl -k -i --http1.1 --max-time 5 \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  "https://<domain>/"

# Negative check: token tidak valid harus 403
curl -k -i --http1.1 --max-time 5 \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  "https://<domain>/deadbeef00"

# Negative check: backend internal down harus fail-close 502
systemctl stop sshws-dropbear
curl -k -i --http1.1 --max-time 5 \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  "https://<domain>/<token>"
systemctl start sshws-dropbear
```

Kriteria lulus:
- Path token valid `/<token>` dan `/<bebas>/<token>` mengembalikan `101 Switching Protocols`.
- Path tanpa token mengembalikan `401 Unauthorized`.
- Token tidak valid mengembalikan `403 Forbidden`.
- Saat `sshws-dropbear` dimatikan, endpoint SSH WS token-valid mengembalikan `502 Bad Gateway`.
- Path Xray lain tetap berfungsi dan tidak bentrok dengan route SSH WS token-path.
- `SSH Direct` login nyata di `80` dan `443` harus lolos minimal sekali setelah perubahan edge routing.

Khusus runtime bot Telegram (smoke cepat; detail lengkap lihat Bagian 6):

```bash
set -a; . /etc/bot-telegram/bot.env; set +a
systemctl is-active bot-telegram-backend bot-telegram-gateway
/opt/bot-telegram/scripts/smoke-test.sh
curl -fsS --max-time 8 \
  -H "X-Internal-Shared-Secret: ${INTERNAL_SHARED_SECRET}" \
  "http://127.0.0.1:7081/api/main-menu" >/dev/null
```

Kriteria lulus:
- Service Telegram backend/gateway aktif.
- Smoke test Telegram PASS.
- Endpoint main menu backend tetap bisa diakses dengan header secret internal.

## 4. Checklist Rilis
Sebelum promote ke production:

1. Semua preflight PASS.
2. Smoke + negative 4 file shell PASS.
3. Gate bot Telegram (`bash bot-telegram/scripts/gate-all.sh`) PASS.
4. Smoke runtime Telegram (`/opt/bot-telegram/scripts/smoke-test.sh`) PASS.
5. Manual `/menu` Telegram minimal untuk `Status`, `Accounts`, `QAC`, `Domain`, `Network`, `Ops` PASS.
6. Journal baru tidak membocorkan token bot.
7. Bukti uji tersimpan (log/screenshot ringkas).
8. Snapshot rollback tersedia.

## 5. Pengujian Bot Telegram

Gunakan harness resmi:

```bash
bash bot-telegram/scripts/gate-all.sh
```

Tambahkan smoke runtime:

```bash
set -a; . /etc/bot-telegram/bot.env; set +a
systemctl is-active bot-telegram-backend bot-telegram-gateway bot-telegram-monitor.timer
/opt/bot-telegram/scripts/smoke-test.sh
curl -fsS --max-time 8 \
  -H "X-Internal-Shared-Secret: ${INTERNAL_SHARED_SECRET}" \
  "http://127.0.0.1:7081/api/main-menu" >/dev/null
```

Catatan:
- Endpoint `/health` backend Telegram wajib header secret internal.
- Action mutasi dikendalikan lewat ACL admin Telegram, bukan lagi flag dangerous terpisah.
- Action menu network tetap perlu diuji untuk regresi WARP parity.

### 6.1 Gate Wajib
1. Jalankan `bash bot-telegram/scripts/gate-all.sh`.
2. Jalankan smoke runtime lokal:
   - backend/gateway/timer aktif
   - `/opt/bot-telegram/scripts/smoke-test.sh`
   - `curl` ke `/api/main-menu` dengan header secret internal
3. Verifikasi env aman:
   - `TELEGRAM_ADMIN_USER_IDS` atau `TELEGRAM_ADMIN_CHAT_IDS` terisi sesuai target
   - `TELEGRAM_ALLOW_UNRESTRICTED_ACCESS=false` kecuali memang sedang uji bypass ACL
4. Verifikasi ACL perilaku:
   - kirim `/menu` dari akun admin -> harus diterima
   - kirim `/menu` dari akun/chat yang tidak di-whitelist -> harus ditolak
5. Verifikasi log baru gateway tidak membocorkan token:

```bash
journalctl -u bot-telegram-gateway --since "10 minutes ago" --no-pager | \
  rg -n 'api\\.telegram\\.org/bot[0-9]+:'
```

Ekspektasi:
- command di atas tidak mengembalikan match.
- akun/chat non-whitelist tidak bisa masuk panel.

### 6.2 E2E Manual Telegram (staging)
1. Jalankan `/menu`.
2. Pastikan keyboard menu utama tampil penuh dan tidak ada button yang mati/error.
3. Uji kategori inti berikut:
   - `Status`
   - `Accounts`
   - `QAC`
   - `Domain`
   - `Network`
   - `Ops`
4. Uji minimal satu action aman-berubah dari `Accounts`, `QAC`, `Domain`, atau `Ops`, lalu rollback hasilnya.
5. Jalankan `/cleanup`.
6. Pastikan output tidak membocorkan token, shared secret, atau secret sensitif lain.

### 6.3 Checklist Manual /menu (Rekomendasi Terbaru)
Gunakan checklist ini saat regresi menu Telegram:

1. Status
- `Overview`
- `Run Xray Test`
- `View TLS Info`

2. Accounts
- `Xray Users -> View Account Info`
- `Xray Users -> Delete User`
- `SSH Users -> View Account Info`
- `SSH Users -> Extend Expiry`
- `SSH Users -> Reset Password`

3. QAC
- `Xray QAC -> pilih user -> Detail`
- `Xray QAC -> pilih user -> Set Quota`
- `SSH QAC -> pilih user -> Detail`
- `SSH QAC -> pilih user -> Set Quota`

4. Domain
- `View Domain Info`
- `TLS Certificate Info`
- `Set Domain Manual`
- `Set Domain Auto` (pilih root domain saja)
- `Refresh Accounts`
- `Renew Cert`

5. Network
- `Adblock Status`
- `DNS Summary`
- `Domain Guard Status`
- `Domain Guard Check`
- `Xray Network -> WARP Global`: stage perubahan, ubah `30-routing.json` dari shell terpisah, lalu coba apply staged. Ekspektasi: apply ditolak karena live berubah sejak staging dibuat.
- `Xray Network -> WARP Global` setelah stale conflict: submenu tetap terbuka agar operator bisa `discard` atau stage ulang, bukan terpental ke parent menu.
- `Xray Network -> DNS Settings`: korupkan sementara `02-dns.json`, buka menu, pastikan tampil `Parser state: INVALID JSON` dan menu per-field menolak staging sampai file valid lagi.
- `Xray Network -> WARP Per User / Per Inbound`: saat `10-inbounds.json` atau `30-routing.json` invalid, menu harus warn invalid JSON, bukan menampilkan list kosong.
- `Xray Network -> WARP Status`: verifikasi layar menampilkan `WARP Global`, jumlah override, dan `Conflict` selain status `wireproxy`.
- `Xray Network -> WARP Per User / Per Inbound`: bila 1 entity sengaja dimasukkan ke marker `direct` dan `warp` sekaligus, status menu harus tampil `conflict`.
- `SSH Network -> Routing SSH Global -> Save WARP Backend (config only)` lalu `Apply Routing Runtime`
- `SSH Network -> WARP SSH Per-User -> Enable WARP for User`
- `SSH Network -> WARP SSH Per-User -> Reset User to Inherit` lalu verifikasi runtime dibersihkan sesuai backend target (`Local Proxy`: redirect/counter turun, `Dedicated Interface`: `wg-quick@<iface>` kembali `inactive`)
- `SSH Network -> WARP SSH Global -> Enable WARP Global`
- `SSH Network -> WARP SSH Global -> Disable WARP Global`
- `systemctl restart ssh-network-restore.service` lalu verifikasi `Result=success`

6. Ops
- `View Ops Status`
- `Run Speedtest`
- `Traffic Overview`
- `Restart Service`
- `List Backups`

### 6.4 Kriteria Lulus Telegram
- Semua action mengembalikan schema `ok/code/title/message`.
- Tidak ada `unknown_action`.
- Tidak ada crash service `bot-telegram-backend` dan `bot-telegram-gateway`.
- ACL admin berjalan sesuai env (`TELEGRAM_ADMIN_*`).
- Akun/chat non-whitelist ditolak konsisten.
- Navigasi `Back`/`Cancel` menjaga konteks picker dan halaman saat kembali.
- Journal baru gateway tidak lagi menulis URL Telegram yang mengandung token.

## 7. Format Laporan Singkat
Gunakan format ini setelah pengujian:

```text
Tanggal:
Environment: staging / production
Commit:

Shell:
- Static/Lint: PASS/FAIL
- Smoke: PASS/FAIL
- Negative: PASS/FAIL
- Integration: PASS/FAIL

Bot Telegram:
- Gate all: PASS/FAIL
- Smoke runtime: PASS/FAIL
- ACL whitelist/non-whitelist: PASS/FAIL
- Manual `/menu` core categories: PASS/FAIL
- Log hygiene: PASS/FAIL

Catatan risiko:
Keputusan lanjut:
```

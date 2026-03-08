# Edge Gateway Design

## Tujuan

Dokumen ini mendefinisikan desain teknis untuk mendukung:

- `SSH WS`
- `SSH SSL/TLS`
- route HTTP/Xray yang sudah ada

berjalan pada:

- `1 domain`
- port publik yang sama: `80` dan `443`

dengan tiga opsi provider edge:

1. `go` custom edge proxy
2. `haproxy`
3. `nginx-stream`

Hanya **satu provider** yang aktif pada satu waktu.

## Ringkasan Keputusan

- `go` menjadi provider utama.
- `haproxy` menjadi fallback production-grade.
- `nginx-stream` tetap didukung, tetapi statusnya **experimental/limited** untuk skenario `1 domain + shared 80/443`.
- Provider `go` dipasang sebagai **binary prebuilt**, bukan compile di VPS saat setup normal.
- `nginx` tidak lagi memegang listener publik `80/443` jika edge provider aktif.
- `nginx` dipindahkan ke backend internal, misalnya `127.0.0.1:18080`.
- rollback operasional singkat dicatat di [EDGE_ROLLBACK.md](/root/project/autoscript/EDGE_ROLLBACK.md).

## Scope

### In scope

- Multiplex `SSH WS` dan `SSH SSL/TLS` pada domain yang sama.
- Shared public port `80` dan `443`.
- Provider abstraction `go|haproxy|nginx-stream`.
- Installer modular untuk provider edge.
- Runtime/service management untuk edge aktif.

### Out of scope

- Quota/speed/IP limit untuk jalur `SSH SSL/TLS`.
- Migrasi bot Discord/Telegram ke surface edge baru.
- Kompatibilitas penuh semua client exotic tanpa validasi bertahap.

## Baseline Saat Ini

Arsitektur aktif saat ini:

- `nginx` publik di `:80/:443`
- `sshws-proxy` internal
- `dropbear` internal
- `xray` diroute di belakang `nginx`

Arsitektur lama ini sudah cocok untuk `SSH WS`, tetapi belum cukup untuk:

- `SSH WS`
- `SSH SSL/TLS`
- satu domain
- shared `80/443`

karena trafik klasik TLS dan trafik HTTP/WebSocket sama-sama ingin masuk lewat port yang sama.

## Prinsip Arsitektur Baru

### 1. Edge Gateway menjadi pintu publik tunggal

Jika edge provider aktif, maka:

- edge provider bind ke `0.0.0.0:80`
- edge provider bind ke `0.0.0.0:443`

Lalu edge provider memutuskan trafik masuk ke backend yang benar.

### 2. Nginx pindah ke backend internal

`nginx` tidak lagi memegang port publik.

Target backend default:

- `nginx-http`: `127.0.0.1:18080`

Route yang tetap dilayani `nginx-http`:

- `SSH WS`
- Xray WS/HUP/gRPC/HTTP route yang sudah ada
- halaman default/status lain yang sudah ada di layer HTTP

### 3. SSH klasik menjadi backend internal terpisah

Backend default:

- `ssh-classic`: `127.0.0.1:22022`

Jalur ini menerima stream SSH mentah setelah TLS di-terminate oleh edge.

Artinya:

- edge provider yang menangani TLS publik
- backend SSH klasik menerima stream plaintext internal

Ini ekuivalen secara fungsi dengan model `stunnel -> dropbear`, tetapi terminasi TLS dipindah ke edge provider.

## Routing Model

### Port 80

Provider edge menerima semua trafik publik di `:80`.

### Deteksi awal

- Jika byte awal adalah HTTP plaintext:
  - route ke `nginx-http`
- Jika byte awal adalah TLS ClientHello:
  - lanjut ke jalur `SSH SSL/TLS`

### Hasil

- `SSH WS` non-TLS / HTTP WS tetap bisa hidup di `:80`
- `SSH SSL/TLS` tetap bisa hidup di `:80` sebagai compatibility mode

Catatan:

- TLS di port `80` bukan mode standar web biasa, tetapi tetap mungkin untuk workflow injector.

### Port 443

Provider edge menerima semua trafik publik di `:443`.

### Langkah routing

1. terminate TLS dengan sertifikat domain aktif dari `/opt/cert`
2. baca data aplikasi pertama dengan timeout pendek
3. jika terlihat HTTP request:
   - route ke `nginx-http`
4. jika tidak ada request HTTP cepat atau datanya bukan HTTP:
   - route ke `ssh-classic`

### Kenapa ini bekerja

- `SSH WS/WSS` biasanya segera mengirim `GET /... HTTP/1.1`
- `SSH klasik` biasanya menunggu banner server, jadi tidak langsung mengirim request HTTP

Timeout awal yang disarankan:

- `EDGE_HTTP_DETECT_TIMEOUT_MS=250`

## Provider Matrix

| Provider | Status | Cocok untuk 1 domain + shared 80/443 | Catatan |
|---|---|---:|---|
| `go` | utama | ya | paling fleksibel dan paling sesuai untuk logic sniffing proyek ini |
| `haproxy` | fallback | ya | feasible, tapi config lebih kompleks |
| `nginx-stream` | experimental | terbatas | paling lemah untuk klasifikasi post-TLS pada domain/port yang sama |

## Provider `go`

### Peran

Custom binary `edge-mux` bertugas:

- bind `:80/:443`
- terminate TLS
- deteksi HTTP vs non-HTTP
- proxy ke backend yang sesuai

### Kenapa `go`

- cocok untuk koneksi long-lived
- binary tunggal
- tidak butuh runtime Python untuk edge paling depan
- lebih aman untuk backpressure dan copy stream
- lebih mudah dijadikan provider utama jangka panjang

### Deploy model

Provider `go` memakai **prebuilt binary**.

Default deploy:

- `linux-amd64`
- `linux-arm64`

Sumber binary:

1. release asset resmi repo
2. fallback lokal saat `RUN_USE_LOCAL_SOURCE=1`

Build on host hanya untuk mode dev eksplisit, misalnya:

- `EDGE_BUILD_LOCAL=1`

dan **bukan** jalur setup normal.

## Provider `haproxy`

### Peran

Fallback production-grade saat operator tidak ingin memakai binary custom.

### Catatan desain

- tetap menjadi provider edge publik tunggal
- tetap perlu memindahkan `nginx` ke backend internal
- tetap memerlukan klasifikasi:
  - HTTP plaintext vs TLS di `:80`
  - HTTP-over-TLS vs SSH klasik di `:443`

### Posisi

- layak sebagai fallback
- tidak menjadi default karena complexity-to-control ratio lebih buruk dibanding provider `go` untuk requirement proyek ini

## Provider `nginx-stream`

### Peran

Provider kompatibilitas minimal.

### Batasan

`nginx-stream` tidak ideal untuk kebutuhan:

- satu domain
- shared `443`
- klasifikasi post-TLS antara HTTP/WebSocket vs SSH klasik

Karena itu statusnya:

- `experimental`

Kita tetap bisa menyiapkan template dan flow install, tetapi provider ini tidak boleh dipromosikan sebagai mode utama untuk target requirement ini.

## Layout Repo Yang Disarankan

```text
opt/edge/
  README.md
  go/
    cmd/
      edge-mux/
        main.go
    internal/
      detect/
      proxy/
      tlsmux/
      runtime/
  dist/
    edge-mux-linux-amd64
    edge-mux-linux-arm64
    SHA256SUMS

opt/setup/install/
  edge.sh

opt/setup/templates/
  config/
    edge-runtime.env
  systemd/
    edge-mux.service
  haproxy/
    haproxy.cfg
  nginx/
    stream-edge.conf
```

## Runtime Ports

Default mapping yang disarankan:

- public:
  - `:80` -> edge provider
  - `:443` -> edge provider
- internal:
  - `127.0.0.1:18080` -> `nginx-http`
  - `127.0.0.1:22022` -> `ssh-classic`

Jika nanti perlu dipisah lebih jauh:

- `sshws-proxy` tetap internal seperti saat ini
- `xray` tetap di belakang `nginx-http`

## Environment Yang Disarankan

```bash
EDGE_PROVIDER=go
EDGE_PUBLIC_HTTP_PORT=80
EDGE_PUBLIC_TLS_PORT=443
EDGE_NGINX_HTTP_BACKEND=127.0.0.1:18080
EDGE_SSH_CLASSIC_BACKEND=127.0.0.1:22022
EDGE_HTTP_DETECT_TIMEOUT_MS=250
EDGE_CLASSIC_TLS_ON_80=true
```

## Dampak Ke Komponen Yang Sudah Ada

### Nginx

- listener publik `80/443` harus dipindah
- mode baru: backend internal HTTP router

### SSH WS

- tetap berjalan melalui route HTTP/WebSocket di `nginx-http`
- tidak perlu diubah menjadi provider edge
- QAC SSH WS tetap berada di jalur existing

### SSH SSL/TLS

- menjadi jalur backend internal raw SSH
- TLS publik diakhiri oleh edge provider

### QAC

QAC SSH WS yang sekarang ada **tidak otomatis berlaku** untuk jalur `SSH SSL/TLS`.

Kalau nanti jalur klasik juga ingin punya:

- quota
- speed limit
- IP/login limit

maka harus dibuat desain enforcement terpisah.

## Install Flow Yang Disarankan

1. pilih `EDGE_PROVIDER`
2. install provider aktif
3. render config runtime edge
4. pindahkan `nginx` ke backend internal
5. pasang unit systemd edge
6. restart edge provider
7. validasi:
   - `nginx -t`
   - `systemctl is-active edge`
   - `101` untuk SSH WS
   - handshake TLS klasik ke backend SSH

## Menu CLI Yang Layak Ditambah Nanti

Tidak wajib untuk fase desain, tetapi sebaiknya dipersiapkan:

- `Maintenance > Edge Gateway Status`
- `Maintenance > Restart Edge Gateway`
- `Maintenance > Edge Gateway Info`

## Fase Implementasi

### Fase 1

- dokumen desain teknis
- belum mengubah runtime

### Fase 2

- scaffold repo:
  - `opt/edge/`
  - `opt/setup/install/edge.sh`
  - template systemd/config provider

### Fase 3

- implement provider `go`
- jadikan sebagai default

### Fase 4

- template/provider `haproxy`
- parity basic terhadap provider `go`

### Fase 5

- template/provider `nginx-stream`
- tandai sebagai experimental

### Fase 6

- CLI status/restart edge
- testing dan audit playbook tambahan

## Testing Strategy

Minimum test untuk provider aktif:

1. `HTTP` di `:80` tetap masuk ke `nginx-http`
2. `SSH WS` plaintext di `:80` tetap `101`
3. `TLS klasik` di `:80` masuk ke backend SSH
4. `WSS` di `:443` tetap `101`
5. `SSH klasik TLS` di `:443` masuk ke backend SSH
6. jalur Xray existing tidak regress
7. `nginx` backend internal tetap sehat

## Keputusan Final Desain

- proyek ini mendukung tiga provider edge
- hanya satu provider aktif pada satu waktu
- `go` menjadi provider utama
- deploy `go` memakai **binary prebuilt**
- `haproxy` menjadi fallback
- `nginx-stream` tetap tersedia tetapi tidak menjadi default untuk requirement ini

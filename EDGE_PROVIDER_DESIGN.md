# Edge Gateway Design

## Tujuan

Dokumen ini mendefinisikan desain teknis untuk mendukung:

- `SSH WS`
- `SSH SSL/TLS`
- route HTTP/Xray yang sudah ada

berjalan pada:

- `1 domain`
- port publik yang sama: `80` dan `443`

dengan dua opsi provider edge:

1. `go` custom edge proxy
2. `nginx-stream`

Hanya **satu provider** yang memegang port publik `80/443` pada satu waktu.

## Ringkasan Keputusan

- `go` menjadi provider utama.
- topologi operasional yang direkomendasikan adalah:
  - `go` aktif di publik `80/443`
  - `nginx` backend internal di `127.0.0.1:18080`
- `nginx-stream` tetap didukung, tetapi statusnya **experimental/limited** untuk skenario `1 domain + shared 80/443`.
- `nginx-stream` saat ini sudah diimplementasikan dan tervalidasi:
  - uji high-port
  - cutover live
  tetapi tetap tidak menjadi default.
- Provider `go` dipasang sebagai **binary prebuilt**, bukan compile di VPS saat setup normal.
- `nginx` tidak lagi memegang listener publik `80/443` jika edge provider aktif.
- `nginx` dipindahkan ke backend internal, misalnya `127.0.0.1:18080`.
- recovery operasional singkat dicatat di [EDGE_RECOVERY.md](/root/project/autoscript/EDGE_RECOVERY.md).

## Scope

### In scope

- Multiplex `SSH WS` dan `SSH SSL/TLS` pada domain yang sama.
- Shared public port `80` dan `443`.
- Provider abstraction `go|nginx-stream`.
- Installer modular untuk provider edge.
- Runtime/service management untuk edge aktif.

### Out of scope

- Quota/speed/IP limit untuk jalur `SSH SSL/TLS`.
- Migrasi bot Discord/Telegram ke surface edge baru.
- Kompatibilitas penuh semua client exotic tanpa validasi bertahap.

## Baseline Saat Ini

Arsitektur aktif saat ini:

- `edge-mux` aktif di publik `:80/:443`
- `nginx` backend internal di `127.0.0.1:18080`
- `dropbear` internal di `127.0.0.1:22022`
- `stunnel` internal di `127.0.0.1:22443`
- `sshws-proxy` internal di `127.0.0.1:10015`

Topologi ini sudah membuktikan:

- `SSH WS`
- `SSH SSL/TLS`
- satu domain
- shared `80/443`

dapat hidup bersama lewat satu edge aktif dan backend internal yang terpisah.

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
| `nginx-stream` | experimental | terbatas | sudah diimplementasikan dan tervalidasi, tetapi tetap paling lemah untuk klasifikasi post-TLS pada domain/port yang sama |

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

Provider ini sekarang sudah memiliki:

- template runtime
- flow install
- validasi high-port
- cutover live dan restore kembali ke provider `go`

Namun provider ini tetap tidak boleh dipromosikan sebagai mode utama untuk target requirement ini.

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

opt/setup/install/
  edge.sh

opt/setup/templates/
  config/
    edge-runtime.env
  systemd/
    edge-mux.service
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

Saat provider aktif adalah `Edge Gateway (go)`, enforcement SSH sekarang berlaku lintas surface edge:

- `SSH WS`
- `SSH SSL/TLS`
- `SSH Direct`

Yang sudah berlaku lintas surface:

- quota
- speed limit
- IP/login limit

Yang tetap di luar scope traffic enforcement:

- `sshd:22` native
- provider fallback yang tidak memakai jalur runtime `Edge Gateway (go)` aktif

## Ekstensi OpenVPN di Atas Edge

### Tujuan

Topologi edge ini dirancang agar nantinya dapat menampung:

- `OpenVPN TCP`
- `OpenVPN SSL/TLS`
- `OpenVPN WS`

tetap dengan target operasional:

- `1 domain`
- shared public port `80` dan `443`

### Definisi Istilah

Dalam repo ini:

- `OpenVPN TCP`
  - OpenVPN berjalan sebagai backend TCP internal biasa
- `OpenVPN SSL/TLS`
  - OpenVPN TCP dibungkus TLS publik di edge, analog dengan model `SSH SSL/TLS`
  - ini **bukan** mode native TLS internal OpenVPN yang berdiri sendiri di port publik
- `OpenVPN WS`
  - OpenVPN TCP dibungkus jalur WebSocket internal, analog dengan model `SSH WS`

### Ringkasan Keputusan

- Core backend OpenVPN hanya satu:
  - `openvpn-tcp`
- Tiga surface publik akan diarahkan ke core backend yang sama:
  - `OpenVPN TCP` -> `edge-mux` -> `openvpn-tcp`
  - `OpenVPN SSL/TLS` -> `edge-mux` -> `openvpn-tcp`
  - `OpenVPN WS` -> `edge-mux` -> `nginx` -> `ovpnws-proxy` -> `openvpn-tcp`
- `nginx` hanya dipakai untuk jalur HTTP/WebSocket.
- Keputusan raw TCP/TLS tetap dilakukan di `edge-mux`.
- `UDP` tetap out of scope untuk fase ini.

### Topologi Yang Disarankan

```text
public :80/:443
  -> edge-mux
      -> nginx-http        127.0.0.1:18080
      -> ssh-classic       127.0.0.1:22022
      -> openvpn-tcp       127.0.0.1:21194

nginx-http
  -> existing Xray HTTP family
  -> existing SSH WS routes
  -> /<token>            -> token WS router -> sshws/ovpnws proxy
  -> /<bebas>/<token>    -> token WS router -> sshws/ovpnws proxy
```

### Runtime Ports Tambahan

Default mapping OpenVPN yang disarankan:

- internal:
  - `127.0.0.1:21194` -> `openvpn-tcp`
  - `127.0.0.1:21195` -> `ovpnws-proxy`

### Routing Model OpenVPN

#### OpenVPN WS

Jalur ini mengikuti konsep `sshws-proxy`.

Flow:

1. client masuk ke `:80` atau `:443`
2. `edge-mux` mendeteksi trafik HTTP/WebSocket
3. route ke `nginx-http`
4. `nginx` meneruskan path OpenVPN WS ke `ovpnws-proxy`
5. `ovpnws-proxy` melakukan handshake WebSocket
6. setelah handshake selesai, `ovpnws-proxy` menjembatani raw stream ke `openvpn-tcp`

Path default yang disarankan:

- `/<token>`
- `/<bebas>/<token>`

`token` WS OpenVPN dibuat per-client dan disimpan di metadata client OpenVPN.
Autentikasi utama tetap dilakukan oleh OpenVPN pada layer backend.
Path berfungsi sebagai selector route ringan, sedangkan pembeda backend WS dilakukan oleh header wrapper `X-OVPN-WS: 1`.

#### OpenVPN TCP

Flow:

1. client masuk ke `:80` atau `:443`
2. `edge-mux` membaca payload awal non-HTTP
3. jika payload cocok dengan signature OpenVPN TCP, route ke `openvpn-tcp`
4. jika tidak cocok, lanjut ke classifier lain seperti `SSH`

Requirement penting:

- detector OpenVPN harus **strict**
- jangan menjadikan semua raw TCP non-HTTP sebagai OpenVPN

#### OpenVPN SSL/TLS

Flow yang diinginkan repo ini:

1. client masuk ke `:443`
2. `edge-mux` terminate TLS publik domain
3. `edge-mux` membaca payload awal setelah TLS dibuka
4. jika payload cocok dengan signature OpenVPN, route ke `openvpn-tcp`
5. jika tidak cocok dan terlihat HTTP-family, route ke `nginx-http`
6. jika tidak cocok dan terlihat SSH-family, route ke `ssh-classic`

Ini membuat model `OpenVPN SSL/TLS` menjadi setara secara topologi dengan `SSH SSL/TLS`.

### Peran Komponen

#### edge-mux

Tanggung jawab baru:

- tambah backend internal OpenVPN
- tambah classifier:
  - `openvpn-tcp`
  - `openvpn-ssl`
- tambah metrics route decision untuk surface OpenVPN
- tambah observability agar `Maintenance > Edge Gateway Status` bisa menampilkan counter OpenVPN

#### nginx

Tanggung jawab baru:

- tambah route HTTP/WebSocket untuk `OpenVPN WS`
- tidak menangani `OpenVPN TCP` atau `OpenVPN SSL/TLS` langsung

#### ovpnws-proxy

Komponen baru dengan konsep seperti `sshws-proxy`.

Tanggung jawab:

- listen lokal, misalnya `127.0.0.1:21195`
- validasi handshake `Upgrade: websocket`
- bridge raw stream ke `openvpn-tcp`
- beri fail-close yang jelas jika backend OpenVPN down

Implementasi awal yang disarankan:

- Python
- gaya service dan operasional mirip `sshws-proxy`

### Environment Tambahan Yang Disarankan

```bash
EDGE_OVPN_TCP_BACKEND=127.0.0.1:21194
OVPN_TCP_PORT=21194
OVPNWS_PROXY_PORT=21195
OVPNWS_PATH=/
OVPNWS_HANDSHAKE_TIMEOUT=10
OVPN_ENABLE_TCP=true
OVPN_ENABLE_SSL=true
OVPN_ENABLE_WS=true
```

Catatan:

- `EDGE_NGINX_HTTP_BACKEND` tetap dipakai untuk route HTTP-family
- backend OpenVPN tidak melewati `nginx`, kecuali surface `WS`

### Layout Repo Tambahan Yang Disarankan

```text
opt/setup/install/
  openvpn.sh

opt/setup/bin/
  ovpnws-proxy.py

opt/setup/templates/
  config/
    openvpn-runtime.env
    openvpn/
      server-tcp.conf
  systemd/
    ovpn-tcp.service
    ovpnws-proxy.service
```

### Nama Service Yang Disarankan

- `ovpn-tcp`
- `ovpnws-proxy`

### Dampak Tambahan Ke Komponen Yang Sudah Ada

#### Edge Gateway

- classifier `HTTP vs SSH` tidak lagi cukup
- perlu menjadi:
  - `HTTP-family`
  - `OpenVPN-family`
  - `SSH-family`

#### Nginx

- tambah satu lokasi route baru untuk `OpenVPN WS`
- tidak mengubah route Xray/SSH WS yang sudah ada

#### CLI / Bot

Fase awal tidak wajib menyentuh bot.

Prioritas CLI:

- `Maintenance > Edge Gateway Status`
- `Status` summary untuk service `ovpn-tcp` dan `ovpnws-proxy`

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

- template/provider `nginx-stream`
- tandai sebagai experimental

### Fase 5

- CLI status/restart edge
- testing dan audit playbook tambahan

### Fase 6

- scaffold OpenVPN:
  - `openvpn.sh`
  - `ovpnws-proxy.py`
  - template runtime/config/unit

### Fase 7

- implement backend OpenVPN di `edge-mux`
- tambah route `nginx` untuk `OpenVPN WS`
- staging E2E untuk `OpenVPN TCP`, `OpenVPN SSL/TLS`, `OpenVPN WS`

## Testing Strategy

Minimum test untuk provider aktif:

1. `HTTP` di `:80` tetap masuk ke `nginx-http`
2. `SSH WS` plaintext di `:80` tetap `101`
3. `TLS klasik` di `:80` masuk ke backend SSH
4. `WSS` di `:443` tetap `101`
5. `SSH klasik TLS` di `:443` masuk ke backend SSH
6. jalur Xray existing tidak regress
7. `nginx` backend internal tetap sehat
8. helper `edge-provider-switch go` harus mengembalikan topologi utama jika provider lain pernah diaktifkan

Tambahan minimum test saat OpenVPN mulai diaktifkan:

1. `OpenVPN TCP` valid route ke backend OpenVPN
2. `OpenVPN SSL/TLS` valid route ke backend OpenVPN
3. `OpenVPN WS` valid `101 Switching Protocols`
4. route SSH existing tidak regress
5. route Xray existing tidak regress
6. `nginx` hanya menyentuh jalur `OpenVPN WS`
7. jika `ovpn-tcp` down:
   - `OpenVPN TCP` fail-close
   - `OpenVPN SSL/TLS` fail-close
   - `OpenVPN WS` fail-close via `502`

## Keputusan Final Desain

- proyek ini mendukung dua provider edge
- hanya satu provider yang memegang `80/443` pada satu waktu
- `go` menjadi provider utama
- deploy `go` memakai **binary prebuilt**
- `nginx-stream` tetap tersedia tetapi tidak menjadi default untuk requirement ini
- topologi ini juga menjadi basis perluasan `OpenVPN TCP`, `OpenVPN SSL/TLS`, dan `OpenVPN WS`

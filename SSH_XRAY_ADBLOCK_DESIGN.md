# SSH + Xray Adblock Design

## Tujuan

Menambahkan adblock untuk dua jalur yang berbeda sifatnya:

- `Xray`: adblock berbasis routing domain yang memang sudah natural di core Xray.
- `SSH`: adblock berbasis DNS/egrss untuk trafik yang keluar dari sesi SSH.

Dokumen ini sengaja memisahkan dua jalur tersebut karena mekanismenya tidak sama.

## Ringkasan Keputusan

### Xray

Tetap memakai model yang sudah cocok dengan repo ini:

- asset geosite: `ext:custom.dat:adblock`
- rule routing domain
- outbound `blocked`

Ini adalah bentuk adblock yang paling bersih untuk Xray.

### SSH

Jangan mencoba memasang adblock di:

- `edge-mux`
- `sshws-proxy`
- `dropbear`
- `stunnel`

Karena komponen itu hanya melihat transport SSH, bukan domain tujuan user.

Untuk SSH, adblock yang realistis adalah:

- resolver lokal dengan blocklist
- redirect DNS keluar dari sesi SSH ke resolver lokal
- enforcement memakai `nftables` berdasarkan UID user SSH

## Kenapa Xray dan SSH Berbeda

### Xray

Xray punya:

- routing rule
- match domain
- outbound `blocked`
- asset geosite `custom.dat`

Jadi adblock bisa bekerja langsung pada layer aplikasi/proxy.

### SSH

SSH di repo ini hanya menyediakan tunnel:

- `SSH Direct`
- `SSH SSL/TLS`
- `SSH WS`

Server tidak tahu domain tujuan secara native dari aliran SSH. Setelah tunnel terbentuk, yang terlihat hanyalah koneksi keluar biasa dari proses sesi SSH.

Akibatnya, kalau ingin adblock di sisi SSH, layer yang paling masuk akal adalah:

- DNS
- optional egress filtering

Bukan ingress SSH.

## Desain Teknis

## Bagian A - Xray Adblock

### Model

- user mengaktifkan `5) Network > Adblock`
- menu menulis rule ke routing Xray
- domain yang match `ext:custom.dat:adblock` diarahkan ke outbound `blocked`

### State yang dipakai

- asset: `${XRAY_ASSET_DIR}/custom.dat`
- entry: `ext:custom.dat:adblock`
- outbound target: `blocked`

### Nilai tambah

- ringan
- mudah dijelaskan
- sesuai arsitektur repo
- tidak perlu komponen baru

### Pengembangan yang layak

Setelah fitur dasar ini stabil, pengembangan yang masih masuk akal:

- whitelist domain
- mode per-user atau per-inbound
- status asset/blocklist yang lebih jelas di menu
- update blocklist manual dari CLI

## Bagian B - SSH Adblock

### Model utama

Tambahkan resolver lokal khusus adblock:

- `dnsmasq` lokal pada `127.0.0.1:5353`

Lalu redirect DNS dari sesi SSH ke resolver tersebut menggunakan `nftables`.

### Kenapa `dnsmasq`

Alasan memilih `dnsmasq` untuk repo ini:

- ringan
- sederhana
- mudah di-manage dari shell/systemd
- cukup untuk sinkhole domain
- cocok dengan repo yang sudah banyak memakai shell + systemd + `nftables`

### Jalur enforcement

1. sesi SSH berjalan sebagai user Linux biasa
2. trafik DNS yang keluar dari user tersebut dicocokkan via `meta skuid`
3. request UDP/TCP port `53` di-redirect ke `127.0.0.1:5353`
4. `dnsmasq` menjawab:
   - `NXDOMAIN`
   - atau sinkhole local address

### Rule yang disarankan

Di `nftables`, fokus pada chain `output` untuk trafik lokal yang dibuat oleh proses SSH user.

Jenis match yang paling relevan:

- `meta skuid`
- `udp dport 53`
- `tcp dport 53`

Contoh konsep, bukan final syntax:

```text
table inet autoscript_ssh_adblock {
  chain output {
    type nat hook output priority dstnat;
    meta skuid {UID_LIST} udp dport 53 redirect to :5353
    meta skuid {UID_LIST} tcp dport 53 redirect to :5353
  }
}
```

`UID_LIST` dibangun dari akun SSH terkelola.

### Sumber blocklist

Ada dua pilihan yang sehat:

1. blocklist lokal sederhana:
   - file domain adblock sendiri
2. generate dari asset `custom.dat` menjadi daftar domain plain untuk `dnsmasq`

Untuk repo ini, fase awal lebih aman memakai file domain adblock plain terpisah untuk SSH.

Jangan langsung memaksa parser `custom.dat` ke `dnsmasq` sampai benar-benar perlu.

### Status yang perlu ditampilkan di menu

Jika nanti diimplementasikan, menu SSH adblock sebaiknya menampilkan:

- `SSH Adblock : ON/OFF`
- `Resolver    : 127.0.0.1:5353`
- `Blocklist   : loaded / empty`
- `Redirect    : active / inactive`
- `Users bound : N user(s)`

## Batasan SSH Adblock

Ini penting:

### Yang bisa diblok dengan baik

- domain yang di-resolve lewat DNS biasa dari sesi SSH
- aplikasi yang memakai resolver server-side

### Yang tidak bisa dijamin diblok

- DoH (DNS over HTTPS)
- DoT (DNS over TLS)
- aplikasi yang langsung hit IP
- aplikasi yang punya hardcoded resolver sendiri

Jadi SSH adblock harus dipahami sebagai:

- `DNS-based adblock`
- bukan `full traffic adblock`

Kalau nanti ingin lebih keras, bisa ditambah phase lanjutan:

- block DoH/DoT endpoints populer
- block port `853`
- deny beberapa endpoint resolver publik yang umum

Tetapi itu harus dianggap hardening tambahan, bukan bagian fase pertama.

## UX yang Disarankan

Supaya tetap sederhana, adblock cukup muncul di dua tempat:

### Xray

- `5) Network > Adblock`

Isi:

- `Enable`
- `Disable`
- `Status`

### SSH

Opsi terbaik:

- tetap taruh di `5) Network`
- submenu baru: `SSH Adblock`

Isi:

- `Enable`
- `Disable`
- `Status`
- `Show bound users`

Jangan taruh di `SSH Users`, karena adblock ini sifatnya policy jaringan, bukan lifecycle user.

## Urutan Implementasi yang Disarankan

### Fase 1

Matangkan `Xray Adblock`:

- pastikan ON/OFF stabil
- tambah status asset/blocklist
- tambah whitelist jika perlu

### Fase 2

Tambahkan `SSH Adblock` dasar:

- install `dnsmasq`
- file blocklist SSH
- `nftables` redirect per UID SSH
- menu ON/OFF/Status

### Fase 3

Hardening bypass SSH adblock:

- block `:853`
- optional deny DoH endpoint populer
- metrics sederhana

## Test Plan

### Xray

- `Adblock OFF`
  - domain iklan uji masih lolos
- `Adblock ON`
  - domain iklan uji diblok outbound `blocked`
- `Disable`
  - rule benar-benar hilang

### SSH

- buat user SSH uji
- enable SSH adblock
- jalankan query DNS dari sesi user itu
  - domain iklan harus `NXDOMAIN`/sinkhole
- jalankan query DNS dari root/non-SSH user
  - tidak boleh ikut ter-redirect
- disable SSH adblock
  - query kembali normal

### Bypass awareness

- uji DNS biasa `53`
- uji `DoT :853`
- catat bahwa DoH belum otomatis tertutup di fase dasar

## Keputusan Akhir

Kalau mau menambah adblock untuk `SSH` dan `Xray`, desain terbaik untuk repo ini adalah:

- `Xray Adblock` = routing block native Xray
- `SSH Adblock` = DNS sinkhole + `nftables` per UID user SSH

Jangan mencampurkan keduanya ke `Edge Gateway`, karena:

- `Xray` memang domain-aware
- `SSH` tidak domain-aware di ingress
- `Edge Gateway` hanya akan menambah kompleksitas tanpa memberi titik kontrol yang benar

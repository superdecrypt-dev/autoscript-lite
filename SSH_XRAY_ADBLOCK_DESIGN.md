# SSH + Xray Adblock Design

## Tujuan

Menambahkan adblock untuk dua jalur yang berbeda sifatnya:

- `Xray`: adblock berbasis routing domain yang memang sudah natural di core Xray.
- `SSH`: adblock berbasis DNS/egress untuk trafik yang keluar dari sesi SSH.

Dokumen ini sengaja memisahkan dua jalur tersebut karena mekanismenya tidak sama.

## Ringkasan Keputusan

### Shared Source

Source of truth adblock disatukan:

- manual domain list
- URL sources
- merged domain cache

Lalu source yang sama dibangun menjadi dua artifact runtime:

- `Xray`: `custom.dat` dengan entry `ext:custom.dat:adblock`
- `SSH`: blocklist `dnsmasq`

Jadi yang fleksibel adalah source-nya, bukan artifact runtime-nya.

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

- user mengelola source bersama dari `7) Adblocker`
- menu `Update Adblock` membangun ulang `custom.dat`
- rule routing Xray tetap memakai `ext:custom.dat:adblock`
- domain yang match diarahkan ke outbound `blocked`

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

Model yang dipakai sekarang:

1. user mengubah source bersama:
   - daftar domain manual
   - daftar URL source
2. menu `Update Adblock` akan:
   - fetch semua URL source
   - normalize + dedup
   - simpan hasil ke merged list
   - build `custom.dat` untuk Xray
   - build blocklist `dnsmasq` untuk SSH

Dengan model ini:

- `Add/Delete` tetap fleksibel
- `Update` menjadi satu-satunya langkah berat
- Xray tidak dipaksa memuat 1 juta domain inline ke config routing

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

Supaya tetap sederhana, adblock cukup muncul di satu jalur user-facing:

- `7) Adblocker`

Isi menu gabungan:

- `Enable Adblock`
- `Disable Adblock`
- `Add Domain`
- `Delete Domain`
- `Add URL Source`
- `Delete URL Source`
- `Update Adblock`
- `Toggle Auto Update`
- `Set Auto Update Interval`
- `Show bound users`

Semantik menu:

- `Add/Delete` hanya mengubah source dan menandai status `dirty`
- `Update Adblock` fetch + merge + build artifact runtime
- `Enable Adblock` akan otomatis memaksa `Update` dulu jika source masih `dirty`
- `Disable Adblock` hanya mematikan enforcement runtime, source tetap disimpan
- `Toggle Auto Update` mengaktifkan atau menonaktifkan timer harian untuk `Update Adblock`
- `Set Auto Update Interval` mengatur interval dalam satuan hari, misalnya `1`, `3`, atau `7`

Implementasi internal tetap dua backend:

- `Xray Adblock` untuk routing `ext:custom.dat:adblock`
- `SSH Adblock` untuk DNS sinkhole + `nftables` per UID

Jadi yang disatukan adalah jalur UX dan kontrol user-facing, bukan dipaksa menjadi satu mesin enforcement yang sama.

Jangan taruh di `SSH Users`, karena adblock ini sifatnya policy jaringan, bukan lifecycle user.

## Urutan Implementasi yang Disarankan

### Fase 1

Satukan jalur UX dan source adblock:

- satu menu
- source manual + URL
- status `dirty`
- update artifact terpadu

### Fase 2

Matangkan runtime enforcement:

- `custom.dat` build lokal untuk Xray
- `dnsmasq` blocklist untuk SSH
- `nftables` redirect per UID SSH
- reload service yang relevan saat artifact berubah

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

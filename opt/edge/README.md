# opt/edge

Direktori ini menyiapkan fondasi ingress publik `autoscript-lite` untuk stack:

- `Xray-core`
- `nginx` backend internal
- `WARP` support di jalur runtime host

dengan shared public port `80` dan `443`.

## Status

- Provider `go` sudah aktif live sebagai `Edge Gateway`.
- `edge-mux` saat ini memegang publik `80/443`.
- `nginx` berjalan di backend internal `127.0.0.1:18080`.
- `nginx-stream` tersedia sebagai opsi experimental/non-default.

## Provider yang direncanakan

1. `go`
   - provider utama
   - custom edge proxy
   - deploy memakai binary prebuilt
2. `nginx-stream`
   - experimental

## Prinsip

- Hanya satu provider aktif pada satu waktu.
- `nginx` akan dipindah ke backend internal saat edge diaktifkan.
- `edge-mux` memetakan traffic HTTP/TLS ke jalur `Xray` yang sesuai.
- route `SNI passthrough` tetap bisa dipakai untuk target internal yang memang diizinkan.

## Referensi

- Installer modular setup: [opt/setup/README.md](/root/project/autoscript-lite/opt/setup/README.md)
- Source provider Go: [opt/edge/go/README.md](/root/project/autoscript-lite/opt/edge/go/README.md)

## Build dan Prebuilt

- source provider `go` ada di `opt/edge/go`
- binary prebuilt disimpan di `opt/edge/dist`
- script build lokal:
  - [build-edge-mux.sh](/root/project/autoscript-lite/opt/edge/scripts/build-edge-mux.sh)

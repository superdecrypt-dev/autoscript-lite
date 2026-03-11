# opt/edge

Direktori ini menyiapkan fondasi provider edge untuk skenario:

- `SSH WS`
- `SSH SSL/TLS`
- route HTTP/Xray yang sudah ada

berjalan pada:

- `1 domain`
- shared public port `80` dan `443`

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
- `SSH WS` tetap berjalan melalui jalur HTTP/WebSocket backend.
- Jalur `SSH SSL/TLS` adalah backend terpisah.

## Referensi

- Desain teknis: [EDGE_PROVIDER_DESIGN.md](/root/project/autoscript/EDGE_PROVIDER_DESIGN.md)
- Installer modular setup: [opt/setup/README.md](/root/project/autoscript/opt/setup/README.md)

## Build dan Prebuilt

- source provider `go` ada di `opt/edge/go`
- binary prebuilt disimpan di `opt/edge/dist`
- script build lokal:
  - [build-edge-mux.sh](/root/project/autoscript/opt/edge/scripts/build-edge-mux.sh)

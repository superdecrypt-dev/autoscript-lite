# opt/edge

Direktori ini menyiapkan fondasi provider edge untuk skenario:

- `SSHWS`
- `SSH SSL/TLS klasik`
- route HTTP/Xray yang sudah ada

berjalan pada:

- `1 domain`
- shared public port `80` dan `443`

## Status

- Struktur ini baru tahap scaffold.
- Belum aktif di runtime.
- Tidak ada perubahan listener publik selama provider edge belum dihubungkan ke `setup.sh`.

## Provider yang direncanakan

1. `go`
   - provider utama
   - custom edge proxy
   - deploy memakai binary prebuilt
2. `haproxy`
   - fallback production-grade
3. `nginx-stream`
   - experimental

## Prinsip

- Hanya satu provider aktif pada satu waktu.
- `nginx` akan dipindah ke backend internal saat edge diaktifkan.
- `SSHWS` tetap berjalan melalui jalur HTTP/WebSocket backend.
- Jalur `SSH SSL/TLS klasik` adalah backend terpisah.

## Referensi

- Desain teknis: [EDGE_PROVIDER_DESIGN.md](/root/project/autoscript/EDGE_PROVIDER_DESIGN.md)
- Installer modular setup: [opt/setup/README.md](/root/project/autoscript/opt/setup/README.md)

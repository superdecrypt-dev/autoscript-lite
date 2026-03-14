# opt/edge/go

Source tree provider edge utama berbasis Go.

## Tujuan

Binary `edge-mux` akan:

- bind public `:80`
- bind public `:443`
- terminate TLS
- mendeteksi HTTP/WebSocket vs non-HTTP
- mem-proxy trafik ke backend yang tepat

## Status

- Provider `go` sudah aktif live sebagai `Edge Gateway`.
- Binary prebuilt dipakai sebagai jalur deploy utama.
- Source Go di sini adalah source of truth untuk build `edge-mux`.

## Layout

- `cmd/edge-mux/`
  - entrypoint binary
- `internal/detect/`
  - deteksi awal traffic
- `internal/proxy/`
  - stream proxy helper
- `internal/tlsmux/`
  - logic TLS terminate + mux
- `internal/runtime/`
  - config/env/runtime helpers

## Cakupan Implementasi Awal

- parse env/config runtime
- listener publik `:80`
- listener publik `:443`
- endpoint observability lokal-only `127.0.0.1:9910`
- TLS termination di `:443`
- klasifikasi awal:
  - HTTP/WebSocket -> backend HTTP internal
  - non-HTTP / timeout singkat -> backend SSH klasik
- route decision berbasis `Host/path/ALPN/SNI`
- override route berbasis `SNI` exact-match lewat `EDGE_SNI_ROUTES`
- passthrough TLS exact-match berbasis `SNI` lewat `EDGE_SNI_PASSTHROUGH`
- bridge stream dasar dua arah
- hot reload `cert/config` via `SIGHUP`
- route map `EDGE_SNI_ROUTES` dan `EDGE_SNI_PASSTHROUGH` ikut hot reload tanpa restart penuh
- hardening anti-abuse dasar
- parity session SSH untuk jalur direct/TLS

## Endpoint Lokal

Saat `EDGE_METRICS_ENABLED=true`, `edge-mux` akan membuka endpoint lokal-only:

- `/health`
- `/status`
- `/metrics`

`/status` sekarang juga memuat:

- info cert TLS aktif
- ALPN yang diiklankan
- listener runtime
- route decision terakhir yang terlihat
- source route terakhir (`detect`, `sni`, atau `passthrough`) dan alias `SNI` yang match
- map `EDGE_SNI_ROUTES` aktif jika dikonfigurasi
- map `EDGE_SNI_PASSTHROUGH` aktif jika dikonfigurasi
- `backend_health` juga mencakup target passthrough unik dengan key `passthrough:<host:port>`
- metrics juga punya counter khusus passthrough untuk `route hits`, `health blocks`, dan `backend dial failures`
- `configured_routes` menampilkan tabel route eksplisit `host -> mode -> backend -> target`

Default listen:

- `127.0.0.1:9910`

## Yang Belum

- parity lanjutan untuk provider `nginx-stream`
- hardening tambahan jika scope edge nanti diperluas lagi

## Build Lokal

Script build lokal:

- [build-edge-mux.sh](/root/project/autoscript/opt/edge/scripts/build-edge-mux.sh)

Output default:

- `opt/edge/dist/edge-mux-linux-amd64`
- `opt/edge/dist/edge-mux-linux-arm64`

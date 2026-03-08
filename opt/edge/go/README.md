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
- TLS termination di `:443`
- klasifikasi awal:
  - HTTP/WebSocket -> backend HTTP internal
  - non-HTTP / timeout singkat -> backend SSH klasik
- bridge stream dasar dua arah

## Yang Belum

- parity lanjutan untuk provider `nginx-stream`
- hardening tambahan jika scope edge nanti diperluas lagi

## Build Lokal

Script build lokal:

- [build-edge-mux.sh](/root/project/autoscript/opt/edge/scripts/build-edge-mux.sh)

Output default:

- `opt/edge/dist/edge-mux-linux-amd64`
- `opt/edge/dist/edge-mux-linux-arm64`
- `opt/edge/dist/SHA256SUMS`

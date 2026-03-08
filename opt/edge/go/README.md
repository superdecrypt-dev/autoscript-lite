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

- Folder ini sudah masuk implementasi awal.
- Runtime belum dihubungkan ke installer live.
- Binary prebuilt belum dibuat dari repo ini.

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

- build binary prebuilt
- wiring `setup.sh`
- status CLI edge
- provider `haproxy`
- provider `nginx-stream`

## Build Lokal

Script build lokal:

- [build-edge-mux.sh](/root/project/autoscript/opt/edge/scripts/build-edge-mux.sh)

Output default:

- `opt/edge/dist/edge-mux-linux-amd64`
- `opt/edge/dist/edge-mux-linux-arm64`
- `opt/edge/dist/SHA256SUMS`

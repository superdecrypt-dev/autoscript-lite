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

- Folder ini baru scaffold.
- Implementasi runtime belum dimulai.

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

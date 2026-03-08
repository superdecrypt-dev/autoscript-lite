#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EDGE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
GO_ROOT="${EDGE_ROOT}/go"
DIST_DIR="${EDGE_ROOT}/dist"
OUT_BASE="${OUT_BASE:-edge-mux-linux}"
if (($# > 0)); then
  TARGETS=("$@")
else
  TARGETS=("linux/amd64" "linux/arm64")
fi
GO_BUILD_CACHE="${GO_BUILD_CACHE:-/tmp/autoscript-edge-gocache}"

command -v go >/dev/null 2>&1 || {
  echo "go toolchain tidak ditemukan di PATH" >&2
  exit 1
}
command -v sha256sum >/dev/null 2>&1 || {
  echo "sha256sum tidak ditemukan di PATH" >&2
  exit 1
}

mkdir -p "${DIST_DIR}"
mkdir -p "${GO_BUILD_CACHE}"

(
  cd "${GO_ROOT}"
  find . -name '*.go' -print0 | xargs -0 gofmt -w
)

build_one() {
  local target="$1"
  local goos="${target%%/*}"
  local goarch="${target##*/}"
  local out="${DIST_DIR}/${OUT_BASE}-${goarch}"

  echo "[build] ${goos}/${goarch} -> ${out}"
  (
    cd "${GO_ROOT}"
    GOCACHE="${GO_BUILD_CACHE}" CGO_ENABLED=0 GOOS="${goos}" GOARCH="${goarch}" \
      go build -trimpath -ldflags="-s -w" -o "${out}" ./cmd/edge-mux
  )
}

for target in "${TARGETS[@]}"; do
  build_one "${target}"
done

(
  cd "${DIST_DIR}"
  sha256sum ${OUT_BASE}-* > SHA256SUMS
)

echo "[done] dist ready at ${DIST_DIR}"

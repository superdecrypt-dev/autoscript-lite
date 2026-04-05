#!/usr/bin/env bash
# Shared Adblock foundation for setup runtime.

ADBLOCK_DIST_DIR="${SCRIPT_DIR}/opt/adblock/dist"
ADBLOCK_AUTO_UPDATE_SERVICE="${ADBLOCK_AUTO_UPDATE_SERVICE:-adblock-update.service}"
ADBLOCK_AUTO_UPDATE_TIMER="${ADBLOCK_AUTO_UPDATE_TIMER:-adblock-update.timer}"
ADBLOCK_AUTO_UPDATE_DAYS="${ADBLOCK_AUTO_UPDATE_DAYS:-1}"

adblock_go_arch_label() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "amd64" ;;
    aarch64|arm64) printf '%s\n' "arm64" ;;
    *) return 1 ;;
  esac
}

adblock_expected_binary_path() {
  local arch
  arch="$(adblock_go_arch_label)" || return 1
  printf '%s/adblock-sync-linux-%s\n' "${ADBLOCK_DIST_DIR}" "${arch}"
}

adblock_prebuilt_ready() {
  local bin
  bin="$(adblock_expected_binary_path)" || return 1
  [[ -f "${bin}" && -s "${bin}" ]]
}

adblock_config_render_preserving_runtime_state() {
  local rendered merged
    rm -f "${rendered}" >/dev/null 2>&1 || true
    die "Gagal menyiapkan merge config adblock."
  }

  render_setup_template_or_die \
    "${rendered}" \
    0644 \
    "ADBLOCK_AUTO_UPDATE_SERVICE=${ADBLOCK_AUTO_UPDATE_SERVICE}" \
    "ADBLOCK_AUTO_UPDATE_TIMER=${ADBLOCK_AUTO_UPDATE_TIMER}" \
    "ADBLOCK_AUTO_UPDATE_DAYS=${ADBLOCK_AUTO_UPDATE_DAYS}" \
    "CUSTOM_GEOSITE_DEST=${CUSTOM_GEOSITE_DEST}"

import pathlib
import sys

existing_path = pathlib.Path(sys.argv[1])
rendered_path = pathlib.Path(sys.argv[2])
merged_path = pathlib.Path(sys.argv[3])
preserve_keys = {
  "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED",
  "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS",
  "AUTOSCRIPT_ADBLOCK_DIRTY",
  "AUTOSCRIPT_ADBLOCK_LAST_UPDATE",
}

existing = {}
try:
  for line in existing_path.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    existing[key.strip()] = value.strip()
except Exception:
  existing = {}

lines = rendered_path.read_text(encoding="utf-8").splitlines()
out = []
for line in lines:
  stripped = line.strip()
  if not stripped or stripped.startswith("#") or "=" not in line:
    out.append(line)
    continue
  key, _ = line.split("=", 1)
  key = key.strip()
  if key in preserve_keys and key in existing:
    out.append(f"{key}={existing[key]}")
  else:
    out.append(line)

merged_path.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
PY
      rm -f "${rendered}" "${merged}" >/dev/null 2>&1 || true
      die "Gagal merge state adblock lama."
    }
  else
  fi
  rm -f "${rendered}" "${merged}" >/dev/null 2>&1 || true
}

adblock_config_get_value() {
  local key="$1"
  local fallback="${2:-}"
    printf '%s\n' "${fallback}"
    return 0
  }
  awk -F'=' -v target="${key}" -v default_value="${fallback}" '
    $1 == target {
      print substr($0, index($0, "=") + 1)
      found = 1
      exit
    }
    END {
      if (!found) {
        print default_value
      }
    }
}

adblock_seed_template_if_missing() {
  local template_rel="$1"
  local dst="$2"
  local mode="${3:-0644}"
  if [[ -e "${dst}" ]]; then
    chmod "${mode}" "${dst}" >/dev/null 2>&1 || true
    chown root:root "${dst}" 2>/dev/null || true
    return 0
  fi
  render_setup_template_or_die "${template_rel}" "${dst}" "${mode}"
}

adblock_touch_if_missing() {
  local dst="$1"
  local mode="${2:-0644}"
  if [[ -e "${dst}" ]]; then
    chmod "${mode}" "${dst}" >/dev/null 2>&1 || true
    chown root:root "${dst}" 2>/dev/null || true
    return 0
  fi
  install -m "${mode}" /dev/null "${dst}"
  chown root:root "${dst}" 2>/dev/null || true
}

adblock_runtime_artifacts_ready() {
  [[ -s "${CUSTOM_GEOSITE_DEST}" ]] || return 1
    return 0
  fi
}

adblock_bootstrap_update_or_preserve_runtime() {
    return 0
  fi
    warn "Update Adblock gagal saat setup; artifact lama dipertahankan."
    return 0
  fi
  return 1
}

adblock_cleanup_legacy_sync_runtime() {
  fi
  fi
}

  adblock_prebuilt_ready || die "Binary prebuilt adblock-sync belum tersedia untuk arsitektur host."
  local dnsmasq_bin=""
  local adblock_bin=""
  local adblock_auto_update_days_effective=""
  dnsmasq_bin="$(command -v dnsmasq 2>/dev/null || true)"
  adblock_bin="$(adblock_expected_binary_path)" || die "Arsitektur host belum didukung untuk adblock-sync."
  [[ -n "${dnsmasq_bin}" ]] || die "dnsmasq tidak ditemukan. Pastikan dnsmasq-base terpasang."
  command -v nft >/dev/null 2>&1 || die "nft tidak ditemukan. Pastikan nftables terpasang."

  install -d -m 755 /etc/systemd/system


  adblock_config_render_preserving_runtime_state

  adblock_seed_template_if_missing \
    0644


  adblock_auto_update_days_effective="$(adblock_config_get_value AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS "${ADBLOCK_AUTO_UPDATE_DAYS}")"
  [[ "${adblock_auto_update_days_effective}" =~ ^[1-9][0-9]*$ ]] || adblock_auto_update_days_effective="${ADBLOCK_AUTO_UPDATE_DAYS}"
  local dns_upstream_primary dns_upstream_secondary

  render_setup_template_or_die \
    0644 \

  render_setup_template_or_die \
    0644 \
    "DNSMASQ_BIN=${dnsmasq_bin}" \

  render_setup_template_or_die \
    "systemd/adblock-sync.service" \
    0644 \

  render_setup_template_or_die \
    "systemd/adblock-update.service" \
    "/etc/systemd/system/${ADBLOCK_AUTO_UPDATE_SERVICE}" \
    0644 \

  render_setup_template_or_die \
    "systemd/adblock-update.timer" \
    "/etc/systemd/system/${ADBLOCK_AUTO_UPDATE_TIMER}" \
    0644 \
    "ADBLOCK_AUTO_UPDATE_SERVICE=${ADBLOCK_AUTO_UPDATE_SERVICE}" \
    "ADBLOCK_AUTO_UPDATE_DAYS=${adblock_auto_update_days_effective}"

  adblock_cleanup_legacy_sync_runtime
  systemctl daemon-reload
  adblock_bootstrap_update_or_preserve_runtime || die "Gagal bootstrap awal Adblock."
    systemctl enable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || die "Gagal mengaktifkan ${ADBLOCK_AUTO_UPDATE_TIMER}."
  else
    systemctl disable --now "${ADBLOCK_AUTO_UPDATE_TIMER}" >/dev/null 2>&1 || true
  fi
}

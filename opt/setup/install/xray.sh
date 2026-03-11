#!/usr/bin/env bash
# Xray install/config module for setup runtime.

install_xray() {
  ok "Pasang Xray..."
  local xray_installer
  local xray_installer_err
  xray_installer="$(mktemp)"
  xray_installer_err="$(mktemp)"
  download_file_or_die "${XRAY_INSTALL_SCRIPT_URL}" "${xray_installer}" "" "xray installer script"
  chmod 700 "${xray_installer}"
  if ! bash "${xray_installer}" install >/dev/null 2>"${xray_installer_err}"; then
    cat "${xray_installer_err}" >&2 || true
    rm -f "${xray_installer}" "${xray_installer_err}" >/dev/null 2>&1 || true
    die "Gagal install Xray dari ref ${XRAY_INSTALL_REF}."
  fi
  rm -f "${xray_installer}" >/dev/null 2>&1 || true
  rm -f "${xray_installer_err}" >/dev/null 2>&1 || true

  command -v xray >/dev/null 2>&1 || die "Xray tidak terpasang."
  ok "Xray siap."
}

write_xray_config() {
  local UUID TROJAN_PASS SS_PASS SS2022_SERVER_PSK SS2022_USER_PSK
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  TROJAN_PASS="$(rand_str 24)"
  SS_PASS="$(rand_str 24)"
  SS2022_SERVER_PSK="$(python3 - <<'PY'
import base64, os
print(base64.b64encode(os.urandom(16)).decode())
PY
)"
  SS2022_USER_PSK="$(python3 - <<'PY'
import base64, os
print(base64.b64encode(os.urandom(16)).decode())
PY
)"

  local P_VLESS_WS P_VMESS_WS P_TROJAN_WS P_SS_WS P_SS2022_WS
  local P_VLESS_HUP P_VMESS_HUP P_TROJAN_HUP P_SS_HUP P_SS2022_HUP
  local P_VLESS_GRPC P_VMESS_GRPC P_TROJAN_GRPC P_SS_GRPC P_SS2022_GRPC
  local P_API

  P_VLESS_WS="$(pick_port)"
  P_VMESS_WS="$(pick_port)"
  P_TROJAN_WS="$(pick_port)"
  P_SS_WS="$(pick_port)"
  P_SS2022_WS="$(pick_port)"
  P_VLESS_HUP="$(pick_port)"
  P_VMESS_HUP="$(pick_port)"
  P_TROJAN_HUP="$(pick_port)"
  P_SS_HUP="$(pick_port)"
  P_SS2022_HUP="$(pick_port)"
  P_VLESS_GRPC="$(pick_port)"
  P_VMESS_GRPC="$(pick_port)"
  P_TROJAN_GRPC="$(pick_port)"
  P_SS_GRPC="$(pick_port)"
  P_SS2022_GRPC="$(pick_port)"
  P_API="10080"

  if ! is_port_free "$P_API"; then
    warn "Port API Xray (${P_API}) sedang dipakai. Mencoba stop service xray sebelumnya..."
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop xray >/dev/null 2>&1 || true
      sleep 1
    fi
  fi
  is_port_free "$P_API" || die "Port API Xray ($P_API) sedang dipakai. Bebaskan port ini atau ubah konfigurasi."

  local I_VLESS_WS I_VMESS_WS I_TROJAN_WS I_SS_WS I_SS2022_WS
  local I_VLESS_HUP I_VMESS_HUP I_TROJAN_HUP I_SS_HUP I_SS2022_HUP
  local I_VLESS_GRPC I_VMESS_GRPC I_TROJAN_GRPC I_SS_GRPC I_SS2022_GRPC

  I_VLESS_WS="/$(rand_str 14)"
  I_VMESS_WS="/$(rand_str 14)"
  I_TROJAN_WS="/$(rand_str 14)"
  I_SS_WS="/$(rand_str 14)"
  I_SS2022_WS="/$(rand_str 14)"
  I_VLESS_HUP="/$(rand_str 14)"
  I_VMESS_HUP="/$(rand_str 14)"
  I_TROJAN_HUP="/$(rand_str 14)"
  I_SS_HUP="/$(rand_str 14)"
  I_SS2022_HUP="/$(rand_str 14)"
  I_VLESS_GRPC="$(rand_str 12)"
  I_VMESS_GRPC="$(rand_str 12)"
  I_TROJAN_GRPC="$(rand_str 12)"
  I_SS_GRPC="$(rand_str 12)"
  I_SS2022_GRPC="$(rand_str 12)"

  mkdir -p "$(dirname "$XRAY_CONFIG")"

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "info"
  },
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8"
    ]
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "domain": [
          "geosite:private"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "domain": [
          "geosite:apple",
          "geosite:meta",
          "geosite:google",
          "geosite:openai",
          "geosite:spotify",
          "geosite:netflix",
          "geosite:reddit"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": [
          "dummy-warp-inbounds"
        ],
        "outboundTag": "warp"
      },
      {
        "type": "field",
        "inboundTag": [
          "dummy-direct-inbounds"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "user": [
          "dummy-warp-user"
        ],
        "outboundTag": "warp"
      },
      {
        "type": "field",
        "user": [
          "dummy-direct-user"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "user": [
          "dummy-block-user"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "user": [
          "dummy-quota-user"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "user": [
          "dummy-limit-user"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "port": "1-65535",
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${P_API},
      "protocol": "dokodemo-door",
      "tag": "api",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_VLESS_WS},
      "protocol": "vless",
      "tag": "default@vless-ws",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "email": "default@vless-ws"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${I_VLESS_WS}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_VMESS_WS},
      "protocol": "vmess",
      "tag": "default@vmess-ws",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0,
            "email": "default@vmess-ws"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${I_VMESS_WS}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_TROJAN_WS},
      "protocol": "trojan",
      "tag": "default@trojan-ws",
      "settings": {
        "clients": [
          {
            "password": "${TROJAN_PASS}",
            "email": "default@trojan-ws"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${I_TROJAN_WS}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_SS_WS},
      "protocol": "shadowsocks",
      "tag": "default@shadowsocks-ws",
      "settings": {
        "method": "aes-128-gcm",
        "password": "${SS_PASS}",
        "clients": [
          {
            "method": "aes-128-gcm",
            "password": "${SS_PASS}",
            "email": "default@shadowsocks-ws"
          }
        ],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${I_SS_WS}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_SS2022_WS},
      "protocol": "shadowsocks",
      "tag": "default@shadowsocks2022-ws",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "${SS2022_SERVER_PSK}",
        "clients": [
          {
            "password": "${SS2022_USER_PSK}",
            "email": "default@shadowsocks2022-ws"
          }
        ],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${I_SS2022_WS}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_VLESS_HUP},
      "protocol": "vless",
      "tag": "default@vless-hup",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "email": "default@vless-hup"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "${I_VLESS_HUP}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_VMESS_HUP},
      "protocol": "vmess",
      "tag": "default@vmess-hup",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0,
            "email": "default@vmess-hup"
          }
        ]
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "${I_VMESS_HUP}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_TROJAN_HUP},
      "protocol": "trojan",
      "tag": "default@trojan-hup",
      "settings": {
        "clients": [
          {
            "password": "${TROJAN_PASS}",
            "email": "default@trojan-hup"
          }
        ]
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "${I_TROJAN_HUP}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_SS_HUP},
      "protocol": "shadowsocks",
      "tag": "default@shadowsocks-hup",
      "settings": {
        "method": "aes-128-gcm",
        "password": "${SS_PASS}",
        "clients": [
          {
            "method": "aes-128-gcm",
            "password": "${SS_PASS}",
            "email": "default@shadowsocks-hup"
          }
        ],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "${I_SS_HUP}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_SS2022_HUP},
      "protocol": "shadowsocks",
      "tag": "default@shadowsocks2022-hup",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "${SS2022_SERVER_PSK}",
        "clients": [
          {
            "password": "${SS2022_USER_PSK}",
            "email": "default@shadowsocks2022-hup"
          }
        ],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "${I_SS2022_HUP}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_VLESS_GRPC},
      "protocol": "vless",
      "tag": "default@vless-grpc",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "email": "default@vless-grpc"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "${I_VLESS_GRPC}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_VMESS_GRPC},
      "protocol": "vmess",
      "tag": "default@vmess-grpc",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0,
            "email": "default@vmess-grpc"
          }
        ]
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "${I_VMESS_GRPC}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_TROJAN_GRPC},
      "protocol": "trojan",
      "tag": "default@trojan-grpc",
      "settings": {
        "clients": [
          {
            "password": "${TROJAN_PASS}",
            "email": "default@trojan-grpc"
          }
        ]
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "${I_TROJAN_GRPC}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_SS_GRPC},
      "protocol": "shadowsocks",
      "tag": "default@shadowsocks-grpc",
      "settings": {
        "method": "aes-128-gcm",
        "password": "${SS_PASS}",
        "clients": [
          {
            "method": "aes-128-gcm",
            "password": "${SS_PASS}",
            "email": "default@shadowsocks-grpc"
          }
        ],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "${I_SS_GRPC}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${P_SS2022_GRPC},
      "protocol": "shadowsocks",
      "tag": "default@shadowsocks2022-grpc",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "${SS2022_SERVER_PSK}",
        "clients": [
          {
            "password": "${SS2022_USER_PSK}",
            "email": "default@shadowsocks2022-grpc"
          }
        ],
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "${I_SS2022_GRPC}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    },
    {
      "protocol": "socks",
      "tag": "warp",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      }
    }
  ]
}
EOF

  mkdir -p /var/log/xray
  touch /var/log/xray/access.log /var/log/xray/error.log

  local xr_user xr_group
  xr_user="$(systemctl show -p User --value xray 2>/dev/null || true)"
  if [[ -z "${xr_user:-}" || "$xr_user" == "n/a" ]]; then
    xr_user="root"
  fi
  xr_group="$(id -gn "$xr_user" 2>/dev/null || echo "$xr_user")"

  chown "$xr_user:$xr_group" "$XRAY_CONFIG" >/dev/null 2>&1 || true
  chown "$xr_user:$xr_group" /var/log/xray >/dev/null 2>&1 || true
  chown "$xr_user:$xr_group" /var/log/xray/access.log /var/log/xray/error.log >/dev/null 2>&1 || true

  chmod 640 "$XRAY_CONFIG"
  chmod 750 /var/log/xray
  chmod 640 /var/log/xray/access.log /var/log/xray/error.log


  # Validasi config sebelum dipakai (hindari exit "diam-diam").
  local test_log
  test_log="$(mktemp "/tmp/xray-config-test.XXXXXX.log")"
  if ! xray run -test -config "$XRAY_CONFIG" >"$test_log" 2>&1; then
    tail -n 200 "$test_log" >&2 || true
    die "Xray config test gagal. Lihat: $test_log"
  fi
  rm -f "$test_log" >/dev/null 2>&1 || true

  # Tidak perlu enable/restart xray di sini.
  # configure_xray_service_confdir (dipanggil setelah write_xray_modular_configs)
  # akan meng-install unit file yang benar (-confdir) dan merestart xray satu kali.
  ok "Config Xray dasar siap."
  declare -gx XR_UUID="$UUID"
  declare -gx XR_TROJAN_PASS="$TROJAN_PASS"
  declare -gx XR_SS_PASS="$SS_PASS"
  declare -gx XR_SS2022_SERVER_PSK="$SS2022_SERVER_PSK"
  declare -gx XR_SS2022_USER_PSK="$SS2022_USER_PSK"
  declare -gx XR_API_PORT="$P_API"

  declare -gx P_VLESS_WS="$P_VLESS_WS"
  declare -gx P_VMESS_WS="$P_VMESS_WS"
  declare -gx P_TROJAN_WS="$P_TROJAN_WS"
  declare -gx P_SS_WS="$P_SS_WS"
  declare -gx P_SS2022_WS="$P_SS2022_WS"
  declare -gx P_VLESS_HUP="$P_VLESS_HUP"
  declare -gx P_VMESS_HUP="$P_VMESS_HUP"
  declare -gx P_TROJAN_HUP="$P_TROJAN_HUP"
  declare -gx P_SS_HUP="$P_SS_HUP"
  declare -gx P_SS2022_HUP="$P_SS2022_HUP"
  declare -gx P_VLESS_GRPC="$P_VLESS_GRPC"
  declare -gx P_VMESS_GRPC="$P_VMESS_GRPC"
  declare -gx P_TROJAN_GRPC="$P_TROJAN_GRPC"
  declare -gx P_SS_GRPC="$P_SS_GRPC"
  declare -gx P_SS2022_GRPC="$P_SS2022_GRPC"

  declare -gx I_VLESS_WS="$I_VLESS_WS"
  declare -gx I_VMESS_WS="$I_VMESS_WS"
  declare -gx I_TROJAN_WS="$I_TROJAN_WS"
  declare -gx I_SS_WS="$I_SS_WS"
  declare -gx I_SS2022_WS="$I_SS2022_WS"
  declare -gx I_VLESS_HUP="$I_VLESS_HUP"
  declare -gx I_VMESS_HUP="$I_VMESS_HUP"
  declare -gx I_TROJAN_HUP="$I_TROJAN_HUP"
  declare -gx I_SS_HUP="$I_SS_HUP"
  declare -gx I_SS2022_HUP="$I_SS2022_HUP"
  declare -gx I_VLESS_GRPC="$I_VLESS_GRPC"
  declare -gx I_VMESS_GRPC="$I_VMESS_GRPC"
  declare -gx I_TROJAN_GRPC="$I_TROJAN_GRPC"
  declare -gx I_SS_GRPC="$I_SS_GRPC"
  declare -gx I_SS2022_GRPC="$I_SS2022_GRPC"
}

write_xray_modular_configs() {
  ok "Buat config Xray modular..."
  mkdir -p "${XRAY_CONFDIR}"
  need_python3

  python3 - <<'PY' "${XRAY_CONFIG}" "${XRAY_CONFDIR}"
import json
import os
import sys

src, outdir = sys.argv[1:3]

with open(src, "r", encoding="utf-8") as f:
  cfg = json.load(f)

routing = cfg.get("routing") or {}
inbounds_fresh = cfg.get("inbounds") or []
if not isinstance(inbounds_fresh, list):
  inbounds_fresh = []

parts = [
  ("00-log.json", {"log": cfg.get("log") or {}}),
  ("01-api.json", {"api": cfg.get("api") or {}}),
  ("02-dns.json", {"dns": cfg.get("dns") or {}}),
  ("10-inbounds.json", {"inbounds": inbounds_fresh}),
  ("20-outbounds.json", {"outbounds": cfg.get("outbounds") or []}),
  ("30-routing.json", {"routing": routing}),
  ("40-policy.json", {"policy": cfg.get("policy") or {}}),
  ("50-stats.json", {"stats": cfg.get("stats") or {}}),
]

os.makedirs(outdir, exist_ok=True)

for name, obj in parts:
  path = os.path.join(outdir, name)
  tmp = f"{path}.tmp"
  with open(tmp, "w", encoding="utf-8") as wf:
    json.dump(obj, wf, ensure_ascii=False, indent=2)
    wf.write("\n")
  os.replace(tmp, path)
PY

  chmod 640 "${XRAY_CONFDIR}"/*.json 2>/dev/null || true
  ok "Config modular siap:"
  ok "  - ${XRAY_CONFDIR}/00-log.json"
  ok "  - ${XRAY_CONFDIR}/01-api.json"
  ok "  - ${XRAY_CONFDIR}/02-dns.json"
  ok "  - ${XRAY_CONFDIR}/10-inbounds.json"
  ok "  - ${XRAY_CONFDIR}/20-outbounds.json"
  ok "  - ${XRAY_CONFDIR}/30-routing.json"
  ok "  - ${XRAY_CONFDIR}/40-policy.json"
  ok "  - ${XRAY_CONFDIR}/50-stats.json"
}

ensure_xray_service_user() {
  # Dedicated non-root service account for xray runtime.
  getent group xray >/dev/null 2>&1 || groupadd --system xray
  if ! id -u xray >/dev/null 2>&1; then
    local nologin_bin
    nologin_bin="$(command -v nologin 2>/dev/null || true)"
    [[ -n "${nologin_bin:-}" ]] || nologin_bin="/usr/sbin/nologin"
    useradd --system --gid xray --home-dir /var/lib/xray --create-home --shell "${nologin_bin}" xray
  fi
}

configure_xray_service_confdir() {
  ok "Atur xray.service -> -confdir ..."

  local xray_bin
  xray_bin="$(command -v xray || true)"
  [[ -n "${xray_bin:-}" ]] || xray_bin="/usr/local/bin/xray"
  ensure_xray_service_user

  # Hilangkan warning systemd "Special user nobody configured" dari unit utama.
  local frag
  frag="$(systemctl show -p FragmentPath --value xray 2>/dev/null || true)"
  if [[ -n "${frag:-}" && -f "${frag}" ]]; then
    sed -i 's/^User=nobody$/User=xray/' "${frag}" 2>/dev/null || true
  fi

  # Bersihkan drop-in yang mungkin konflik
  mkdir -p /etc/systemd/system/xray.service.d
  rm -f /etc/systemd/system/xray.service.d/*.conf 2>/dev/null || true

  render_setup_template_or_die \
    "systemd/xray-confdir.conf" \
    "/etc/systemd/system/xray.service.d/10-confdir.conf" \
    0644 \
    "XRAY_BIN=${xray_bin}" \
    "XRAY_CONFDIR=${XRAY_CONFDIR}"

  systemctl daemon-reload

  # Pastikan permission conf.d bisa dibaca oleh user xray
  mkdir -p /usr/local/etc/xray "${XRAY_CONFDIR}"
  chown root:xray /usr/local/etc/xray "${XRAY_CONFDIR}" >/dev/null 2>&1 || true
  chmod 750 /usr/local/etc/xray "${XRAY_CONFDIR}" >/dev/null 2>&1 || true
  chown root:xray "${XRAY_CONFDIR}"/*.json >/dev/null 2>&1 || true
  chmod 640 "${XRAY_CONFDIR}"/*.json >/dev/null 2>&1 || true

  # Pastikan direktori & file log ada
  mkdir -p /var/log/xray
  touch /var/log/xray/access.log /var/log/xray/error.log
  chown xray:xray /var/log/xray /var/log/xray/access.log /var/log/xray/error.log >/dev/null 2>&1 || true
  chmod 750 /var/log/xray
  chmod 640 /var/log/xray/access.log /var/log/xray/error.log

  # Test konfigurasi confdir sebelum restart
  if ! "${xray_bin}" run -test -confdir "${XRAY_CONFDIR}" >/dev/null 2>&1; then
    "${xray_bin}" run -test -confdir "${XRAY_CONFDIR}" || true
    die "Konfigurasi confdir Xray invalid."
  fi

  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray >/dev/null 2>&1 || { journalctl -u xray -n 200 --no-pager >&2 || true; die "Gagal restart xray"; }
  ok "xray.service aktif."

  # Setelah Xray berjalan menggunakan conf.d, config.json tidak diperlukan lagi.
  if [[ -f "${XRAY_CONFIG}" ]]; then
    rm -f "${XRAY_CONFIG}" 2>/dev/null || true
    ok "Config bawaan dihapus: ${XRAY_CONFIG}"
  fi
}



setup_xray_geodata_updater() {
  ok "Pasang updater geodata..."

  cat > /usr/local/bin/xray-update-geodata <<EOF
#!/usr/bin/env bash
set -euo pipefail

URL="${XRAY_INSTALL_SCRIPT_URL}"
CUSTOM_URL="${CUSTOM_GEOSITE_URL}"
CUSTOM_DEST="${CUSTOM_GEOSITE_DEST}"
tmp="\$(mktemp)"
tmp_custom="\$(mktemp)"
cleanup() {
  rm -f "\${tmp}" >/dev/null 2>&1 || true
  rm -f "\${tmp_custom}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

curl -fsSL --connect-timeout 15 --max-time 120 "\${URL}" -o "\${tmp}"
bash "\${tmp}" install-geodata >/dev/null 2>&1

mkdir -p "\$(dirname "\${CUSTOM_DEST}")"
curl -fsSL --connect-timeout 15 --max-time 120 "\${CUSTOM_URL}" -o "\${tmp_custom}"
[[ -s "\${tmp_custom}" ]] || { echo "[xray-update-geodata] custom.dat kosong: \${CUSTOM_URL}" >&2; exit 1; }
install -m 644 "\${tmp_custom}" "\${CUSTOM_DEST}"
EOF

  chmod +x /usr/local/bin/xray-update-geodata

  cat > /etc/cron.d/xray-update-geodata <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 4 * * * root /usr/local/bin/xray-update-geodata >/dev/null 2>&1
EOF

  ok "Cron geodata siap."


  ok "Update geodata awal..."
  /usr/local/bin/xray-update-geodata || die "Gagal update geodata pertama kali (cek koneksi ke github.com)."
  ok "Geodata awal selesai."

}

install_custom_geosite_adblock() {
  ok "Unduh geosite custom..."
  mkdir -p "${XRAY_ASSET_DIR}"

  local tmp
  tmp="$(mktemp)"
  download_file_or_die "${CUSTOM_GEOSITE_URL}" "${tmp}" "" "custom geosite"
  [[ -s "${tmp}" ]] || {
    rm -f "${tmp}" >/dev/null 2>&1 || true
    die "File custom geosite kosong: ${CUSTOM_GEOSITE_URL}"
  }

  install -m 644 "${tmp}" "${CUSTOM_GEOSITE_DEST}"
  rm -f "${tmp}" >/dev/null 2>&1 || true
  ok "custom.dat tersimpan."
}

install_xray_speed_limiter_foundation() {
  ok "Pasang xray-speed..."

  mkdir -p "${SPEED_POLICY_ROOT}" "${SPEED_STATE_DIR}" "${SPEED_CONFIG_DIR}"
  chmod 700 "${SPEED_POLICY_ROOT}" "${SPEED_STATE_DIR}" "${SPEED_CONFIG_DIR}" || true

  local proto
  for proto in "${SPEED_PROTO_DIRS[@]}"; do
    mkdir -p "${SPEED_POLICY_ROOT}/${proto}"
    chmod 700 "${SPEED_POLICY_ROOT}/${proto}" || true
  done

  render_setup_template_or_die     "config/xray-speed-config.json"     "${SPEED_CONFIG_DIR}/config.json"     0600     "SPEED_POLICY_ROOT=${SPEED_POLICY_ROOT}"     "SPEED_STATE_FILE=${SPEED_STATE_DIR}/state.json"

  install_setup_bin_or_die "xray-speed.py" "/usr/local/bin/xray-speed" 0755

  render_setup_template_or_die     "systemd/xray-speed.service"     "/etc/systemd/system/xray-speed.service"     0644

  systemctl daemon-reload
  if service_enable_restart_checked xray-speed; then
    ok "xray-speed aktif:"
    ok "  - policy root: ${SPEED_POLICY_ROOT}/{vless,vmess,trojan,shadowsocks,shadowsocks2022}"
    ok "  - config: ${SPEED_CONFIG_DIR}/config.json"
    ok "  - binary: /usr/local/bin/xray-speed"
    ok "  - service: xray-speed"
  else
    warn "xray-speed gagal aktif otomatis. Bisa diaktifkan manual:"
    warn "  systemctl status xray-speed --no-pager"
    warn "  journalctl -u xray-speed -n 100 --no-pager"
    systemctl disable --now xray-speed >/dev/null 2>&1 || true
  fi
}

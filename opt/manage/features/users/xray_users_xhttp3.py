#!/usr/bin/env python3

import json
import os
import subprocess
import urllib.parse


def strip_json_comments(text):
    result = []
    i = 0
    in_string = False
    escape = False
    length = len(text)
    while i < length:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < length else ""
        if in_string:
            result.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            result.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            i += 2
            while i < length and text[i] not in "\r\n":
                i += 1
            continue
        if ch == "/" and nxt == "*":
            i += 2
            while i + 1 < length and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i = min(i + 2, length)
            continue
        result.append(ch)
        i += 1
    return "".join(result)


def load_jsonc(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.loads(strip_json_comments(handle.read()))


def ech_config_from_server_keys(server_keys):
    raw = str(server_keys or "").strip()
    if not raw:
        return ""
    try:
        out = subprocess.check_output(
            ["xray", "tls", "ech", "-i", raw],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except Exception:
        return ""
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    for idx, line in enumerate(lines):
        if line.lower().startswith("ech config list") and idx + 1 < len(lines):
            return lines[idx + 1]
    return ""


def _find_vless_xhttp3_inbound(cfg):
    for item in cfg.get("inbounds") or []:
        if isinstance(item, dict) and str(item.get("tag") or "").strip() == "default@vless-xhttp3":
            return item
    return None


def build_vless_xhttp3_client_config(inbounds_path, domain, cred, username, proto):
    if not os.path.isfile(inbounds_path):
        return None
    try:
        cfg = load_jsonc(inbounds_path)
    except Exception:
        return None

    inbound = _find_vless_xhttp3_inbound(cfg)
    if not isinstance(inbound, dict):
        return None

    stream = inbound.get("streamSettings") or {}
    tls = stream.get("tlsSettings") or {}
    xhttp = stream.get("xhttpSettings") or {}
    finalmask = stream.get("finalmask") or {}
    udp_masks = finalmask.get("udp") or []
    quic_params = finalmask.get("quicParams") or {}

    out_stream = {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
            "serverName": str(tls.get("serverName") or domain),
            "alpn": list(tls.get("alpn") or ["h3"]),
        },
        "xhttpSettings": {
            "path": str(xhttp.get("path") or "/vless-xhttp3"),
        },
    }
    user_agent = str((xhttp.get("headers") or {}).get("User-Agent") or "").strip()
    if user_agent:
        out_stream["xhttpSettings"]["headers"] = {"User-Agent": user_agent}

    ech_config = ech_config_from_server_keys(tls.get("echServerKeys"))
    if ech_config:
        out_stream["tlsSettings"]["echConfigList"] = ech_config

    udp_out = []
    for mask in udp_masks:
        if not isinstance(mask, dict):
            continue
        if str(mask.get("type") or "").strip() != "salamander":
            continue
        password = str(((mask.get("settings") or {}).get("password")) or "").strip()
        if not password:
            continue
        udp_out.append({"type": "salamander", "settings": {"password": password}})
    if udp_out or (isinstance(quic_params, dict) and quic_params):
        out_stream["finalmask"] = {}
        if udp_out:
            out_stream["finalmask"]["udp"] = udp_out
        if isinstance(quic_params, dict) and quic_params:
            out_stream["finalmask"]["quicParams"] = quic_params

    email = f"{username}@{proto}"
    remark = f"VLESS XHTTP/3 Full - {email}"
    return {
        "remark": remark,
        "remarks": remark,
        "version": {"min": "26.3.27"},
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {"udp": True},
            }
        ],
        "outbounds": [
            {
                "tag": "vless-xhttp3-out",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": domain,
                            "port": 443,
                            "users": [{"id": cred, "encryption": "none"}],
                        }
                    ]
                },
                "streamSettings": out_stream,
            }
        ],
        "routing": {
            "rules": [
                {
                    "type": "field",
                    "inboundTag": ["socks-in"],
                    "outboundTag": "vless-xhttp3-out",
                }
            ]
        },
    }


def build_vless_xhttp3_link(inbounds_path, domain, cred, username, proto):
    if not os.path.isfile(inbounds_path):
        return ""
    try:
        cfg = load_jsonc(inbounds_path)
    except Exception:
        return ""

    inbound = _find_vless_xhttp3_inbound(cfg)
    if not isinstance(inbound, dict):
        return ""

    stream = inbound.get("streamSettings") or {}
    tls = stream.get("tlsSettings") or {}
    xhttp = stream.get("xhttpSettings") or {}
    finalmask = stream.get("finalmask") or {}
    headers = xhttp.get("headers") or {}
    user_agent = str(headers.get("User-Agent") or "").strip()
    ech_config = ech_config_from_server_keys(tls.get("echServerKeys"))

    query = {
        "alpn": "h3",
        "fp": user_agent or "firefox",
        "type": "xhttp",
        "sni": str(tls.get("serverName") or domain),
        "mode": str(xhttp.get("mode") or "auto"),
        "path": str(xhttp.get("path") or "/vless-xhttp3"),
        "security": "tls",
        "encryption": "none",
        "insecure": "0",
        "allowInsecure": "0",
    }
    if ech_config:
        query["ech"] = ech_config
    if isinstance(finalmask, dict) and finalmask:
        query["fm"] = json.dumps(finalmask, ensure_ascii=False, separators=(",", ":"))
    if headers:
        query["extra"] = json.dumps({"headers": headers}, ensure_ascii=False, separators=(",", ":"))
    return f"vless://{cred}@{domain}:443?{urllib.parse.urlencode(query)}#{urllib.parse.quote(username + '@' + proto)}"

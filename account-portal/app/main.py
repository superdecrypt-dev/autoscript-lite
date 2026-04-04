from __future__ import annotations

import html
import json
import subprocess
import threading
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, JSONResponse

from .data import build_public_account_summary, build_public_account_traffic_context

APP_ROOT = Path(__file__).resolve().parents[2]
PORTAL_HEADERS = {
    "Cache-Control": "private, no-store",
    "X-Robots-Tag": "noindex, nofollow, noarchive",
}
TRAFFIC_WINDOW_SECONDS = 300
TRAFFIC_MAX_WINDOW_SECONDS = 900
TRAFFIC_SAMPLE_INTERVAL_SECONDS = 5
TRAFFIC_PRUNE_IDLE_SECONDS = 1800
TRAFFIC_SOURCE_CACHE_SECONDS = max(1, TRAFFIC_SAMPLE_INTERVAL_SECONDS - 1)
TRAFFIC_MAX_POINTS = max(2, (TRAFFIC_MAX_WINDOW_SECONDS // TRAFFIC_SAMPLE_INTERVAL_SECONDS) + 4)
_TRAFFIC_LOCK = threading.Lock()
_TRAFFIC_STATE: dict[str, dict[str, object]] = {}
XRAY_API_SERVER_FALLBACKS = ("127.0.0.1:10080", "[::1]:10080")
_XRAY_STATS_CACHE_LOCK = threading.Lock()
_XRAY_STATS_CACHE: dict[str, object] = {
    "expires_at": 0.0,
    "server": "",
    "totals": {},
}

app = FastAPI(
    title="autoscript-account-portal",
    version="1.0.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


def _escape(value: object) -> str:
    return html.escape(str(value if value is not None else "-"), quote=True)


def _device_from_user_agent(user_agent: str) -> str:
    ua = str(user_agent or "").lower()
    if not ua:
        return "desktop"
    if "ipad" in ua or "tablet" in ua or "sm-t" in ua:
        return "tablet"
    if "android" in ua and "mobile" not in ua:
        return "tablet"
    if "iphone" in ua or "ipod" in ua or "mobile" in ua:
        return "mobile"
    return "desktop"


def _status_badge_class(status_value: str) -> str:
    status_n = str(status_value or "").strip().lower()
    if status_n == "active":
        return "ok"
    if status_n == "expired":
        return "warn"
    return "bad"


def _quota_percent(summary: dict) -> int:
    limit_bytes = summary.get("quota_limit_bytes")
    used_bytes = summary.get("quota_used_bytes")
    if not isinstance(limit_bytes, int) or limit_bytes <= 0:
        return 0
    if not isinstance(used_bytes, int) or used_bytes <= 0:
        return 0
    percent = int((used_bytes / limit_bytes) * 100)
    return max(0, min(percent, 100))


def _active_ip_hint(active_ip: str, active_ip_last_seen: str) -> str:
    if active_ip != "-" and active_ip_last_seen != "-":
        return f"Terakhir aktif: {active_ip_last_seen}"
    if active_ip != "-":
        return "Sedang aktif."
    if active_ip_last_seen != "-":
        return f"Terakhir aktif: {active_ip_last_seen}"
    return "Belum ada login aktif."


def _quota_state(percent: int) -> tuple[str, str, str]:
    if percent >= 90:
        return "Hampir Habis", "bad", "Quota hampir habis."
    if percent >= 60:
        return "Perlu Dipantau", "warn", "Quota mulai tinggi."
    return "Aman", "ok", "Quota masih aman."


def _next_action(summary: dict, quota_percent: int) -> tuple[str, str]:
    status_value = str(summary.get("status") or "").strip().lower()
    days_remaining = summary.get("days_remaining")
    active_ip = str(summary.get("active_ip") or "-").strip() or "-"
    if status_value == "blocked":
        return "warning", "Akun diblokir. Hubungi admin."
    if status_value == "expired":
        return "warning", "Masa aktif habis. Hubungi admin."
    if quota_percent >= 90:
        return "warning", "Quota hampir habis."
    if isinstance(days_remaining, int) and days_remaining <= 3:
        return "warning", "Masa aktif hampir habis."
    if active_ip == "-":
        return "info", "Akun siap dipakai."
    return "ok", "Akun aktif."


def _protocol_badge(summary: dict) -> str:
    proto = str(summary.get("protocol") or "-").strip().lower()
    mapping = {
        "vless": "VLESS",
        "vmess": "VMESS",
        "trojan": "TROJAN",
        "ssh": "SSH",
        "openvpn": "OPENVPN",
    }
    return mapping.get(proto, proto.upper() or "-")


def _protocol_label(summary: dict) -> str:
    return _protocol_badge(summary)


def _human_rate(value: float) -> str:
    amount = max(0.0, float(value or 0.0))
    units = ("B/s", "KiB/s", "MiB/s", "GiB/s")
    idx = 0
    while amount >= 1024.0 and idx < len(units) - 1:
        amount /= 1024.0
        idx += 1
    if idx == 0:
        return f"{int(amount)} {units[idx]}"
    if amount >= 100:
        return f"{amount:.0f} {units[idx]}"
    if amount >= 10:
        return f"{amount:.1f} {units[idx]}"
    return f"{amount:.2f} {units[idx]}"


def _to_int(value: object, default: int = 0) -> int:
    try:
        if value is None:
            return default
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, (int, float)):
            return int(value)
        raw = str(value).strip()
        if not raw:
            return default
        return int(float(raw))
    except Exception:
        return default


def _xray_api_server_candidates(raw: object = None) -> list[str]:
    ordered: list[str] = []
    current = str(raw or "").strip()
    if current:
        for part in current.split(","):
            candidate = part.strip()
            if candidate and candidate not in ordered:
                ordered.append(candidate)
    for candidate in XRAY_API_SERVER_FALLBACKS:
        if candidate not in ordered:
            ordered.append(candidate)
    return ordered


def _xray_bulk_traffic_totals() -> dict[str, object] | None:
    now_ts = time.time()
    with _XRAY_STATS_CACHE_LOCK:
        expires_at = float(_XRAY_STATS_CACHE.get("expires_at") or 0.0)
        cached_totals = _XRAY_STATS_CACHE.get("totals")
        cached_server = str(_XRAY_STATS_CACHE.get("server") or "")
        if expires_at > now_ts and isinstance(cached_totals, dict):
            return {
                "server": cached_server,
                "totals": cached_totals,
            }

    last_error = ""
    for server in _xray_api_server_candidates():
        try:
            out = subprocess.check_output(
                ["xray", "api", "statsquery", f"--server={server}", "--pattern", "user>>>"],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=4,
            )
            payload = json.loads(out)
        except FileNotFoundError:
            return None
        except subprocess.TimeoutExpired:
            last_error = f"timeout @ {server}"
            continue
        except subprocess.CalledProcessError as exc:
            last_error = f"exit {exc.returncode} @ {server}"
            continue
        except json.JSONDecodeError as exc:
            last_error = f"json @ {server}: {exc}"
            continue
        except Exception as exc:
            last_error = f"error @ {server}: {exc}"
            continue

        totals: dict[str, dict[str, int]] = {}
        for item in payload.get("stat") or []:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or "")
            value = max(0, _to_int(item.get("value"), 0))
            parts = name.split(">>>")
            if len(parts) < 4 or parts[0] != "user" or parts[2] != "traffic":
                continue
            identity = str(parts[1] or "").strip()
            direction = str(parts[3] or "").strip().lower()
            if not identity:
                continue
            current = totals.setdefault(identity, {"uplink": 0, "downlink": 0})
            if direction == "uplink":
                current["uplink"] = value
            elif direction == "downlink":
                current["downlink"] = value
        with _XRAY_STATS_CACHE_LOCK:
            _XRAY_STATS_CACHE["expires_at"] = now_ts + TRAFFIC_SOURCE_CACHE_SECONDS
            _XRAY_STATS_CACHE["server"] = server
            _XRAY_STATS_CACHE["totals"] = totals
        return {
            "server": server,
            "totals": totals,
        }
    with _XRAY_STATS_CACHE_LOCK:
        _XRAY_STATS_CACHE["expires_at"] = now_ts + 1
        _XRAY_STATS_CACHE["server"] = ""
        _XRAY_STATS_CACHE["totals"] = {}
    return {"error": last_error, "totals": {}}


def _xray_live_traffic_totals(summary: dict) -> dict[str, object] | None:
    proto = str(summary.get("protocol") or "").strip().lower()
    if proto not in {"vless", "vmess", "trojan"}:
        return None
    identity = str(summary.get("traffic_account_key") or "").strip()
    if not identity:
        username = str(summary.get("username") or "").strip()
        if username:
            identity = f"{username}@{proto}"
    if not identity:
        return None

    bulk = _xray_bulk_traffic_totals()
    if not isinstance(bulk, dict):
        return None
    totals = bulk.get("totals")
    if not isinstance(totals, dict):
        totals = {}
    metrics = totals.get(identity) if isinstance(totals.get(identity), dict) else None
    if not isinstance(metrics, dict):
        return {
            "source": "quota_delta",
            "source_text": "Fallback delta quota",
            "supports_split": False,
            "error": str(bulk.get("error") or "").strip(),
        }
    uplink = max(0, _to_int(metrics.get("uplink"), 0))
    downlink = max(0, _to_int(metrics.get("downlink"), 0))
    server = str(bulk.get("server") or "")
    return {
        "source": "xray_api_stats",
        "source_text": "Data live Xray API",
        "supports_split": True,
        "uplink_total_bytes": uplink,
        "downlink_total_bytes": downlink,
        "total_bytes": uplink + downlink,
        "detail": f"{identity} via {server}" if server else identity,
    }


def _traffic_prune_locked(now_ts: float) -> None:
    stale_before = now_ts - TRAFFIC_PRUNE_IDLE_SECONDS
    for token in list(_TRAFFIC_STATE.keys()):
        item = _TRAFFIC_STATE.get(token)
        if not isinstance(item, dict):
            _TRAFFIC_STATE.pop(token, None)
            continue
        last_seen = float(item.get("last_seen_at") or 0.0)
        if last_seen < stale_before:
            _TRAFFIC_STATE.pop(token, None)


def _traffic_snapshot(token: str, summary: dict) -> dict[str, object]:
    now_ts = time.time()
    used_bytes = max(0, int(summary.get("quota_used_bytes") or 0))
    with _TRAFFIC_LOCK:
        _traffic_prune_locked(now_ts)
        state = _TRAFFIC_STATE.setdefault(
            token,
            {
                "last_total_bytes": used_bytes,
                "last_downlink_bytes": 0,
                "last_uplink_bytes": 0,
                "last_sample_ts": now_ts,
                "last_seen_at": now_ts,
                "samples": [],
                "live_metrics": None,
                "live_metrics_at": 0.0,
            },
        )
        cached_metrics = state.get("live_metrics") if isinstance(state.get("live_metrics"), dict) else None
        cached_metrics_at = float(state.get("live_metrics_at") or 0.0)

    live_metrics = cached_metrics if (cached_metrics is not None and (now_ts - cached_metrics_at) < TRAFFIC_SOURCE_CACHE_SECONDS) else None
    if live_metrics is None:
        live_metrics = _xray_live_traffic_totals(summary)
        with _TRAFFIC_LOCK:
            state = _TRAFFIC_STATE.setdefault(
                token,
                {
                    "last_total_bytes": used_bytes,
                    "last_downlink_bytes": 0,
                    "last_uplink_bytes": 0,
                    "last_sample_ts": now_ts,
                    "last_seen_at": now_ts,
                    "samples": [],
                    "live_metrics": None,
                    "live_metrics_at": 0.0,
                },
            )
            state["live_metrics"] = live_metrics if isinstance(live_metrics, dict) else None
            state["live_metrics_at"] = now_ts

    source = "quota_delta"
    source_text = "Delta quota"
    supports_split = False
    total_bytes = used_bytes
    downlink_bytes = 0
    uplink_bytes = 0
    if isinstance(live_metrics, dict):
        source = str(live_metrics.get("source") or source)
        source_text = str(live_metrics.get("source_text") or source_text)
        supports_split = bool(live_metrics.get("supports_split"))
        if supports_split:
            downlink_bytes = max(0, _to_int(live_metrics.get("downlink_total_bytes"), 0))
            uplink_bytes = max(0, _to_int(live_metrics.get("uplink_total_bytes"), 0))
            total_bytes = max(0, _to_int(live_metrics.get("total_bytes"), downlink_bytes + uplink_bytes))
    with _TRAFFIC_LOCK:
        state = _TRAFFIC_STATE.setdefault(
            token,
            {
                "last_total_bytes": total_bytes,
                "last_downlink_bytes": downlink_bytes,
                "last_uplink_bytes": uplink_bytes,
                "last_sample_ts": now_ts,
                "last_seen_at": now_ts,
                "samples": [],
                "live_metrics": live_metrics if isinstance(live_metrics, dict) else None,
                "live_metrics_at": now_ts,
                "source_key": f"{source}:{int(supports_split)}",
            },
        )
        last_total_bytes = max(0, int(state.get("last_total_bytes") or 0))
        last_downlink_bytes = max(0, int(state.get("last_downlink_bytes") or 0))
        last_uplink_bytes = max(0, int(state.get("last_uplink_bytes") or 0))
        last_sample_ts = float(state.get("last_sample_ts") or now_ts)
        previous_source_key = str(state.get("source_key") or "")
        source_key = f"{source}:{int(supports_split)}"
        samples = state.get("samples")
        if not isinstance(samples, list):
            samples = []
            state["samples"] = samples

        if previous_source_key != source_key:
            last_total_bytes = total_bytes
            last_downlink_bytes = downlink_bytes
            last_uplink_bytes = uplink_bytes
            last_sample_ts = now_ts
            samples = []
            state["samples"] = samples

        total_rate_bps = 0.0
        downlink_rate_bps = 0.0
        uplink_rate_bps = 0.0
        delta_seconds = max(0.0, now_ts - last_sample_ts)
        if delta_seconds > 0:
            if supports_split:
                down_delta = downlink_bytes - last_downlink_bytes
                up_delta = uplink_bytes - last_uplink_bytes
                if down_delta >= 0:
                    downlink_rate_bps = max(0.0, down_delta / delta_seconds)
                if up_delta >= 0:
                    uplink_rate_bps = max(0.0, up_delta / delta_seconds)
                total_rate_bps = max(0.0, downlink_rate_bps + uplink_rate_bps)
            else:
                delta_bytes = total_bytes - last_total_bytes
                if delta_bytes >= 0:
                    total_rate_bps = max(0.0, delta_bytes / delta_seconds)

        sample = {
            "ts": int(now_ts),
            "rate_bps": int(round(total_rate_bps)),
            "total_rate_bps": int(round(total_rate_bps)),
            "down_rate_bps": int(round(downlink_rate_bps)),
            "up_rate_bps": int(round(uplink_rate_bps)),
        }
        if samples and int(samples[-1].get("ts") or 0) == sample["ts"]:
            samples[-1] = sample
        else:
            samples.append(sample)

        cutoff = int(now_ts - TRAFFIC_MAX_WINDOW_SECONDS)
        filtered = [item for item in samples if int(item.get("ts") or 0) >= cutoff]
        if len(filtered) > TRAFFIC_MAX_POINTS:
            filtered = filtered[-TRAFFIC_MAX_POINTS:]
        state["samples"] = filtered
        state["last_total_bytes"] = total_bytes
        state["last_downlink_bytes"] = downlink_bytes
        state["last_uplink_bytes"] = uplink_bytes
        state["last_sample_ts"] = now_ts
        state["last_seen_at"] = now_ts
        state["source_key"] = source_key

        current_rate_bps = int(round(total_rate_bps))
        current_down_rate_bps = int(round(downlink_rate_bps))
        current_up_rate_bps = int(round(uplink_rate_bps))
        active = current_rate_bps > 0
        return {
            "ok": True,
            "active": active,
            "source": source,
            "source_text": source_text,
            "supports_split": supports_split,
            "sample_interval_seconds": TRAFFIC_SAMPLE_INTERVAL_SECONDS,
            "window_seconds": TRAFFIC_MAX_WINDOW_SECONDS,
            "default_window_seconds": TRAFFIC_WINDOW_SECONDS,
            "available_windows": [60, 300, 900],
            "current_rate_bps": current_rate_bps,
            "current_rate_text": _human_rate(total_rate_bps),
            "current_down_rate_bps": current_down_rate_bps,
            "current_down_rate_text": _human_rate(downlink_rate_bps),
            "current_up_rate_bps": current_up_rate_bps,
            "current_up_rate_text": _human_rate(uplink_rate_bps),
            "points": filtered,
        }


def _import_label_key(label: str) -> str:
    normalized = "".join(ch.lower() if ch.isalnum() else "-" for ch in str(label or "").strip())
    while "--" in normalized:
        normalized = normalized.replace("--", "-")
    return normalized.strip("-") or "mode"


def _default_import_key(items: list[dict[str, str]]) -> str:
    if not items:
        return "mode"
    priority = ("websocket", "tcp-tls", "httpupgrade", "xhttp", "grpc")
    keyed = {str(item.get("label") or "").strip(): _import_label_key(str(item.get("label") or "")) for item in items}
    for preferred in priority:
        for label, key in keyed.items():
            if key == preferred:
                return key
    first = str(items[0].get("label") or "").strip()
    return keyed.get(first, "mode")


def _render_import_tabs(summary: dict) -> str:
    raw_items = summary.get("import_links")
    if not isinstance(raw_items, list):
        return ""
    items: list[dict[str, str]] = []
    for item in raw_items:
        if not isinstance(item, dict):
            continue
        label = str(item.get("label") or "").strip()
        url = str(item.get("url") or "").strip()
        if not label or not url:
            continue
        items.append({"label": label, "url": url, "key": _import_label_key(label)})
    if not items:
        return ""
    active_key = _default_import_key(items)
    tabs = []
    panes = []
    for item in items:
        key = item["key"]
        label = item["label"]
        url = item["url"]
        active_class = " is-active" if key == active_key else ""
        hidden_attr = "" if key == active_key else " hidden"
        tabs.append(
            f"""          <button class="import-tab{active_class}" type="button" data-import-key="{_escape(key)}" role="tab" aria-selected="{"true" if key == active_key else "false"}">{_escape(label)}</button>"""
        )
        panes.append(
            f"""          <section class="import-pane{active_class}" data-import-pane="{_escape(key)}"{hidden_attr}>
            <div class="import-pane-head">
              <div>
                <p class="import-kicker">Mode Aktif</p>
                <h3>{_escape(label)}</h3>
              </div>
              <button class="copy-btn copy-btn-strong" type="button" data-copy={url!r}>Copy Link</button>
            </div>
            <p class="import-helper">Gunakan link ini untuk mode <strong>{_escape(label)}</strong>.</p>
            <code>{_escape(url)}</code>
          </section>"""
        )
    return """      <article class="card import-card" id="import-card" data-active-import-key=\"""" + _escape(active_key) + """\">
        <div class="section-head">
          <h2>Link Import</h2>
          <p>Pilih mode yang ingin dipakai.</p>
        </div>
        <div class="import-tabs" id="import-tabs" role="tablist">
""" + "\n".join(tabs) + """
        </div>
        <div class="import-stage" id="import-stage">
""" + "\n".join(panes) + """
        </div>
      </article>"""


def _render_access_details(summary: dict) -> str:
    items = summary.get("access_details")
    if not isinstance(items, list):
        return ""
    port_rows: list[str] = []
    path_rows: list[str] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        label = str(item.get("label") or "").strip()
        value = str(item.get("value") or "").strip()
        if not label or not value:
            continue
        row = f"""            <div class="access-stat">
              <dt>{_escape(label)}</dt>
              <dd>{_escape(value)}</dd>
            </div>"""
        if "Path" in label or "Service" in label:
            path_rows.append(row)
        else:
            port_rows.append(row)
    if not port_rows and not path_rows:
        return ""
    groups: list[str] = []
    if port_rows:
        groups.append(
            """        <section class="access-group">
          <p class="access-group-title">Port</p>
          <dl class="access-group-grid">
"""
            + "\n".join(port_rows)
            + """
          </dl>
        </section>"""
        )
    if path_rows:
        groups.append(
            """        <section class="access-group">
          <p class="access-group-title">Path & Service</p>
          <dl class="access-group-grid">
"""
            + "\n".join(path_rows)
            + """
          </dl>
        </section>"""
        )
    return """
        <div class="access-cluster" id="access-detail-grid">
""" + "\n".join(groups) + """
        </div>"""


def _render_account_portal(summary: dict, device: str = "desktop") -> str:
    status_class = _status_badge_class(str(summary.get("status") or ""))
    status_value = str(summary.get("status") or "-").strip() or "-"
    token = str(summary.get("token") or "").strip()
    active_ip_last_seen = str(summary.get("active_ip_last_seen_at") or "-").strip() or "-"
    days_remaining = summary.get("days_remaining")
    days_label = f"{days_remaining} hari" if isinstance(days_remaining, int) and days_remaining >= 0 else "-"
    active_ip = str(summary.get("active_ip") or "-").strip() or "-"
    active_ip_hint = _active_ip_hint(active_ip, active_ip_last_seen)
    quota_percent = _quota_percent(summary)
    quota_state_label, quota_state_class, usage_tone = _quota_state(quota_percent)
    action_tone, action_text = _next_action(summary, quota_percent)
    ip_limit_text = str(summary.get("ip_limit_text") or "OFF").strip() or "OFF"
    speed_limit_text = str(summary.get("speed_limit_text") or "OFF").strip() or "OFF"
    access_domain = str(summary.get("access_domain") or "-").strip() or "-"
    protocol_badge = _protocol_badge(summary)
    protocol_label = _protocol_label(summary)
    show_problem_state = status_value in {"blocked", "expired"}
    import_links_html = _render_import_tabs(summary)
    access_details_html = _render_access_details(summary)
    return f"""<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,nofollow,noarchive">
  <title>Info Akun</title>
  <script>
    (() => {{
      const key = "autoscript-account-portal-theme";
      try {{
        const stored = localStorage.getItem(key);
        const preference = stored === "light" || stored === "dark" || stored === "system" ? stored : "system";
        const media = window.matchMedia("(prefers-color-scheme: dark)");
        const effective = preference === "system" ? (media.matches ? "dark" : "light") : preference;
        document.documentElement.dataset.theme = effective;
        document.documentElement.dataset.themePreference = preference;
      }} catch (_err) {{
        document.documentElement.dataset.theme = "dark";
        document.documentElement.dataset.themePreference = "system";
      }}
    }})();
  </script>
  <style>
    :root {{
      --bg: #120f0b;
      --bg-end: #0c0a08;
      --panel: #19140f;
      --text: #f4ede4;
      --text-strong: #fff1e3;
      --text-soft: #ffe7d2;
      --text-accent: #f8d4b7;
      --text-accent-strong: #ffd6b6;
      --text-heading: #f7d1b2;
      --muted: #b8ab9b;
      --accent: #d66b22;
      --accent-2: #f2b24f;
      --accent-contrast: #1b120b;
      --ok: #1e9b62;
      --warn: #d59b1b;
      --bad: #c84d45;
      --stroke: rgba(255,255,255,0.08);
      --shadow: 0 24px 80px rgba(0,0,0,0.25);
      --shadow-hover: 0 16px 42px rgba(0,0,0,0.18);
      --surface-soft: rgba(255,255,255,0.025);
      --surface-base: rgba(255,255,255,0.03);
      --surface-strong: rgba(255,255,255,0.04);
      --surface-deep: rgba(0,0,0,0.18);
      --surface-chart: rgba(0,0,0,0.12);
      --border-soft: rgba(255,255,255,0.06);
      --hero-top-glow: rgba(255,255,255,0.09);
      --hero-side-glow: rgba(214,107,34,0.12);
      --page-aurora-1: rgba(214,107,34,0.18);
      --page-aurora-2: rgba(242,178,79,0.14);
      --page-aurora-3: rgba(255,255,255,0.06);
      --page-aurora-4: rgba(255,255,255,0.05);
      --page-aurora-5: rgba(214,107,34,0.10);
      --body-blob-1-core: rgba(214,107,34,0.24);
      --body-blob-1-soft: rgba(214,107,34,0.04);
      --body-blob-2-core: rgba(242,178,79,0.18);
      --body-blob-2-soft: rgba(242,178,79,0.05);
      --main-blob-1-core: rgba(255,255,255,0.10);
      --main-blob-1-soft: rgba(255,255,255,0.03);
      --main-blob-2-core: rgba(214,107,34,0.14);
      --main-blob-2-soft: rgba(214,107,34,0.04);
      --brand-border: rgba(214,107,34,0.35);
      --brand-bg: rgba(214,107,34,0.14);
      --brand-border-soft: rgba(214,107,34,0.24);
      --brand-border-strong: rgba(214,107,34,0.48);
      --brand-bg-soft: rgba(214,107,34,0.12);
      --brand-bg-strong: rgba(214,107,34,0.18);
      --brand-shadow: rgba(214,107,34,0.18);
      --brand-shadow-soft: rgba(214,107,34,0.12);
      --ok-text: #bff2d8;
      --ok-bg: rgba(30,155,98,0.14);
      --ok-border: rgba(30,155,98,0.35);
      --warn-text: #ffdf91;
      --warn-bg: rgba(213,155,27,0.14);
      --warn-border: rgba(213,155,27,0.35);
      --bad-text: #ffbeb9;
      --bad-bg: rgba(200,77,69,0.14);
      --bad-border: rgba(200,77,69,0.35);
      --problem-strong: #fff1c2;
      --problem-bad-strong: #ffe2de;
      --chart-grid: rgba(255,255,255,0.06);
      --chart-fill-top: rgba(214,107,34,0.26);
      --chart-fill-bottom: rgba(214,107,34,0);
      --chart-line-a: #f2b24f;
      --chart-line-b: #d66b22;
      --chart-down-fill-top: rgba(242,178,79,0.20);
      --chart-down-fill-bottom: rgba(242,178,79,0.02);
      --chart-down-line: #f2b24f;
      --chart-up-fill-top: rgba(214,107,34,0.16);
      --chart-up-fill-bottom: rgba(214,107,34,0.01);
      --chart-up-line: #d66b22;
      --chart-point: #fff1e3;
      --chart-ring: rgba(255,241,227,0.24);
      --chart-text: rgba(255,241,227,0.78);
      --chart-burst: rgba(242,178,79,0.16);
    }}
    html[data-theme="dark"] {{
      color-scheme: dark;
    }}
    html[data-theme="light"] {{
      color-scheme: light;
      --bg: #faf5ee;
      --bg-end: #f2e7db;
      --panel: rgba(255,255,255,0.93);
      --text: #281a11;
      --text-strong: #120b07;
      --text-soft: #2d1d12;
      --text-accent: #67350f;
      --text-accent-strong: #5b2c0a;
      --text-heading: #62310d;
      --muted: #554334;
      --accent: #9f4e1a;
      --accent-2: #d98f36;
      --accent-contrast: #fff8f1;
      --stroke: rgba(77,44,18,0.18);
      --shadow: 0 24px 70px rgba(133,95,54,0.16);
      --shadow-hover: 0 16px 36px rgba(133,95,54,0.14);
      --surface-soft: rgba(255,255,255,0.72);
      --surface-base: rgba(255,255,255,0.82);
      --surface-strong: rgba(255,255,255,0.94);
      --surface-deep: rgba(255,255,255,0.88);
      --surface-chart: rgba(255,255,255,0.84);
      --border-soft: rgba(77,44,18,0.14);
      --hero-top-glow: rgba(255,255,255,0.28);
      --hero-side-glow: rgba(214,107,34,0.08);
      --page-aurora-1: rgba(214,107,34,0.08);
      --page-aurora-2: rgba(242,178,79,0.06);
      --page-aurora-3: rgba(255,255,255,0.24);
      --page-aurora-4: rgba(255,255,255,0.16);
      --page-aurora-5: rgba(214,107,34,0.04);
      --body-blob-1-core: rgba(214,107,34,0.08);
      --body-blob-1-soft: rgba(214,107,34,0.01);
      --body-blob-2-core: rgba(242,178,79,0.07);
      --body-blob-2-soft: rgba(242,178,79,0.01);
      --main-blob-1-core: rgba(255,255,255,0.34);
      --main-blob-1-soft: rgba(255,255,255,0.03);
      --main-blob-2-core: rgba(214,107,34,0.04);
      --main-blob-2-soft: rgba(214,107,34,0.01);
      --brand-border: rgba(180,91,31,0.24);
      --brand-bg: rgba(180,91,31,0.10);
      --brand-border-soft: rgba(180,91,31,0.18);
      --brand-border-strong: rgba(180,91,31,0.34);
      --brand-bg-soft: rgba(180,91,31,0.08);
      --brand-bg-strong: rgba(180,91,31,0.12);
      --brand-shadow: rgba(180,91,31,0.10);
      --brand-shadow-soft: rgba(180,91,31,0.08);
      --ok-text: #1b7a4d;
      --ok-bg: rgba(30,155,98,0.10);
      --ok-border: rgba(30,155,98,0.22);
      --warn-text: #9c6a00;
      --warn-bg: rgba(213,155,27,0.10);
      --warn-border: rgba(213,155,27,0.24);
      --bad-text: #a63d36;
      --bad-bg: rgba(200,77,69,0.10);
      --bad-border: rgba(200,77,69,0.20);
      --problem-strong: #8a5600;
      --problem-bad-strong: #98352d;
      --chart-grid: rgba(77,44,18,0.14);
      --chart-fill-top: rgba(180,91,31,0.14);
      --chart-fill-bottom: rgba(180,91,31,0);
      --chart-line-a: #d98f36;
      --chart-line-b: #9f4e1a;
      --chart-down-fill-top: rgba(217,143,54,0.14);
      --chart-down-fill-bottom: rgba(217,143,54,0.01);
      --chart-down-line: #c87620;
      --chart-up-fill-top: rgba(159,78,26,0.12);
      --chart-up-fill-bottom: rgba(159,78,26,0.01);
      --chart-up-line: #8a4319;
      --chart-point: #2d1d12;
      --chart-ring: rgba(45,29,18,0.18);
      --chart-text: rgba(77,44,18,0.72);
      --chart-burst: rgba(200,118,32,0.12);
    }}
    html[data-theme="light"] .sub,
    html[data-theme="light"] .note,
    html[data-theme="light"] .section-head p,
    html[data-theme="light"] .import-helper,
    html[data-theme="light"] .theme-option-note,
    html[data-theme="light"] .spotlight-card span,
    html[data-theme="light"] .traffic-foot span,
    html[data-theme="light"] .traffic-state p {{
      color: var(--muted);
    }}
    html[data-theme="light"] .action-banner.info {{
      color: var(--text-soft);
      background: rgba(255,255,255,0.90);
      border-color: rgba(77,44,18,0.14);
    }}
    html[data-theme="light"] .card {{
      background: linear-gradient(180deg, rgba(255,255,255,0.98), rgba(255,255,255,0.92));
      border-color: rgba(77,44,18,0.18);
      box-shadow: 0 14px 34px rgba(133,95,54,0.12);
    }}
    html[data-theme="light"] .card::before {{
      background: linear-gradient(160deg, rgba(255,255,255,0.32), transparent 42%);
      opacity: 0.34;
    }}
    html[data-theme="light"] .card h2,
    html[data-theme="light"] .section-head h2 {{
      color: var(--text-heading);
      letter-spacing: 0.10em;
    }}
    html[data-theme="light"] dt,
    html[data-theme="light"] .traffic-kicker,
    html[data-theme="light"] .access-group-title,
    html[data-theme="light"] .import-kicker,
    html[data-theme="light"] .eyebrow {{
      color: var(--text-accent-strong);
    }}
    html[data-theme="light"] dd,
    html[data-theme="light"] .traffic-rate,
    html[data-theme="light"] .spotlight-card strong,
    html[data-theme="light"] .import-pane-head h3 {{
      color: var(--text-strong);
    }}
    html[data-theme="light"] .value-sub,
    html[data-theme="light"] .quota-row,
    html[data-theme="light"] .traffic-meta,
    html[data-theme="light"] .access-stat {{
      color: var(--text-soft);
    }}
    html[data-theme="light"] .quota-pill,
    html[data-theme="light"] .traffic-live-pill {{
      border-color: rgba(77,44,18,0.14);
      background: rgba(255,255,255,0.86);
    }}
    html[data-theme="light"] .traffic-mini,
    html[data-theme="light"] .traffic-range {{
      background: linear-gradient(180deg, rgba(255,255,255,0.92), rgba(255,248,241,0.9));
    }}
    html[data-theme="light"] .traffic-card {{
      background:
        radial-gradient(circle at top left, rgba(180,91,31,0.05), transparent 40%),
        linear-gradient(180deg, rgba(255,255,255,0.98), rgba(255,255,255,0.92));
    }}
    html[data-theme="light"] .import-card {{
      background:
        radial-gradient(circle at top right, rgba(180,91,31,0.04), transparent 36%),
        linear-gradient(180deg, rgba(255,255,255,0.98), rgba(255,255,255,0.92));
    }}
    html[data-theme="light"] body::before,
    html[data-theme="light"] body::after {{
      opacity: 0.16;
    }}
    html[data-theme="light"] main::before,
    html[data-theme="light"] main::after {{
      opacity: 0.10;
    }}
    html[data-theme="light"] .hero::before {{
      opacity: 0.36;
    }}
    html[data-theme="light"] .import-pane code,
    html[data-theme="light"] .traffic-chart-wrap,
    html[data-theme="light"] .spotlight-card,
    html[data-theme="light"] .access-group {{
      border-color: rgba(77,44,18,0.12);
    }}
    html[data-theme="light"] .traffic-tooltip {{
      background: rgba(255,252,248,0.96);
      color: #4d2c12;
      border-color: rgba(151,94,49,0.18);
      box-shadow: 0 16px 36px rgba(77,44,18,0.14);
    }}
    html[data-theme="light"] .traffic-tooltip strong {{
      color: #2f1c11;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at 12% 8%, var(--page-aurora-1), transparent 28%),
        radial-gradient(circle at 82% 16%, var(--page-aurora-2), transparent 24%),
        radial-gradient(circle at 50% 22%, var(--page-aurora-3), transparent 18%),
        radial-gradient(circle at 18% 78%, var(--page-aurora-4), transparent 22%),
        radial-gradient(circle at 78% 82%, var(--page-aurora-5), transparent 26%),
        linear-gradient(180deg, var(--bg) 0%, var(--bg-end) 100%);
      color: var(--text);
      overflow-x: hidden;
    }}
    body::before,
    body::after {{
      content: "";
      position: fixed;
      inset: auto;
      width: 520px;
      height: 520px;
      border-radius: 999px;
      filter: blur(72px);
      pointer-events: none;
      opacity: 0.34;
      z-index: 0;
    }}
    body::before {{
      top: -6%;
      right: -140px;
      background: radial-gradient(circle, var(--body-blob-1-core) 0%, var(--body-blob-1-soft) 58%, transparent 74%);
      animation: auroraFloatA 18s ease-in-out infinite;
    }}
    body::after {{
      left: -180px;
      bottom: -12%;
      background: radial-gradient(circle, var(--body-blob-2-core) 0%, var(--body-blob-2-soft) 54%, transparent 76%);
      animation: auroraFloatB 22s ease-in-out infinite;
    }}
    main {{
      max-width: 920px;
      margin: 0 auto;
      padding: 28px 18px 40px;
      position: relative;
      z-index: 1;
      isolation: isolate;
    }}
    main::before,
    main::after {{
      content: "";
      position: absolute;
      border-radius: 999px;
      pointer-events: none;
      z-index: -1;
      filter: blur(54px);
      opacity: 0.24;
    }}
    main::before {{
      top: 40px;
      left: 14%;
      width: 340px;
      height: 340px;
      background: radial-gradient(circle, var(--main-blob-1-core) 0%, var(--main-blob-1-soft) 50%, transparent 74%);
      animation: auroraPulse 16s ease-in-out infinite;
    }}
    main::after {{
      right: 6%;
      bottom: 120px;
      width: 400px;
      height: 400px;
      background: radial-gradient(circle, var(--main-blob-2-core) 0%, var(--main-blob-2-soft) 55%, transparent 76%);
      animation: auroraFloatB 20s ease-in-out infinite reverse;
    }}
    .hero {{
      padding: 22px 22px 18px;
      border: 1px solid var(--stroke);
      border-radius: 24px;
      background: linear-gradient(180deg, var(--surface-strong), var(--surface-soft));
      box-shadow: var(--shadow);
      position: relative;
      overflow: hidden;
      animation: riseIn 700ms cubic-bezier(.2,.8,.2,1) both;
    }}
    .hero::before {{
      content: "";
      position: absolute;
      inset: 0;
      background:
        radial-gradient(circle at 12% 0%, var(--hero-top-glow), transparent 34%),
        radial-gradient(circle at 84% 18%, var(--hero-side-glow), transparent 30%);
      animation: auroraPulse 18s ease-in-out infinite;
      opacity: 0.72;
      pointer-events: none;
    }}
    .hero-topbar {{
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 4px;
    }}
    .eyebrow {{
      margin: 0;
      font-size: 12px;
      letter-spacing: 0.18em;
      text-transform: uppercase;
      color: var(--accent);
      font-weight: 700;
    }}
    h1 {{
      margin: 0;
      font-size: clamp(2rem, 6vw, 3rem);
      line-height: 0.98;
    }}
    .sub {{
      margin: 10px 0 0;
      color: var(--muted);
      max-width: 46rem;
      line-height: 1.6;
    }}
    .hero-grid {{
      display: grid;
      grid-template-columns: minmax(0, 1.4fr) minmax(260px, 0.9fr);
      gap: 18px;
      align-items: end;
    }}
    .status-row {{
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
      margin-top: 18px;
    }}
    .theme-menu {{
      position: relative;
      display: inline-flex;
      justify-content: flex-end;
    }}
    .theme-menu-btn {{
      appearance: none;
      border: 1px solid var(--stroke);
      background: var(--surface-base);
      color: var(--text);
      padding: 10px 14px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 800;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      cursor: pointer;
      transition: background 140ms ease, color 140ms ease, transform 140ms ease, box-shadow 140ms ease, border-color 140ms ease;
      display: inline-flex;
      align-items: center;
      gap: 10px;
      backdrop-filter: blur(18px);
      box-shadow: 0 12px 28px rgba(0,0,0,0.10);
    }}
    .theme-menu-btn::after {{
      content: "";
      width: 9px;
      height: 9px;
      border-right: 2px solid currentColor;
      border-bottom: 2px solid currentColor;
      transform: rotate(45deg) translateY(-1px);
      opacity: 0.72;
      transition: transform 140ms ease, opacity 140ms ease;
    }}
    .theme-menu-btn:hover {{
      color: var(--text);
      transform: translateY(-1px);
      border-color: var(--brand-border-soft);
    }}
    .theme-menu-btn:focus-visible {{
      outline: none;
      border-color: var(--brand-border-strong);
      box-shadow: 0 0 0 3px var(--brand-bg-soft), 0 12px 28px rgba(0,0,0,0.10);
    }}
    .theme-menu.is-open .theme-menu-btn::after {{
      transform: rotate(225deg) translateY(-1px);
      opacity: 1;
    }}
    .theme-popover {{
      position: absolute;
      top: calc(100% + 10px);
      right: 0;
      width: min(220px, calc(100vw - 32px));
      padding: 10px;
      border-radius: 18px;
      border: 1px solid var(--stroke);
      background: linear-gradient(180deg, var(--surface-strong), var(--surface-soft));
      box-shadow: 0 18px 44px rgba(0,0,0,0.16);
      display: grid;
      gap: 6px;
      z-index: 5;
      backdrop-filter: blur(18px);
    }}
    .theme-popover[hidden] {{
      display: none;
    }}
    .theme-option {{
      appearance: none;
      width: 100%;
      border: 0;
      background: transparent;
      color: var(--muted);
      padding: 12px 14px;
      border-radius: 14px;
      font-size: 13px;
      font-weight: 700;
      text-align: left;
      cursor: pointer;
      display: grid;
      gap: 3px;
      transition: background 140ms ease, color 140ms ease, transform 140ms ease;
    }}
    .theme-option:hover {{
      transform: translateY(-1px);
      color: var(--text);
      background: var(--surface-base);
    }}
    .theme-option:focus-visible {{
      outline: none;
      color: var(--text);
      background: var(--surface-base);
      box-shadow: inset 0 0 0 2px var(--brand-border-strong);
    }}
    .theme-option-label {{
      color: inherit;
    }}
    .theme-option-note {{
      color: var(--muted);
      font-size: 12px;
      line-height: 1.4;
      font-weight: 600;
    }}
    .theme-option.is-active {{
      color: var(--accent-contrast);
      background: linear-gradient(90deg, var(--accent) 0%, var(--accent-2) 100%);
      box-shadow: 0 10px 22px var(--brand-shadow);
    }}
    .theme-option.is-active .theme-option-note {{
      color: rgba(255, 248, 241, 0.78);
    }}
    .protocol-chip {{
      display: inline-flex;
      align-items: center;
      padding: 10px 14px;
      border-radius: 999px;
      border: 1px solid var(--brand-border);
      background: var(--brand-bg);
      color: var(--text-accent-strong);
      font-weight: 800;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      font-size: 12px;
      box-shadow: 0 0 0 1px var(--brand-bg-soft) inset;
    }}
    .status-badge {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 10px 14px;
      border-radius: 999px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      font-size: 12px;
      border: 1px solid transparent;
    }}
    .status-badge.ok {{ color: var(--ok-text); background: var(--ok-bg); border-color: var(--ok-border); }}
    .status-badge.warn {{ color: var(--warn-text); background: var(--warn-bg); border-color: var(--warn-border); }}
    .status-badge.bad {{ color: var(--bad-text); background: var(--bad-bg); border-color: var(--bad-border); }}
    .note {{
      margin: 0;
      color: var(--muted);
      line-height: 1.5;
    }}
    .action-banner {{
      margin-top: 16px;
      padding: 14px 16px;
      border-radius: 16px;
      border: 1px solid transparent;
      font-weight: 600;
      line-height: 1.6;
    }}
    .action-banner.ok {{ color: var(--ok-text); background: var(--ok-bg); border-color: var(--ok-border); }}
    .action-banner.info {{ color: var(--text-soft); background: var(--surface-strong); border-color: var(--stroke); }}
    .action-banner.warning {{ color: var(--warn-text); background: var(--warn-bg); border-color: var(--warn-border); }}
    .sync-state {{
      margin-top: 12px;
      padding: 11px 14px;
      border-radius: 14px;
      border: 1px solid var(--warn-border);
      background: var(--surface-soft);
      color: var(--warn-text);
      font-size: 13px;
      line-height: 1.55;
    }}
    .problem-state {{
      margin-top: 16px;
      padding: 16px;
      border-radius: 18px;
      border: 1px solid var(--warn-border);
      background: var(--warn-bg);
      color: var(--warn-text);
      line-height: 1.6;
    }}
    .problem-state strong {{
      display: block;
      margin-bottom: 4px;
      color: var(--problem-strong);
      font-size: 15px;
    }}
    .problem-state.bad {{
      border-color: var(--bad-border);
      background: var(--bad-bg);
      color: var(--bad-text);
    }}
    .problem-state.bad strong {{
      color: var(--problem-bad-strong);
    }}
    .spotlight {{
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 12px;
    }}
    .spotlight-card {{
      padding: 14px;
      border-radius: 18px;
      background: var(--surface-deep);
      border: 1px solid var(--stroke);
      min-width: 0;
      transition: transform 180ms ease, border-color 180ms ease, background 180ms ease;
      animation: riseIn 780ms cubic-bezier(.2,.8,.2,1) both;
    }}
    .spotlight-card:hover {{
      transform: translateY(-2px);
      border-color: var(--brand-border-soft);
      background: var(--surface-strong);
    }}
    .spotlight-card strong {{
      display: block;
      font-size: 28px;
      line-height: 1;
      margin-top: 8px;
      word-break: break-word;
    }}
    .spotlight-card span {{
      display: block;
      font-size: 12px;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }}
    .is-empty {{ color: var(--warn-text); }}
    .grid {{
      display: grid;
      grid-template-columns: repeat(6, minmax(0, 1fr));
      gap: 14px;
      margin-top: 18px;
    }}
    .summary-card {{
      grid-column: span 2;
      order: 2;
    }}
    .quota-card {{
      grid-column: span 2;
      order: 3;
    }}
    .traffic-card {{
      grid-column: span 4;
      order: 1;
    }}
    .access-card {{
      grid-column: span 4;
      order: 4;
    }}
    .import-card {{
      grid-column: 1 / -1;
      order: 5;
    }}
    .card {{
      padding: 16px;
      border: 1px solid var(--stroke);
      border-radius: 18px;
      background: var(--panel);
      min-width: 0;
      position: relative;
      overflow: hidden;
      transition: transform 180ms ease, border-color 180ms ease, box-shadow 180ms ease;
      animation: riseIn 860ms cubic-bezier(.2,.8,.2,1) both;
    }}
    .card::before {{
      content: "";
      position: absolute;
      inset: 0;
      background: linear-gradient(160deg, var(--surface-strong), transparent 34%);
      pointer-events: none;
    }}
    .card:hover {{
      transform: translateY(-2px);
      border-color: var(--brand-border-soft);
      box-shadow: var(--shadow-hover);
    }}
    .card h2 {{
      margin: 0 0 14px;
      font-size: 15px;
      color: var(--text-heading);
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }}
    dl {{
      margin: 0;
      display: grid;
      gap: 12px;
    }}
    .metric {{
      display: grid;
      gap: 4px;
    }}
    dt {{
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }}
    dd {{
      margin: 0;
      font-size: 18px;
      font-weight: 700;
      word-break: break-word;
    }}
    .value-sub {{
      margin: 2px 0 0;
      color: var(--muted);
      font-size: 13px;
      line-height: 1.5;
    }}
    .quota-meter {{
      margin-top: 6px;
      display: grid;
      gap: 10px;
    }}
    .quota-bar {{
      position: relative;
      height: 14px;
      border-radius: 999px;
      overflow: hidden;
      border: 1px solid var(--stroke);
      background: var(--surface-base);
    }}
    .quota-bar > span {{
      display: block;
      height: 100%;
      width: {quota_percent}%;
      min-width: {("10px" if quota_percent > 0 else "0")};
      border-radius: inherit;
      background: linear-gradient(90deg, var(--accent) 0%, var(--accent-2) 100%);
      position: relative;
      overflow: hidden;
    }}
    .quota-bar > span::after {{
      content: "";
      position: absolute;
      inset: 0;
      background: linear-gradient(120deg, transparent 0%, rgba(255,255,255,0.26) 35%, transparent 70%);
      transform: translateX(-130%);
      animation: quotaShimmer 3s ease-in-out infinite;
    }}
    .quota-row {{
      display: flex;
      justify-content: space-between;
      gap: 12px;
      color: var(--muted);
      font-size: 13px;
    }}
    .quota-pill {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      width: fit-content;
      padding: 9px 12px;
      border-radius: 999px;
      border: 1px solid var(--stroke);
      background: var(--surface-base);
      color: var(--text-accent);
      font-size: 13px;
      font-weight: 700;
    }}
    .quota-summary-row {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      align-items: center;
    }}
    .quota-state {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      width: fit-content;
      padding: 9px 12px;
      border-radius: 999px;
      border: 1px solid transparent;
      font-size: 13px;
      font-weight: 700;
    }}
    .quota-state.ok {{ color: var(--ok-text); background: var(--ok-bg); border-color: var(--ok-border); }}
    .quota-state.warn {{ color: var(--warn-text); background: var(--warn-bg); border-color: var(--warn-border); }}
    .quota-state.bad {{ color: var(--bad-text); background: var(--bad-bg); border-color: var(--bad-border); }}
    .card-grid {{
      display: grid;
      gap: 14px;
    }}
    .section-head {{
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      gap: 10px 14px;
      align-items: baseline;
      margin-bottom: 14px;
    }}
    .section-head h2 {{
      margin: 0;
    }}
    .section-head p {{
      margin: 0;
      color: var(--muted);
      font-size: 13px;
      line-height: 1.5;
    }}
    .access-cluster {{
      display: grid;
      gap: 12px;
      margin-top: 14px;
    }}
    .access-group {{
      padding: 14px;
      border-radius: 16px;
      border: 1px solid var(--border-soft);
      background: var(--surface-soft);
    }}
    .access-group-title {{
      margin: 0 0 12px;
      color: var(--text-accent);
      font-size: 12px;
      font-weight: 800;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }}
    .access-group-grid {{
      display: grid;
      gap: 12px;
    }}
    .access-stat {{
      display: grid;
      gap: 4px;
      padding-top: 12px;
      border-top: 1px solid var(--border-soft);
    }}
    .access-stat:first-child {{
      padding-top: 0;
      border-top: 0;
    }}
    .import-card {{
      background:
        radial-gradient(circle at top right, var(--brand-bg-soft), transparent 36%),
        var(--panel);
    }}
    .import-tabs {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-bottom: 14px;
    }}
    .import-tab {{
      appearance: none;
      border: 1px solid var(--stroke);
      background: var(--surface-base);
      color: var(--muted);
      padding: 10px 14px;
      border-radius: 999px;
      font-size: 13px;
      font-weight: 700;
      cursor: pointer;
      transition: transform 140ms ease, border-color 140ms ease, background 140ms ease, color 140ms ease;
    }}
    .import-tab:hover {{
      transform: translateY(-1px);
      border-color: var(--brand-border-soft);
      color: var(--text-soft);
    }}
    .import-tab.is-active {{
      color: var(--accent-contrast);
      border-color: transparent;
      background: linear-gradient(90deg, var(--accent) 0%, var(--accent-2) 100%);
      box-shadow: 0 10px 24px var(--brand-shadow);
    }}
    .import-stage {{
      display: grid;
    }}
    .import-pane {{
      display: grid;
      gap: 12px;
      padding: 18px;
      border-radius: 20px;
      border: 1px solid var(--brand-bg);
      background:
        radial-gradient(circle at top right, var(--brand-bg), transparent 38%),
        linear-gradient(180deg, var(--surface-strong), var(--surface-soft));
      box-shadow: 0 18px 44px rgba(0,0,0,0.18);
      animation: riseIn 220ms ease both;
    }}
    .import-pane[hidden] {{
      display: none;
    }}
    .import-pane-head {{
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      justify-content: space-between;
      align-items: flex-start;
    }}
    .import-pane-head h3 {{
      margin: 4px 0 0;
      font-size: 22px;
      line-height: 1;
      color: var(--text-strong);
    }}
    .import-kicker {{
      margin: 0;
      color: var(--text-accent);
      font-size: 12px;
      font-weight: 800;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }}
    .import-helper {{
      margin: 0;
      color: var(--muted);
      font-size: 13px;
      line-height: 1.6;
    }}
    .import-helper strong {{
      color: var(--text-soft);
    }}
    .import-pane code {{
      display: block;
      padding: 16px;
      border-radius: 14px;
      background: var(--surface-deep);
      border: 1px solid var(--stroke);
      line-height: 1.6;
    }}
    .import-links {{
      display: grid;
      gap: 14px;
      margin-top: 10px;
    }}
    .import-item {{
      display: grid;
      gap: 6px;
      padding: 12px 0;
      border-top: 1px solid var(--border-soft);
    }}
    .import-item:first-child {{
      padding-top: 0;
      border-top: 0;
    }}
    .import-item dd {{
      display: grid;
      gap: 10px;
    }}
    .copy-btn {{
      width: fit-content;
      padding: 8px 12px;
      border-radius: 999px;
      border: 1px solid var(--brand-border);
      background: var(--brand-bg-soft);
      color: var(--text-accent-strong);
      font-weight: 700;
      cursor: pointer;
      transition: transform 140ms ease, border-color 140ms ease, background 140ms ease;
    }}
    .copy-btn:hover {{
      transform: translateY(-1px);
      border-color: var(--brand-border-strong);
      background: var(--brand-bg-strong);
    }}
    .copy-btn.is-done {{
      color: var(--ok-text);
      border-color: var(--ok-border);
      background: var(--ok-bg);
    }}
    .copy-btn-strong {{
      padding: 10px 16px;
      border-color: var(--brand-border-strong);
      background: linear-gradient(90deg, var(--brand-bg-strong), rgba(242,178,79,0.18));
      color: var(--text-strong);
      box-shadow: 0 10px 24px var(--brand-shadow-soft);
    }}
    .traffic-card {{
      background:
        radial-gradient(circle at top left, var(--brand-bg), transparent 36%),
        linear-gradient(180deg, var(--surface-strong), var(--surface-soft));
    }}
    .traffic-toolbar {{
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      align-items: center;
      gap: 10px;
      margin-bottom: 12px;
    }}
    .traffic-range {{
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 6px;
      border-radius: 999px;
      border: 1px solid var(--stroke);
      background: var(--surface-base);
      box-shadow: inset 0 1px 0 var(--surface-strong);
    }}
    .traffic-range-btn {{
      border: 0;
      background: transparent;
      color: var(--muted);
      border-radius: 999px;
      padding: 8px 12px;
      font-size: 12px;
      font-weight: 800;
      letter-spacing: 0.04em;
      cursor: pointer;
      transition: background 140ms ease, color 140ms ease, transform 140ms ease;
    }}
    .traffic-range-btn:hover {{
      color: var(--text-strong);
      transform: translateY(-1px);
    }}
    .traffic-range-btn.is-active {{
      background: linear-gradient(90deg, var(--brand-bg-strong), rgba(242,178,79,0.12));
      color: var(--text-strong);
      box-shadow: 0 10px 22px var(--brand-shadow-soft);
    }}
    .traffic-head {{
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 12px;
    }}
    .traffic-split,
    .traffic-stat-row {{
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
    }}
    .traffic-stat-row {{
      grid-template-columns: repeat(3, minmax(0, 1fr));
      margin-bottom: 12px;
    }}
    .traffic-mini {{
      min-width: 0;
      padding: 12px 14px;
      border-radius: 16px;
      border: 1px solid var(--stroke);
      background: linear-gradient(180deg, var(--surface-strong), var(--surface-soft));
      box-shadow: inset 0 1px 0 var(--surface-strong);
    }}
    .traffic-mini span {{
      display: block;
      margin-bottom: 6px;
      color: var(--muted);
      font-size: 11px;
      font-weight: 800;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }}
    .traffic-mini strong {{
      display: block;
      color: var(--text-strong);
      font-size: 17px;
      line-height: 1.2;
      letter-spacing: -0.02em;
    }}
    .traffic-kicker {{
      margin: 0 0 6px;
      color: var(--text-accent);
      font-size: 12px;
      font-weight: 800;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }}
    .traffic-rate {{
      margin: 0;
      font-size: 30px;
      line-height: 1;
      color: var(--text-strong);
      letter-spacing: -0.03em;
    }}
    .traffic-live-pill {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 10px 14px;
      border-radius: 999px;
      border: 1px solid var(--stroke);
      background: var(--surface-base);
      color: var(--muted);
      font-size: 13px;
      font-weight: 700;
    }}
    .traffic-live-pill::before {{
      content: "";
      width: 9px;
      height: 9px;
      border-radius: 999px;
      background: rgba(255,255,255,0.2);
      box-shadow: 0 0 0 0 rgba(255,255,255,0.16);
    }}
    .traffic-live-pill.live {{
      color: var(--ok-text);
      border-color: var(--ok-border);
      background: var(--ok-bg);
    }}
    .traffic-live-pill.live::before {{
      background: #3ed68e;
      box-shadow: 0 0 0 8px rgba(62,214,142,0.12);
    }}
    .traffic-live-pill.idle {{
      color: var(--warn-text);
      border-color: var(--warn-border);
      background: var(--warn-bg);
    }}
    .traffic-live-pill.idle::before {{
      background: #e6b437;
      box-shadow: 0 0 0 8px rgba(230,180,55,0.10);
    }}
    .traffic-chart-wrap {{
      position: relative;
      overflow: hidden;
      border-radius: 20px;
      border: 1px solid var(--stroke);
      background:
        linear-gradient(180deg, var(--surface-strong), rgba(255,255,255,0.015)),
        var(--surface-chart);
      box-shadow: inset 0 1px 0 var(--surface-strong);
    }}
    .traffic-chart-wrap::before {{
      content: "";
      position: absolute;
      inset: 0;
      background:
        linear-gradient(180deg, var(--surface-soft), transparent 32%),
        radial-gradient(circle at top right, var(--brand-bg-soft), transparent 34%);
      pointer-events: none;
    }}
    .traffic-chart {{
      display: block;
      width: 100%;
      height: 220px;
    }}
    .traffic-tooltip {{
      position: absolute;
      min-width: 140px;
      max-width: 220px;
      padding: 10px 12px;
      border-radius: 14px;
      border: 1px solid var(--stroke);
      background: rgba(25, 16, 10, 0.94);
      color: #fff4e8;
      font-size: 12px;
      line-height: 1.45;
      box-shadow: 0 14px 36px rgba(0,0,0,0.28);
      pointer-events: none;
      z-index: 2;
      transform: translate(-50%, calc(-100% - 14px));
      backdrop-filter: blur(10px);
    }}
    .traffic-tooltip strong {{
      display: block;
      margin-bottom: 4px;
      color: #fff;
      font-size: 12px;
      letter-spacing: 0.02em;
    }}
    .traffic-burst-pill {{
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      padding: 10px 14px;
      border-radius: 999px;
      border: 1px solid var(--brand-border);
      background: var(--chart-burst);
      color: var(--text-accent-strong);
      font-size: 12px;
      font-weight: 800;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }}
    .traffic-burst-pill::before {{
      content: "";
      width: 8px;
      height: 8px;
      border-radius: 999px;
      background: var(--accent-2);
      box-shadow: 0 0 0 8px rgba(242,178,79,0.08);
    }}
    .traffic-meta {{
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      gap: 10px;
      margin-top: 12px;
      color: var(--muted);
      font-size: 12px;
      line-height: 1.5;
    }}
    code {{
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      color: var(--text-soft);
      word-break: break-all;
    }}
    @keyframes riseIn {{
      from {{
        opacity: 0;
        transform: translateY(18px);
      }}
      to {{
        opacity: 1;
        transform: translateY(0);
      }}
    }}
    @keyframes auroraFloatA {{
      0%, 100% {{ transform: translate3d(0, 0, 0) scale(1); opacity: 0.30; }}
      33% {{ transform: translate3d(18px, -12px, 0) scale(1.08); opacity: 0.42; }}
      66% {{ transform: translate3d(-12px, 10px, 0) scale(0.96); opacity: 0.28; }}
    }}
    @keyframes auroraFloatB {{
      0%, 100% {{ transform: translate3d(0, 0, 0) scale(1); opacity: 0.26; }}
      45% {{ transform: translate3d(-22px, -16px, 0) scale(1.12); opacity: 0.36; }}
      70% {{ transform: translate3d(10px, 18px, 0) scale(0.94); opacity: 0.22; }}
    }}
    @keyframes auroraPulse {{
      0%, 100% {{ transform: scale(1); opacity: 0.18; }}
      50% {{ transform: scale(1.08); opacity: 0.30; }}
    }}
    @keyframes quotaShimmer {{
      0%, 100% {{ transform: translateX(-130%); }}
      48%, 68% {{ transform: translateX(135%); }}
    }}
    .hero .status-row > *:nth-child(1) {{ animation: riseIn 820ms cubic-bezier(.2,.8,.2,1) both; }}
    .hero .status-row > *:nth-child(2) {{ animation: riseIn 920ms cubic-bezier(.2,.8,.2,1) both; }}
    .hero .status-row > *:nth-child(3) {{ animation: riseIn 1020ms cubic-bezier(.2,.8,.2,1) both; }}
    .spotlight-card:nth-child(1) {{ animation-delay: 110ms; }}
    .spotlight-card:nth-child(2) {{ animation-delay: 180ms; }}
    .grid > .card:nth-child(1) {{ animation-delay: 120ms; }}
    .grid > .card:nth-child(2) {{ animation-delay: 200ms; }}
    .grid > .card:nth-child(3) {{ animation-delay: 280ms; }}
    .grid > .card:nth-child(4) {{ animation-delay: 360ms; }}
    @media (prefers-reduced-motion: reduce) {{
      *, *::before, *::after {{
        animation: none !important;
        transition: none !important;
        scroll-behavior: auto !important;
      }}
    }}
    @media (max-width: 720px) {{
      .hero-grid,
      .grid {{ grid-template-columns: 1fr; }}
      .spotlight {{ grid-template-columns: 1fr 1fr; }}
      main {{ padding: 18px 14px 28px; }}
      .hero {{ padding: 18px; border-radius: 20px; }}
      .card {{ border-radius: 16px; }}
      body::before,
      body::after {{ width: 360px; height: 360px; filter: blur(58px); }}
      main::before,
      main::after {{ width: 260px; height: 260px; filter: blur(46px); }}
    }}
    @media (max-width: 520px) {{
      .spotlight {{ grid-template-columns: 1fr; }}
      .spotlight-card strong {{ font-size: 24px; }}
      dd {{ font-size: 17px; }}
      .import-pane-head h3 {{ font-size: 20px; }}
    }}
    body[data-device="tablet"] main {{
      max-width: 860px;
      padding: 24px 16px 32px;
    }}
    body[data-device="tablet"] .hero-grid,
    body[data-device="tablet"] .grid {{
      grid-template-columns: 1fr;
    }}
    body[data-device="tablet"] .summary-card,
    body[data-device="tablet"] .quota-card,
    body[data-device="tablet"] .traffic-card,
    body[data-device="tablet"] .access-card,
    body[data-device="tablet"] .import-card {{
      grid-column: 1 / -1;
    }}
    body[data-device="tablet"] .spotlight {{
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }}
    body[data-device="mobile"] main {{
      padding: 16px 12px 24px;
    }}
    body[data-device="mobile"] .hero {{
      padding: 18px 16px 16px;
      border-radius: 20px;
    }}
    body[data-device="mobile"] .hero-topbar {{
      display: flex;
      gap: 10px;
      align-items: center;
      justify-content: space-between;
    }}
    body[data-device="mobile"] .theme-menu {{
      width: auto;
      max-width: 100%;
      display: inline-flex;
      justify-content: flex-end;
    }}
    body[data-device="mobile"] .theme-menu-btn {{
      width: auto;
      max-width: 100%;
      justify-content: center;
      padding: 9px 13px;
      font-size: 10px;
      letter-spacing: 0.05em;
      gap: 10px;
    }}
    body[data-device="mobile"] .theme-popover {{
      position: absolute;
      top: calc(100% + 8px);
      left: auto;
      right: 0;
      width: min(210px, calc(100vw - 40px));
      margin-top: 0;
      padding: 8px;
      z-index: 9;
    }}
    body[data-device="mobile"] .theme-option {{
      padding: 10px 12px;
      gap: 0;
    }}
    body[data-device="mobile"] .theme-option-note {{
      display: none;
    }}
    body[data-device="mobile"] .hero-grid,
    body[data-device="mobile"] .grid,
    body[data-device="mobile"] .spotlight {{
      grid-template-columns: 1fr;
    }}
    body[data-device="mobile"] .summary-card,
    body[data-device="mobile"] .quota-card,
    body[data-device="mobile"] .traffic-card,
    body[data-device="mobile"] .access-card,
    body[data-device="mobile"] .import-card {{
      grid-column: 1 / -1;
    }}
    body[data-device="mobile"] .status-row {{
      gap: 10px;
    }}
    body[data-device="mobile"] .card {{
      border-radius: 16px;
      padding: 14px;
    }}
    body[data-device="mobile"] .import-tabs {{
      gap: 8px;
    }}
    body[data-device="mobile"] .import-tab {{
      display: flex;
      flex: 1 1 calc(50% - 4px);
      width: auto;
      min-width: 0;
      text-align: center;
      justify-content: center;
    }}
    body[data-device="mobile"] .import-pane {{
      padding: 16px;
      border-radius: 18px;
    }}
    body[data-device="mobile"] .import-pane-head {{
      display: grid;
      grid-template-columns: 1fr;
    }}
    body[data-device="mobile"] .copy-btn-strong {{
      width: 100%;
      text-align: center;
      justify-content: center;
    }}
    body[data-device="mobile"] .traffic-chart {{
      height: 190px;
    }}
    body[data-device="mobile"] .traffic-head {{
      align-items: flex-start;
    }}
    body[data-device="mobile"] .traffic-toolbar {{
      align-items: stretch;
    }}
    body[data-device="mobile"] .traffic-range {{
      width: 100%;
      justify-content: space-between;
    }}
    body[data-device="mobile"] .traffic-range-btn {{
      flex: 1 1 0;
      text-align: center;
      justify-content: center;
    }}
    body[data-device="mobile"] .traffic-split,
    body[data-device="mobile"] .traffic-stat-row {{
      grid-template-columns: 1fr;
    }}
    body[data-device="mobile"] .traffic-rate {{
      font-size: 24px;
    }}
    body[data-device="mobile"] .traffic-live-pill {{
      width: 100%;
      justify-content: center;
    }}
    body[data-device="mobile"] .traffic-tooltip {{
      max-width: calc(100% - 24px);
    }}
  </style>
</head>
<body data-device="{_escape(device)}">
  <main>
    <section class="hero">
      <div class="hero-grid">
        <div>
          <div class="hero-topbar">
            <p class="eyebrow">Info Akun</p>
            <div class="theme-menu" id="theme-menu">
              <button class="theme-menu-btn" id="theme-menu-btn" type="button" aria-haspopup="menu" aria-expanded="false" aria-controls="theme-popover">Tema</button>
              <div class="theme-popover" id="theme-popover" role="menu" aria-label="Pengaturan tema" hidden>
                <button class="theme-option" type="button" role="menuitemradio" data-theme-choice="system" aria-checked="false">
                  <span class="theme-option-label">System</span>
                  <span class="theme-option-note">Ikuti tema perangkat</span>
                </button>
                <button class="theme-option" type="button" role="menuitemradio" data-theme-choice="dark" aria-checked="false">
                  <span class="theme-option-label">Gelap</span>
                  <span class="theme-option-note">Tampilan gelap hangat</span>
                </button>
                <button class="theme-option" type="button" role="menuitemradio" data-theme-choice="light" aria-checked="false">
                  <span class="theme-option-label">Terang</span>
                  <span class="theme-option-note">Tampilan terang lembut</span>
                </button>
              </div>
            </div>
          </div>
          <h1>{_escape(summary.get("username"))}</h1>
          <p class="sub">Status akun, masa aktif, quota, dan IP aktif.</p>
          <div class="status-row">
            <span id="protocol-chip" class="protocol-chip">{_escape(protocol_badge)}</span>
            <span id="status-badge" class="status-badge {status_class}">{_escape(status_value)}</span>
            <p id="status-text" class="note">{_escape(summary.get("status_text"))}</p>
          </div>
          <div id="next-action" class="action-banner {action_tone}">{_escape(action_text)}</div>
          <div id="sync-state" class="sync-state" hidden>Menampilkan data terakhir. Koneksi portal sedang tertunda.</div>
{"          <div id=\"problem-state\" class=\"problem-state " + ("bad" if status_value == "blocked" else "") + "\"><strong>" + _escape("Akun diblokir" if status_value == "blocked" else "Masa aktif habis") + "</strong>" + _escape("Akses akun dibatasi sampai status dipulihkan." if status_value == "blocked" else "Akun tidak bisa dipakai sampai diperpanjang.") + "</div>" if show_problem_state else ""}
        </div>
        <div class="spotlight">
          <div class="spotlight-card">
            <span>Masa Aktif</span>
            <strong id="days-remaining">{_escape(days_label)}</strong>
          </div>
          <div class="spotlight-card">
            <span>IP Aktif</span>
            <strong id="active-ip-hero" class="{"is-empty" if active_ip == "-" else ""}">{_escape(active_ip)}</strong>
          </div>
        </div>
      </div>
    </section>

    <section class="grid">
      <article class="card summary-card">
        <h2>Ringkasan</h2>
        <dl>
          <div class="metric"><dt>Protokol</dt><dd id="protocol">{_escape(protocol_label)}</dd></div>
          <div class="metric"><dt>Berlaku Sampai</dt><dd id="valid-until">{_escape(summary.get("valid_until"))}</dd></div>
          <div class="metric"><dt>Masa Aktif</dt><dd id="days-remaining-detail">{_escape(days_label)}</dd></div>
          <div class="metric"><dt>Limit IP</dt><dd id="ip-limit">{_escape(ip_limit_text)}</dd></div>
          <div class="metric"><dt>Limit Speed</dt><dd id="speed-limit">{_escape(speed_limit_text)}</dd></div>
          <div class="metric">
            <dt>IP Aktif</dt>
            <dd id="active-ip-detail" class="{"is-empty" if active_ip == "-" else ""}">{_escape(active_ip)}</dd>
            <p id="active-ip-hint" class="value-sub">{_escape(active_ip_hint)}</p>
          </div>
        </dl>
      </article>

      <article class="card quota-card">
        <h2>Quota</h2>
        <div class="card-grid">
          <div class="quota-meter">
            <div class="quota-summary-row">
              <div id="quota-pill" class="quota-pill">{quota_percent}% terpakai</div>
              <div id="quota-state" class="quota-state {quota_state_class}">{_escape(quota_state_label)}</div>
            </div>
            <div class="quota-bar"><span id="quota-bar-fill"></span></div>
            <div class="quota-row">
              <span id="quota-used-inline">Used: {_escape(summary.get("quota_used"))}</span>
              <span id="quota-remaining-inline">Remaining: {_escape(summary.get("quota_remaining"))}</span>
            </div>
            <p id="usage-tone" class="value-sub">{_escape(usage_tone)}</p>
          </div>
          <dl>
            <div class="metric"><dt>Limit</dt><dd id="quota-limit">{_escape(summary.get("quota_limit"))}</dd></div>
            <div class="metric"><dt>Terpakai</dt><dd id="quota-used">{_escape(summary.get("quota_used"))}</dd></div>
            <div class="metric"><dt>Sisa</dt><dd id="quota-remaining">{_escape(summary.get("quota_remaining"))}</dd></div>
          </dl>
        </div>
      </article>
      <article class="card traffic-card">
        <div class="section-head">
          <h2>Traffic Realtime</h2>
          <p id="traffic-state-text">Memantau traffic akun saat digunakan.</p>
        </div>
        <div class="traffic-toolbar">
          <div id="traffic-range" class="traffic-range" role="group" aria-label="Rentang traffic realtime">
            <button class="traffic-range-btn" type="button" data-window="60">1m</button>
            <button class="traffic-range-btn is-active" type="button" data-window="300">5m</button>
            <button class="traffic-range-btn" type="button" data-window="900">15m</button>
          </div>
          <div id="traffic-live-pill" class="traffic-live-pill idle">Tidak ada traffic saat ini</div>
        </div>
        <div class="traffic-head">
          <div>
            <p class="traffic-kicker">Rate Saat Ini</p>
            <p id="traffic-current-rate" class="traffic-rate">0 B/s</p>
          </div>
          <div class="traffic-split">
            <div class="traffic-mini">
              <span>Download</span>
              <strong id="traffic-down-rate">0 B/s</strong>
            </div>
            <div class="traffic-mini">
              <span>Upload</span>
              <strong id="traffic-up-rate">0 B/s</strong>
            </div>
          </div>
        </div>
        <div class="traffic-stat-row">
          <div class="traffic-mini">
            <span>Peak</span>
            <strong id="traffic-peak-rate">0 B/s</strong>
          </div>
          <div class="traffic-mini">
            <span>Avg</span>
            <strong id="traffic-avg-rate">0 B/s</strong>
          </div>
          <div id="traffic-burst-pill" class="traffic-burst-pill" hidden>Lonjakan traffic</div>
        </div>
        <div class="traffic-chart-wrap">
          <canvas id="traffic-chart" class="traffic-chart" width="640" height="220"></canvas>
          <div id="traffic-tooltip" class="traffic-tooltip" hidden></div>
        </div>
        <div class="traffic-meta">
          <span id="traffic-window-label">5 menit terakhir</span>
          <span id="traffic-source-label">Data live Xray API</span>
          <span id="traffic-sample-label">Sample 5 detik</span>
        </div>
      </article>
      <article class="card access-card">
        <div class="section-head">
          <h2>Info Akses</h2>
          <p>Ringkasan jalur akses akun.</p>
        </div>
        <dl>
          <div class="metric"><dt>Domain</dt><dd id="access-domain">{_escape(access_domain)}</dd></div>
        </dl>
{access_details_html}
      </article>
{import_links_html}
    </section>
  </main>
  <script>
    (() => {{
      const token = {token!r};
      if (!token) return;
      const root = document.documentElement;
      const themeKey = "autoscript-account-portal-theme";
      const themeMedia = window.matchMedia("(prefers-color-scheme: dark)");
      const themeMenu = document.getElementById("theme-menu");
      const themeMenuBtn = document.getElementById("theme-menu-btn");
      const themePopover = document.getElementById("theme-popover");
      const detectDevice = () => {{
        const ua = navigator.userAgent.toLowerCase();
        const width = window.innerWidth || document.documentElement.clientWidth || 0;
        if (width <= 720) return "mobile";
        if (width <= 1100) return "tablet";
        if (ua.includes("ipad") || ua.includes("tablet") || ua.includes("sm-t")) return "tablet";
        if (ua.includes("iphone") || ua.includes("ipod") || ua.includes("mobile")) return "mobile";
        if (ua.includes("android") && !ua.includes("mobile")) return "tablet";
        return "desktop";
      }};
      const applyDevice = () => {{
        document.body.dataset.device = detectDevice();
      }};
      const normalizeThemePreference = (value) => {{
        const current = String(value || "").trim().toLowerCase();
        return ["system", "dark", "light"].includes(current) ? current : "system";
      }};
      const effectiveTheme = (preference) => preference === "system" ? (themeMedia.matches ? "dark" : "light") : preference;
      const escapeHtml = (value) => String(value ?? "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
      const escapeAttr = (value) => escapeHtml(value).replace(/"/g, "&quot;");
      const updateThemeButtons = (preference) => {{
        document.querySelectorAll(".theme-option").forEach((button) => {{
          const active = button.getAttribute("data-theme-choice") === preference;
          button.classList.toggle("is-active", active);
          button.setAttribute("aria-checked", active ? "true" : "false");
        }});
      }};
      const themeOptions = () => Array.from(document.querySelectorAll(".theme-option"));
      const focusActiveThemeOption = () => {{
        const options = themeOptions();
        if (!options.length) return;
        const active = options.find((button) => button.classList.contains("is-active"));
        (active || options[0]).focus();
      }};
      const moveThemeFocus = (step) => {{
        const options = themeOptions();
        if (!options.length) return;
        const currentIndex = Math.max(0, options.findIndex((button) => button === document.activeElement));
        const nextIndex = (currentIndex + step + options.length) % options.length;
        options[nextIndex].focus();
      }};
      const setThemeMenuOpen = (open, options = {{}}) => {{
        if (!themeMenu || !themeMenuBtn || !themePopover) return;
        const next = Boolean(open);
        const {{ focusMenu = false, restoreFocus = false }} = options;
        themeMenu.classList.toggle("is-open", next);
        themePopover.hidden = !next;
        themeMenuBtn.setAttribute("aria-expanded", next ? "true" : "false");
        if (next && focusMenu) {{
          window.requestAnimationFrame(() => focusActiveThemeOption());
        }}
        if (!next && restoreFocus) {{
          themeMenuBtn.focus();
        }}
      }};
      const applyThemePreference = (preference, persist = true) => {{
        const nextPreference = normalizeThemePreference(preference);
        const nextTheme = effectiveTheme(nextPreference);
        root.dataset.themePreference = nextPreference;
        root.dataset.theme = nextTheme;
        updateThemeButtons(nextPreference);
        if (persist) {{
          try {{
            localStorage.setItem(themeKey, nextPreference);
          }} catch (_err) {{
            // ignore storage errors
          }}
        }}
        if (latestTrafficPayload) drawTrafficChart(latestTrafficPayload);
      }};

      const setText = (id, value) => {{
        const node = document.getElementById(id);
        if (node) node.textContent = value ?? "-";
      }};
      const setClassOnly = (id, classes, active) => {{
        const node = document.getElementById(id);
        if (!node) return;
        for (const name of classes) node.classList.remove(name);
        if (active) node.classList.add(active);
      }};
      const setEmptyTone = (id, value) => {{
        const node = document.getElementById(id);
        if (!node) return;
        if ((value ?? "-") === "-") node.classList.add("is-empty");
        else node.classList.remove("is-empty");
      }};
      const quotaPercent = (limitBytes, usedBytes) => {{
        const limit = Number(limitBytes || 0);
        const used = Number(usedBytes || 0);
        if (!Number.isFinite(limit) || limit <= 0 || !Number.isFinite(used) || used <= 0) return 0;
        return Math.max(0, Math.min(100, Math.floor((used / limit) * 100)));
      }};
      const usageTone = (percent) => {{
        if (percent < 60) return "Quota masih aman.";
        if (percent < 90) return "Quota mulai tinggi.";
        return "Quota hampir habis.";
      }};
      const quotaState = (percent) => {{
        if (percent < 60) return ["Aman", "ok"];
        if (percent < 90) return ["Perlu Dipantau", "warn"];
        return ["Hampir Habis", "bad"];
      }};
      const nextAction = (summary, percent) => {{
        const status = String(summary.status || "").trim().toLowerCase();
        const days = Number(summary.days_remaining);
        const activeIp = String(summary.active_ip || "-").trim() || "-";
        if (status === "blocked") return ["warning", "Akun diblokir. Hubungi admin."];
        if (status === "expired") return ["warning", "Masa aktif habis. Hubungi admin."];
        if (percent >= 90) return ["warning", "Quota hampir habis."];
        if (Number.isInteger(days) && days <= 3) return ["warning", "Masa aktif hampir habis."];
        if (activeIp === "-") return ["info", "Akun siap dipakai."];
        return ["ok", "Akun aktif."];
      }};
      const activeIpHint = (ip, lastSeen) => {{
        if (ip !== "-" && lastSeen !== "-") return `Terakhir aktif: ${{lastSeen}}`;
        if (ip !== "-") return "Sedang aktif.";
        if (lastSeen !== "-") return `Terakhir aktif: ${{lastSeen}}`;
        return "Belum ada login aktif.";
      }};
      const daysLabel = (value) => Number.isInteger(value) && value >= 0 ? `${{value}} hari` : "-";
      const statusClass = (value) => {{
        const normalized = String(value || "").trim().toLowerCase();
        if (normalized === "active") return "ok";
        if (normalized === "expired") return "warn";
        return "bad";
      }};
      const importCard = document.getElementById("import-card");
      const trafficCanvas = document.getElementById("traffic-chart");
      const trafficCtx = trafficCanvas?.getContext("2d") || null;
      const trafficTooltip = document.getElementById("traffic-tooltip");
      const trafficRange = document.getElementById("traffic-range");
      const syncState = document.getElementById("sync-state");
      let activeImportKey = importCard?.dataset.activeImportKey || "";
      let latestTrafficPayload = null;
      let latestTrafficRender = null;
      let trafficHoverIndex = -1;
      let selectedTrafficWindow = 300;
      let trafficTooltipFrame = 0;
      let pendingTrafficPointer = null;
      let summaryRefreshFailed = false;
      let trafficRefreshFailed = false;
      let summaryRefreshTimer = 0;
      let trafficRefreshTimer = 0;
      let summaryRefreshDelay = 15000;
      let trafficRefreshDelay = {TRAFFIC_SAMPLE_INTERVAL_SECONDS * 1000};
      const importKey = (label) => String(label || "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "mode";
      const preferredImportKey = (items) => {{
        const keys = items.map((item) => importKey(item.label));
        for (const preferred of ["websocket", "tcp-tls", "httpupgrade", "xhttp", "grpc"]) {{
          if (keys.includes(preferred)) return preferred;
        }}
        return keys[0] || "mode";
      }};
      const updateSyncState = () => {{
        if (!syncState) return;
        if (!summaryRefreshFailed && !trafficRefreshFailed) {{
          syncState.hidden = true;
          syncState.textContent = "";
          return;
        }}
        syncState.hidden = false;
        if (summaryRefreshFailed && trafficRefreshFailed) {{
          syncState.textContent = "Menampilkan data terakhir. Koneksi portal sedang tertunda.";
          return;
        }}
        syncState.textContent = summaryRefreshFailed
          ? "Info akun belum diperbarui. Menampilkan data terakhir."
          : "Traffic realtime belum diperbarui. Menampilkan data terakhir.";
      }};
      const scheduleSummaryRefresh = (delay = summaryRefreshDelay) => {{
        if (summaryRefreshTimer) window.clearTimeout(summaryRefreshTimer);
        summaryRefreshTimer = window.setTimeout(() => {{
          summaryRefreshTimer = 0;
          refresh();
        }}, Math.max(1000, Number(delay || 15000)));
      }};
      const scheduleTrafficRefresh = (delay = trafficRefreshDelay) => {{
        if (trafficRefreshTimer) window.clearTimeout(trafficRefreshTimer);
        trafficRefreshTimer = window.setTimeout(() => {{
          trafficRefreshTimer = 0;
          refreshTraffic();
        }}, Math.max(1000, Number(delay || {TRAFFIC_SAMPLE_INTERVAL_SECONDS * 1000})));
      }};
      const bindCopyButtons = (root = document) => {{
        root.querySelectorAll(".copy-btn").forEach((button) => {{
          if (button.dataset.bound === "1") return;
          button.dataset.bound = "1";
          button.addEventListener("click", async () => {{
            const value = button.getAttribute("data-copy") || "";
            if (!value) return;
            try {{
              await navigator.clipboard.writeText(value);
              const previous = button.textContent || "Copy";
              button.textContent = "Copied";
              button.classList.add("is-done");
              window.setTimeout(() => {{
                button.textContent = previous === "Copied" ? "Copy" : previous;
                button.classList.remove("is-done");
              }}, 1400);
            }} catch (_err) {{
              button.textContent = "Gagal";
              window.setTimeout(() => {{
                button.textContent = "Copy";
              }}, 1400);
            }}
          }});
        }});
      }};
      const selectImportTab = (key) => {{
        activeImportKey = key;
        if (importCard) importCard.dataset.activeImportKey = key;
        document.querySelectorAll(".import-tab").forEach((button) => {{
          const active = button.getAttribute("data-import-key") === key;
          button.classList.toggle("is-active", active);
          button.setAttribute("aria-selected", active ? "true" : "false");
        }});
        document.querySelectorAll(".import-pane").forEach((pane) => {{
          pane.hidden = pane.getAttribute("data-import-pane") !== key;
          pane.classList.toggle("is-active", pane.getAttribute("data-import-pane") === key);
        }});
      }};
      const renderImportPane = (item) => {{
        const active = item.key === activeImportKey;
        const hiddenAttr = active ? "" : " hidden";
        return `<section class="import-pane${{active ? " is-active" : ""}}" data-import-pane="${{escapeAttr(item.key)}}"${{hiddenAttr}}><div class="import-pane-head"><div><p class="import-kicker">Mode Aktif</p><h3>${{escapeHtml(item.label)}}</h3></div><button class="copy-btn copy-btn-strong" type="button" data-copy="${{escapeAttr(item.url)}}">Copy Link</button></div><p class="import-helper">Gunakan link ini untuk mode <strong>${{escapeHtml(item.label)}}</strong>.</p><code>${{escapeHtml(item.url)}}</code></section>`;
      }};
      const renderImportTabs = (items) => {{
        if (!importCard) return;
        const tabs = document.getElementById("import-tabs");
        const stage = document.getElementById("import-stage");
        if (!tabs || !stage) return;
        if (!Array.isArray(items) || !items.length) {{
          importCard.hidden = true;
          return;
        }}
        importCard.hidden = false;
        const mapped = items
          .map((item) => ({{
            label: String(item?.label || "").trim(),
            url: String(item?.url || "").trim(),
            key: importKey(item?.label || ""),
          }}))
          .filter((item) => item.label && item.url);
        if (!mapped.length) {{
          importCard.hidden = true;
          return;
        }}
        if (!mapped.some((item) => item.key === activeImportKey)) {{
          activeImportKey = preferredImportKey(mapped);
        }}
        tabs.innerHTML = mapped
          .map((item) => `<button class="import-tab${{item.key === activeImportKey ? " is-active" : ""}}" type="button" data-import-key="${{escapeAttr(item.key)}}" role="tab" aria-selected="${{item.key === activeImportKey ? "true" : "false"}}">${{escapeHtml(item.label)}}</button>`)
          .join("");
        stage.innerHTML = mapped
          .map((item) => renderImportPane(item))
          .join("");
        tabs.querySelectorAll(".import-tab").forEach((button) => {{
          button.addEventListener("click", () => selectImportTab(button.getAttribute("data-import-key") || ""));
        }});
        bindCopyButtons(stage);
        selectImportTab(activeImportKey);
      }};
      const formatRate = (value) => {{
        let amount = Math.max(0, Number(value || 0));
        const units = ["B/s", "KiB/s", "MiB/s", "GiB/s"];
        let unitIndex = 0;
        while (amount >= 1024 && unitIndex < units.length - 1) {{
          amount /= 1024;
          unitIndex += 1;
        }}
        if (unitIndex === 0) return `${{Math.round(amount)}} ${{units[unitIndex]}}`;
        if (amount >= 100) return `${{amount.toFixed(0)}} ${{units[unitIndex]}}`;
        if (amount >= 10) return `${{amount.toFixed(1)}} ${{units[unitIndex]}}`;
        return `${{amount.toFixed(2)}} ${{units[unitIndex]}}`;
      }};
      const formatWindowLabel = (seconds) => {{
        const total = Math.max(0, Number(seconds || 0));
        const minutes = Math.round(total / 60);
        if (minutes <= 1) return "1 menit terakhir";
        return `${{minutes}} menit terakhir`;
      }};
      const compactWindowLabel = (seconds) => {{
        const total = Math.max(0, Number(seconds || 0));
        if (total < 60) return `${{total}}s`;
        const minutes = Math.round(total / 60);
        return `${{Math.max(1, minutes)}}m`;
      }};
      const formatClock = (timestampSeconds) => {{
        const date = new Date(Math.max(0, Number(timestampSeconds || 0)) * 1000);
        if (Number.isNaN(date.getTime())) return "-";
        return date.toLocaleTimeString("id-ID", {{
          hour: "2-digit",
          minute: "2-digit",
          second: "2-digit",
        }});
      }};
      const updateTrafficRangeButtons = () => {{
        trafficRange?.querySelectorAll(".traffic-range-btn").forEach((button) => {{
          const active = Number(button.getAttribute("data-window") || 0) === selectedTrafficWindow;
          button.classList.toggle("is-active", active);
          button.setAttribute("aria-pressed", active ? "true" : "false");
        }});
      }};
      const renderTrafficRangeButtons = (payload) => {{
        if (!trafficRange) return [];
        const raw = Array.isArray(payload?.available_windows) ? payload.available_windows : [];
        const windows = raw
          .map((item) => Math.max(1, Number(item || 0)))
          .filter((item, index, arr) => Number.isFinite(item) && item > 0 && arr.indexOf(item) === index)
          .sort((a, b) => a - b);
        const resolved = windows.length ? windows : [60, 300, 900];
        const signature = resolved.join(",");
        if (trafficRange.dataset.signature !== signature) {{
          trafficRange.dataset.signature = signature;
          trafficRange.innerHTML = resolved
            .map((seconds) => `<button class="traffic-range-btn" type="button" data-window="${{seconds}}">${{compactWindowLabel(seconds)}}</button>`)
            .join("");
          trafficRange.querySelectorAll(".traffic-range-btn").forEach((button) => {{
            button.addEventListener("click", () => {{
              setTrafficWindow(Number(button.getAttribute("data-window") || resolved[0] || 300));
            }});
          }});
        }}
        return resolved;
      }};
      const setTrafficWindow = (seconds) => {{
        const next = Math.max(60, Number(seconds || 300));
        selectedTrafficWindow = next;
        updateTrafficRangeButtons();
        if (latestTrafficPayload) applyTraffic(latestTrafficPayload);
      }};
      const prepareTrafficSeries = (payload) => {{
        const sourcePoints = Array.isArray(payload?.points) ? payload.points : [];
        const all = sourcePoints
          .map((item) => ({{
            ts: Number(item?.ts || 0),
            total: Math.max(0, Number(item?.total_rate_bps ?? item?.rate_bps || 0)),
            down: Math.max(0, Number(item?.down_rate_bps || 0)),
            up: Math.max(0, Number(item?.up_rate_bps || 0)),
          }}))
          .filter((item) => Number.isFinite(item.ts) && item.ts > 0 && Number.isFinite(item.total) && Number.isFinite(item.down) && Number.isFinite(item.up));

        if (!all.length) {{
          all.push({{ ts: Date.now() / 1000, total: 0, down: 0, up: 0 }});
        }}
        const selected = Math.max(60, Number(selectedTrafficWindow || payload?.default_window_seconds || 300));
        const latestTs = all[all.length - 1].ts;
        const cutoff = latestTs - selected;
        let prepared = all.filter((item) => item.ts >= cutoff);
        if (!prepared.length) {{
          prepared = [all[all.length - 1]];
        }}
        if (prepared.length === 1) {{
          prepared.unshift({{
            ts: prepared[0].ts - Math.max(1, Number(payload?.sample_interval_seconds || 5)),
            total: 0,
            down: 0,
            up: 0,
          }});
        }}
        return prepared;
      }};
      const trafficStats = (points) => {{
        const last = points[points.length - 1] || {{ total: 0, down: 0, up: 0 }};
        const totals = points.map((item) => Math.max(0, Number(item.total || 0)));
        const peak = Math.max(0, ...totals);
        const avg = totals.length ? (totals.reduce((sum, value) => sum + value, 0) / totals.length) : 0;
        const peakIndex = totals.findIndex((value) => value === peak);
        const burst = peak > 0 && last.total >= Math.max(peak * 0.85, avg * 1.6, 128 * 1024);
        return {{
          currentTotal: Math.max(0, Number(last.total || 0)),
          currentDown: Math.max(0, Number(last.down || 0)),
          currentUp: Math.max(0, Number(last.up || 0)),
          peak,
          avg,
          peakIndex,
          burst,
        }};
      }};
      const resizeTrafficCanvas = () => {{
        if (!trafficCanvas || !trafficCtx) return;
        const ratio = Math.max(1, window.devicePixelRatio || 1);
        const cssWidth = Math.max(280, Math.floor(trafficCanvas.clientWidth || 640));
        const cssHeight = Math.max(180, Math.floor(trafficCanvas.clientHeight || 220));
        const nextWidth = Math.floor(cssWidth * ratio);
        const nextHeight = Math.floor(cssHeight * ratio);
        if (trafficCanvas.width !== nextWidth || trafficCanvas.height !== nextHeight) {{
          trafficCanvas.width = nextWidth;
          trafficCanvas.height = nextHeight;
        }}
        trafficCtx.setTransform(1, 0, 0, 1, 0, 0);
        trafficCtx.scale(ratio, ratio);
        return {{ width: cssWidth, height: cssHeight }};
      }};
      const cssVar = (name, fallback = "") => {{
        const value = getComputedStyle(root).getPropertyValue(name).trim();
        return value || fallback;
      }};
      const hideTrafficTooltip = () => {{
        if (trafficTooltipFrame) {{
          window.cancelAnimationFrame(trafficTooltipFrame);
          trafficTooltipFrame = 0;
        }}
        pendingTrafficPointer = null;
        trafficHoverIndex = -1;
        if (trafficTooltip) trafficTooltip.hidden = true;
      }};
      const drawTrafficChart = (payload) => {{
        if (!trafficCanvas || !trafficCtx) return;
        const size = resizeTrafficCanvas();
        if (!size) return;
        const {{ width, height }} = size;
        trafficCtx.clearRect(0, 0, width, height);

        const left = 10;
        const right = width - 10;
        const top = 16;
        const bottom = height - 20;
        const chartHeight = Math.max(20, bottom - top);
        const chartWidth = Math.max(40, right - left);
        const prepared = prepareTrafficSeries(payload);
        const stats = trafficStats(prepared);
        const minTs = prepared[0].ts;
        const maxTs = prepared[prepared.length - 1].ts;
        const spanTs = Math.max(1, maxTs - minTs);
        const maxRate = Math.max(1, ...prepared.map((item) => item.total));

        trafficCtx.strokeStyle = cssVar("--chart-grid", "rgba(255,255,255,0.06)");
        trafficCtx.lineWidth = 1;
        for (let i = 0; i < 4; i += 1) {{
          const y = top + ((chartHeight / 3) * i);
          trafficCtx.beginPath();
          trafficCtx.moveTo(left, y);
          trafficCtx.lineTo(right, y);
          trafficCtx.stroke();
        }}
        trafficCtx.fillStyle = cssVar("--chart-text", "rgba(255,241,227,0.78)");
        trafficCtx.font = "12px ui-sans-serif, system-ui, sans-serif";
        trafficCtx.textAlign = "right";
        trafficCtx.fillText(formatRate(maxRate), right, top + 2);
        trafficCtx.fillText("0 B/s", right, bottom - 4);

        const points = prepared.map((item) => {{
          const x = left + ((item.ts - minTs) / spanTs) * chartWidth;
          return {{
            ts: item.ts,
            x,
            total: item.total,
            down: item.down,
            up: item.up,
            yTotal: bottom - (item.total / maxRate) * chartHeight,
            yDown: bottom - (item.down / maxRate) * chartHeight,
            yUp: bottom - (item.up / maxRate) * chartHeight,
          }};
        }});

        const drawArea = (seriesKey, fillTopVar, fillBottomVar) => {{
          const areaGradient = trafficCtx.createLinearGradient(0, top, 0, bottom);
          areaGradient.addColorStop(0, cssVar(fillTopVar, "rgba(214,107,34,0.26)"));
          areaGradient.addColorStop(1, cssVar(fillBottomVar, "rgba(214,107,34,0)"));
          trafficCtx.beginPath();
          trafficCtx.moveTo(points[0].x, bottom);
          for (const point of points) trafficCtx.lineTo(point.x, point[seriesKey]);
          trafficCtx.lineTo(points[points.length - 1].x, bottom);
          trafficCtx.closePath();
          trafficCtx.fillStyle = areaGradient;
          trafficCtx.fill();
        }};
        const drawLine = (seriesKey, colorVar, widthLine) => {{
          trafficCtx.beginPath();
          trafficCtx.lineWidth = widthLine;
          trafficCtx.lineJoin = "round";
          trafficCtx.lineCap = "round";
          points.forEach((point, index) => {{
            if (index === 0) trafficCtx.moveTo(point.x, point[seriesKey]);
            else trafficCtx.lineTo(point.x, point[seriesKey]);
          }});
          trafficCtx.strokeStyle = cssVar(colorVar, "#f2b24f");
          trafficCtx.stroke();
        }};
        drawArea("yDown", "--chart-down-fill-top", "--chart-down-fill-bottom");
        drawArea("yUp", "--chart-up-fill-top", "--chart-up-fill-bottom");
        drawLine("yDown", "--chart-down-line", 3);
        drawLine("yUp", "--chart-up-line", 2.2);

        if (Number.isInteger(stats.peakIndex) && stats.peakIndex >= 0 && points[stats.peakIndex]) {{
          const peakPoint = points[stats.peakIndex];
          trafficCtx.beginPath();
          trafficCtx.arc(peakPoint.x, peakPoint.yTotal, 5, 0, Math.PI * 2);
          trafficCtx.fillStyle = cssVar("--chart-point", "#fff1e3");
          trafficCtx.fill();
          trafficCtx.beginPath();
          trafficCtx.arc(peakPoint.x, peakPoint.yTotal, 10, 0, Math.PI * 2);
          trafficCtx.strokeStyle = cssVar("--chart-ring", "rgba(255,241,227,0.24)");
          trafficCtx.lineWidth = 2;
          trafficCtx.stroke();
        }}

        const hoverIndex = trafficHoverIndex >= 0 ? Math.min(trafficHoverIndex, points.length - 1) : -1;
        if (hoverIndex >= 0 && points[hoverIndex]) {{
          const hoverPoint = points[hoverIndex];
          trafficCtx.beginPath();
          trafficCtx.arc(hoverPoint.x, hoverPoint.yDown, 4, 0, Math.PI * 2);
          trafficCtx.fillStyle = cssVar("--chart-down-line", "#f2b24f");
          trafficCtx.fill();
          trafficCtx.beginPath();
          trafficCtx.arc(hoverPoint.x, hoverPoint.yUp, 4, 0, Math.PI * 2);
          trafficCtx.fillStyle = cssVar("--chart-up-line", "#d66b22");
          trafficCtx.fill();
        }}

        latestTrafficRender = {{
          payload,
          points,
          stats,
          width,
          height,
          bounds: {{ left, right, top, bottom }},
        }};
        return latestTrafficRender;
      }};
      const nearestTrafficIndex = (clientX) => {{
        if (!trafficCanvas || !latestTrafficRender?.points?.length) return -1;
        const rect = trafficCanvas.getBoundingClientRect();
        const localX = clientX - rect.left;
        let bestIndex = -1;
        let bestDistance = Number.POSITIVE_INFINITY;
        latestTrafficRender.points.forEach((point, index) => {{
          const distance = Math.abs(point.x - localX);
          if (distance < bestDistance) {{
            bestDistance = distance;
            bestIndex = index;
          }}
        }});
        return bestIndex;
      }};
      const renderTrafficTooltip = (clientX, clientY) => {{
        if (!trafficTooltip || !latestTrafficRender?.points?.length) return;
        const index = nearestTrafficIndex(clientX);
        if (index < 0) {{
          hideTrafficTooltip();
          return;
        }}
        const hoverChanged = trafficHoverIndex !== index;
        trafficHoverIndex = index;
        const point = latestTrafficRender.points[index];
        trafficTooltip.hidden = false;
        trafficTooltip.innerHTML = `<strong>${{formatClock(point.ts)}}</strong>Down: ${{formatRate(point.down)}}<br>Up: ${{formatRate(point.up)}}<br>Total: ${{formatRate(point.total)}}`;
        const rect = trafficCanvas.getBoundingClientRect();
        const left = Math.max(12, Math.min(rect.width - 12, clientX - rect.left));
        const top = Math.max(24, clientY - rect.top);
        trafficTooltip.style.left = `${{left}}px`;
        trafficTooltip.style.top = `${{top}}px`;
        if (hoverChanged && latestTrafficPayload) {{
          drawTrafficChart(latestTrafficPayload);
        }}
      }};
      const queueTrafficTooltip = (clientX, clientY) => {{
        pendingTrafficPointer = {{ clientX, clientY }};
        if (trafficTooltipFrame) return;
        trafficTooltipFrame = window.requestAnimationFrame(() => {{
          trafficTooltipFrame = 0;
          const nextPointer = pendingTrafficPointer;
          pendingTrafficPointer = null;
          if (!nextPointer) return;
          renderTrafficTooltip(nextPointer.clientX, nextPointer.clientY);
        }});
      }};
      const applyTraffic = (payload) => {{
        latestTrafficPayload = payload;
        const availableWindows = renderTrafficRangeButtons(payload);
        const defaultWindow = Math.max(60, Number(payload?.default_window_seconds || 300));
        if (!availableWindows.includes(selectedTrafficWindow)) {{
          selectedTrafficWindow = availableWindows.includes(defaultWindow) ? defaultWindow : (availableWindows[0] || defaultWindow);
        }}
        updateTrafficRangeButtons();
        setText("traffic-current-rate", payload?.current_rate_text || "0 B/s");
        setText("traffic-down-rate", payload?.current_down_rate_text || "0 B/s");
        setText("traffic-up-rate", payload?.current_up_rate_text || "0 B/s");
        setText("traffic-window-label", formatWindowLabel(selectedTrafficWindow));
        setText("traffic-source-label", payload?.source_text || "Delta quota");
        setText("traffic-sample-label", `Sample ${{Math.max(1, Number(payload?.sample_interval_seconds || 5))}} detik`);
        const livePill = document.getElementById("traffic-live-pill");
        const stateText = document.getElementById("traffic-state-text");
        const burstPill = document.getElementById("traffic-burst-pill");
        const active = Boolean(payload?.active);
        if (livePill) {{
          livePill.textContent = active ? "Sedang aktif" : "Tidak ada traffic saat ini";
          livePill.classList.remove("live", "idle");
          livePill.classList.add(active ? "live" : "idle");
        }}
        if (stateText) {{
          stateText.textContent = active
            ? "Traffic realtime terdeteksi untuk akun ini."
            : "Belum ada traffic realtime untuk akun ini.";
        }}
        const render = drawTrafficChart(payload);
        const stats = render?.stats || trafficStats(prepareTrafficSeries(payload));
        setText("traffic-peak-rate", formatRate(stats.peak));
        setText("traffic-avg-rate", formatRate(stats.avg));
        if (burstPill) {{
          burstPill.hidden = !stats.burst;
        }}
      }};
      const applySummary = (summary) => {{
        const percent = quotaPercent(summary.quota_limit_bytes, summary.quota_used_bytes);
        const activeIp = String(summary.active_ip || "-").trim() || "-";
        const lastSeen = String(summary.active_ip_last_seen_at || "-").trim() || "-";
        const [quotaStateLabel, quotaStateClass] = quotaState(percent);
        const badge = document.getElementById("status-badge");
        if (badge) {{
          badge.textContent = summary.status || "-";
          badge.classList.remove("ok", "warn", "bad");
          badge.classList.add(statusClass(summary.status));
        }}
        const protoMap = {{
          vless: "VLESS",
          vmess: "VMESS",
          trojan: "TROJAN",
          ssh: "SSH",
          openvpn: "OPENVPN",
        }};
        const protocolDisplay = protoMap[String(summary.protocol || "").trim().toLowerCase()] || String(summary.protocol || "-").toUpperCase();
        setText("protocol-chip", protocolDisplay);
        setText("status-text", summary.status_text || "-");
        setText("protocol", protocolDisplay);
        const [actionClass, actionText] = nextAction(summary, percent);
        setText("next-action", actionText);
        setClassOnly("next-action", ["ok", "info", "warning"], actionClass);
        const problemState = document.getElementById("problem-state");
        const normalizedStatus = String(summary.status || "").trim().toLowerCase();
        if (problemState) {{
          if (normalizedStatus === "blocked") {{
            problemState.hidden = false;
            problemState.classList.add("bad");
            problemState.innerHTML = "<strong>Akun diblokir</strong>Akses akun dibatasi sampai status dipulihkan.";
          }} else if (normalizedStatus === "expired") {{
            problemState.hidden = false;
            problemState.classList.remove("bad");
            problemState.innerHTML = "<strong>Masa aktif habis</strong>Akun tidak bisa dipakai sampai diperpanjang.";
          }} else {{
            problemState.hidden = true;
          }}
        }}
        setText("days-remaining", daysLabel(summary.days_remaining));
        setText("days-remaining-detail", daysLabel(summary.days_remaining));
        setText("valid-until", summary.valid_until || "-");
        setText("access-domain", summary.access_domain || "-");
        setText("ip-limit", summary.ip_limit_text || "OFF");
        setText("speed-limit", summary.speed_limit_text || "OFF");
        setText("active-ip-hero", activeIp);
        setText("active-ip-detail", activeIp);
        setEmptyTone("active-ip-hero", activeIp);
        setEmptyTone("active-ip-detail", activeIp);
        setText("active-ip-hint", activeIpHint(activeIp, lastSeen));
        setText("quota-pill", `${{percent}}% terpakai`);
        const quotaStateNode = document.getElementById("quota-state");
        if (quotaStateNode) {{
          quotaStateNode.textContent = quotaStateLabel;
          quotaStateNode.classList.remove("ok", "warn", "bad");
          quotaStateNode.classList.add(quotaStateClass);
        }}
        setText("quota-used-inline", `Used: ${{summary.quota_used || "-"}}`);
        setText("quota-remaining-inline", `Remaining: ${{summary.quota_remaining || "-"}}`);
        setText("usage-tone", usageTone(percent));
        setText("quota-limit", summary.quota_limit || "-");
        setText("quota-used", summary.quota_used || "-");
        setText("quota-remaining", summary.quota_remaining || "-");
        renderImportTabs(summary.import_links || []);
        const bar = document.getElementById("quota-bar-fill");
        if (bar) {{
          bar.style.width = `${{percent}}%`;
          bar.style.minWidth = percent > 0 ? "10px" : "0";
        }}
      }};
      const refreshTraffic = async () => {{
        let failed = true;
        try {{
          const response = await fetch(`/api/account/${{token}}/traffic`, {{
            method: "GET",
            cache: "no-store",
            headers: {{ "Accept": "application/json" }},
          }});
          if (!response.ok) {{
            trafficRefreshFailed = true;
            updateSyncState();
            return;
          }}
          const payload = await response.json();
          if (payload && payload.ok) {{
            trafficRefreshFailed = false;
            failed = false;
            applyTraffic(payload);
            updateSyncState();
            return;
          }}
          trafficRefreshFailed = true;
          updateSyncState();
        }} catch (_err) {{
          trafficRefreshFailed = true;
          updateSyncState();
        }} finally {{
          trafficRefreshDelay = failed
            ? Math.min(30000, Math.max({TRAFFIC_SAMPLE_INTERVAL_SECONDS * 1000}, Math.round(trafficRefreshDelay * 1.8)))
            : {TRAFFIC_SAMPLE_INTERVAL_SECONDS * 1000};
          scheduleTrafficRefresh(trafficRefreshDelay);
        }}
      }};

      const refresh = async () => {{
        let failed = true;
        try {{
          const response = await fetch(`/api/account/${{token}}/summary`, {{
            method: "GET",
            cache: "no-store",
            headers: {{ "Accept": "application/json" }},
          }});
          if (!response.ok) {{
            summaryRefreshFailed = true;
            updateSyncState();
            return;
          }}
          const summary = await response.json();
          if (summary && summary.ok) {{
            summaryRefreshFailed = false;
            failed = false;
            applySummary(summary);
            updateSyncState();
            return;
          }}
          summaryRefreshFailed = true;
          updateSyncState();
        }} catch (_err) {{
          summaryRefreshFailed = true;
          updateSyncState();
        }} finally {{
          summaryRefreshDelay = failed ? Math.min(60000, Math.max(15000, Math.round(summaryRefreshDelay * 1.8))) : 15000;
          scheduleSummaryRefresh(summaryRefreshDelay);
        }}
      }};

      bindCopyButtons(document);
      trafficCanvas?.addEventListener("pointermove", (event) => {{
        queueTrafficTooltip(event.clientX, event.clientY);
      }});
      trafficCanvas?.addEventListener("pointerleave", () => {{
        const hadHover = trafficHoverIndex >= 0;
        hideTrafficTooltip();
        if (hadHover && latestTrafficPayload) drawTrafficChart(latestTrafficPayload);
      }});
      trafficCanvas?.addEventListener("pointerdown", (event) => {{
        queueTrafficTooltip(event.clientX, event.clientY);
      }});
      themeMenuBtn?.addEventListener("click", (event) => {{
        event.stopPropagation();
        setThemeMenuOpen(themePopover?.hidden !== false, {{ focusMenu: themePopover?.hidden !== false }});
      }});
      document.querySelectorAll(".theme-option").forEach((button) => {{
        button.addEventListener("click", () => {{
          applyThemePreference(button.getAttribute("data-theme-choice") || "system");
          setThemeMenuOpen(false, {{ restoreFocus: true }});
        }});
      }});
      document.addEventListener("click", (event) => {{
        if (!themeMenu) return;
        if (themeMenu.contains(event.target)) return;
        setThemeMenuOpen(false);
      }});
      themePopover?.addEventListener("keydown", (event) => {{
        if (event.key === "ArrowDown") {{
          event.preventDefault();
          moveThemeFocus(1);
        }} else if (event.key === "ArrowUp") {{
          event.preventDefault();
          moveThemeFocus(-1);
        }} else if (event.key === "Home") {{
          event.preventDefault();
          themeOptions()[0]?.focus();
        }} else if (event.key === "End") {{
          event.preventDefault();
          const options = themeOptions();
          options[options.length - 1]?.focus();
        }} else if (event.key === "Tab") {{
          setThemeMenuOpen(false);
        }}
      }});
      document.addEventListener("keydown", (event) => {{
        if (event.key === "Escape") setThemeMenuOpen(false, {{ restoreFocus: !themePopover?.hidden }});
      }});
      renderImportTabs({summary.get("import_links")!r});
      applyDevice();
      applyThemePreference(root.dataset.themePreference || "system", false);
      updateSyncState();
      if (typeof themeMedia.addEventListener === "function") {{
        themeMedia.addEventListener("change", () => {{
          if ((root.dataset.themePreference || "system") === "system") {{
            applyThemePreference("system", false);
          }}
        }});
      }} else if (typeof themeMedia.addListener === "function") {{
        themeMedia.addListener(() => {{
          if ((root.dataset.themePreference || "system") === "system") {{
            applyThemePreference("system", false);
          }}
        }});
      }}
      window.addEventListener("resize", () => {{
        applyDevice();
        if (latestTrafficPayload) drawTrafficChart(latestTrafficPayload);
      }}, {{ passive: true }});
      refreshTraffic();
      scheduleSummaryRefresh(15000);
    }})();
  </script>
</body>
</html>"""


@app.get("/health")
def health() -> dict[str, object]:
    return {
        "status": "ok",
        "service": "account-portal",
        "app_root": str(APP_ROOT),
    }


@app.get("/api/account/{token}/summary")
def get_account_summary(token: str) -> JSONResponse:
    summary = build_public_account_summary(token)
    if summary is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Portal akun tidak ditemukan.")
    return JSONResponse(summary, headers=PORTAL_HEADERS)


@app.get("/api/account/{token}/traffic")
def get_account_traffic(token: str) -> JSONResponse:
    traffic_context = build_public_account_traffic_context(token)
    if traffic_context is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Portal akun tidak ditemukan.")
    return JSONResponse(_traffic_snapshot(token, traffic_context), headers=PORTAL_HEADERS)


@app.get("/account/{token}", response_class=HTMLResponse)
def account_portal_page(token: str, request: Request) -> HTMLResponse:
    summary = build_public_account_summary(token)
    if summary is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Portal akun tidak ditemukan.")
    device = _device_from_user_agent(request.headers.get("user-agent", ""))
    return HTMLResponse(_render_account_portal(summary, device=device), headers=PORTAL_HEADERS)

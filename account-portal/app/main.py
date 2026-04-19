from __future__ import annotations

import json
import re
import subprocess
import threading
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, status
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse

from .data import build_public_account_summary, build_public_account_traffic_context

APP_ROOT = Path(__file__).resolve().parents[2]
PORTAL_ROOT = Path(__file__).resolve().parents[1]
PORTAL_WEB_DIST = PORTAL_ROOT / "web" / "dist"
PORTAL_WEB_PREVIEW_BASE = "/portal-react"
PORTAL_WEB_ASSET_BASE = "/account-app"
PORTAL_HEADERS = {
    "Cache-Control": "private, no-store",
    "X-Robots-Tag": "noindex, nofollow, noarchive",
}
HYSTERIA2_ACCOUNT_ROOT = Path("/opt/account/hysteria2")
HYSTERIA2_XRAY_USERNAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
TRAFFIC_WINDOW_SECONDS = 300
TRAFFIC_MAX_WINDOW_SECONDS = 900
TRAFFIC_SAMPLE_INTERVAL_SECONDS = 1
TRAFFIC_MOBILE_REFRESH_SECONDS = 3
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


def _portal_web_asset(path: str) -> Path | None:
    candidate = (PORTAL_WEB_DIST / path).resolve()
    try:
        candidate.relative_to(PORTAL_WEB_DIST.resolve())
    except Exception:
        return None
    if not candidate.is_file():
        return None
    return candidate


def _portal_web_index_file() -> Path:
    index_file = PORTAL_WEB_DIST / "index.html"
    if not index_file.exists():
        raise RuntimeError("Frontend React portal akun belum dibuild.")
    return index_file

def _portal_web_index_response() -> FileResponse:
    try:
        index_file = _portal_web_index_file()
    except RuntimeError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
    return FileResponse(index_file, headers=PORTAL_HEADERS)


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


@app.on_event("startup")
def ensure_portal_web_ready() -> None:
    _portal_web_index_file()


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


@app.get("/health")
def health() -> dict[str, object]:
    return {
        "status": "ok",
        "service": "account-portal",
        "app_root": str(APP_ROOT),
    }


@app.get(PORTAL_WEB_PREVIEW_BASE, response_class=HTMLResponse)
@app.get(f"{PORTAL_WEB_PREVIEW_BASE}/", response_class=HTMLResponse)
@app.get(f"{PORTAL_WEB_PREVIEW_BASE}" + "/{path:path}")
def portal_web_preview(path: str = ""):
    try:
        _portal_web_index_file()
    except RuntimeError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    normalized = str(path or "").strip("/")
    if normalized:
        asset = _portal_web_asset(normalized)
        if asset is not None:
            return FileResponse(asset, headers=PORTAL_HEADERS)

    return _portal_web_index_response()


@app.get(PORTAL_WEB_ASSET_BASE + "/{path:path}")
def portal_web_assets(path: str):
    try:
        _portal_web_index_file()
    except RuntimeError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
    normalized = str(path or "").strip("/")
    asset = _portal_web_asset(normalized)
    if asset is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Asset frontend tidak ditemukan.")
    return FileResponse(asset, headers=PORTAL_HEADERS)


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


@app.get("/account/hysteria2/{username}/xray.json")
def download_hysteria_xray_json(username: str) -> FileResponse:
    username_n = str(username or "").strip()
    if not HYSTERIA2_XRAY_USERNAME_RE.fullmatch(username_n) or username_n.startswith("__"):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File JSON Hysteria tidak ditemukan.")
    xray_file = HYSTERIA2_ACCOUNT_ROOT / f"{username_n}@hy2.xray.json"
    if not xray_file.is_file():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File JSON Hysteria tidak ditemukan.")
    return FileResponse(
        xray_file,
        media_type="application/json",
        filename=xray_file.name,
        headers=PORTAL_HEADERS,
    )


@app.get("/account/{token}", response_class=HTMLResponse)
def account_portal_page(token: str) -> HTMLResponse:
    summary = build_public_account_summary(token)
    if summary is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Portal akun tidak ditemukan.")
    return _portal_web_index_response()

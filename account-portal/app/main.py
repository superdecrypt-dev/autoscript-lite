from __future__ import annotations

import html
from pathlib import Path

from fastapi import FastAPI, HTTPException, status
from fastapi.responses import HTMLResponse, JSONResponse

from .data import build_public_account_summary

APP_ROOT = Path(__file__).resolve().parents[2]
PORTAL_HEADERS = {
    "Cache-Control": "private, no-store",
    "X-Robots-Tag": "noindex, nofollow, noarchive",
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


def _status_badge_class(status_value: str) -> str:
    status_n = str(status_value or "").strip().lower()
    if status_n == "active":
        return "ok"
    if status_n == "expired":
        return "warn"
    return "bad"


def _render_account_portal(summary: dict) -> str:
    status_class = _status_badge_class(str(summary.get("status") or ""))
    active_ip_last_seen = str(summary.get("active_ip_last_seen_at") or "-").strip() or "-"
    days_remaining = summary.get("days_remaining")
    days_label = f"{days_remaining} hari" if isinstance(days_remaining, int) and days_remaining >= 0 else "-"
    active_ip_hint = "Belum ada sesi aktif yang terdeteksi." if active_ip_last_seen == "-" else f"Terakhir terlihat: {active_ip_last_seen}"
    return f"""<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,nofollow,noarchive">
  <title>Portal Info Akun</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg: #120f0b;
      --panel: #1c1712;
      --panel-2: #241d15;
      --text: #f4ede4;
      --muted: #b8ab9b;
      --accent: #d66b22;
      --ok: #1e9b62;
      --warn: #d59b1b;
      --bad: #c84d45;
      --stroke: rgba(255,255,255,0.08);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at top, rgba(214,107,34,0.18), transparent 32%),
        linear-gradient(180deg, #120f0b 0%, #0c0a08 100%);
      color: var(--text);
    }}
    main {{
      max-width: 860px;
      margin: 0 auto;
      padding: 28px 18px 40px;
    }}
    .hero {{
      padding: 20px 22px;
      border: 1px solid var(--stroke);
      border-radius: 24px;
      background: linear-gradient(180deg, rgba(255,255,255,0.04), rgba(255,255,255,0.02));
      box-shadow: 0 24px 80px rgba(0,0,0,0.25);
    }}
    .eyebrow {{
      margin: 0 0 8px;
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
    .status-row {{
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
      margin-top: 18px;
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
    .status-badge.ok {{ color: #bff2d8; background: rgba(30,155,98,0.14); border-color: rgba(30,155,98,0.35); }}
    .status-badge.warn {{ color: #ffdf91; background: rgba(213,155,27,0.14); border-color: rgba(213,155,27,0.35); }}
    .status-badge.bad {{ color: #ffbeb9; background: rgba(200,77,69,0.14); border-color: rgba(200,77,69,0.35); }}
    .note {{
      margin: 0;
      color: var(--muted);
      line-height: 1.5;
    }}
    .grid {{
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
      margin-top: 18px;
    }}
    .card {{
      padding: 16px;
      border: 1px solid var(--stroke);
      border-radius: 18px;
      background: var(--panel);
      min-width: 0;
    }}
    .card h2 {{
      margin: 0 0 14px;
      font-size: 15px;
      color: #f7d1b2;
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
    .foot {{
      margin-top: 16px;
      padding: 16px;
      border: 1px solid var(--stroke);
      border-radius: 18px;
      background: var(--panel-2);
      color: var(--muted);
      line-height: 1.6;
    }}
    code {{
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      color: #ffe7d2;
      word-break: break-all;
    }}
    @media (max-width: 720px) {{
      .grid {{ grid-template-columns: 1fr; }}
      main {{ padding: 18px 14px 28px; }}
      .hero {{ padding: 18px; border-radius: 20px; }}
      .card {{ border-radius: 16px; }}
    }}
  </style>
</head>
<body>
  <main>
    <section class="hero">
      <p class="eyebrow">Portal Info Akun</p>
      <h1>{_escape(summary.get("username"))}</h1>
      <p class="sub">Halaman ini menampilkan status akun, sisa masa aktif, pemakaian quota, dan IP login aktif yang terdeteksi dari runtime.</p>
      <div class="status-row">
        <span class="status-badge {status_class}">{_escape(summary.get("status"))}</span>
        <p class="note">{_escape(summary.get("status_text"))}</p>
      </div>
    </section>

    <section class="grid">
      <article class="card">
        <h2>Ringkasan</h2>
        <dl>
          <div class="metric"><dt>Protocol</dt><dd>{_escape(summary.get("protocol"))}</dd></div>
          <div class="metric"><dt>Valid Until</dt><dd>{_escape(summary.get("valid_until"))}</dd></div>
          <div class="metric"><dt>Sisa Aktif</dt><dd>{_escape(days_label)}</dd></div>
          <div class="metric"><dt>IP Login</dt><dd>{_escape(summary.get("active_ip"))}</dd></div>
        </dl>
      </article>

      <article class="card">
        <h2>Quota</h2>
        <dl>
          <div class="metric"><dt>Limit</dt><dd>{_escape(summary.get("quota_limit"))}</dd></div>
          <div class="metric"><dt>Terpakai</dt><dd>{_escape(summary.get("quota_used"))}</dd></div>
          <div class="metric"><dt>Sisa</dt><dd>{_escape(summary.get("quota_remaining"))}</dd></div>
          <div class="metric"><dt>IP Aktif</dt><dd>{_escape(active_ip_hint)}</dd></div>
        </dl>
      </article>
    </section>

    <section class="foot">
      Token portal ini bersifat read-only dan hanya menampilkan data akun. Link portal:
      <br>
      <code>{_escape(summary.get("portal_url"))}</code>
    </section>
  </main>
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


@app.get("/account/{token}", response_class=HTMLResponse)
def account_portal_page(token: str) -> HTMLResponse:
    summary = build_public_account_summary(token)
    if summary is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Portal akun tidak ditemukan.")
    return HTMLResponse(_render_account_portal(summary), headers=PORTAL_HEADERS)

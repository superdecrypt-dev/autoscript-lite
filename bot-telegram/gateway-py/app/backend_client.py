from __future__ import annotations

from dataclasses import dataclass
import re

import httpx


DEFAULT_TIMEOUT_SECONDS = 30.0
ACTION_TIMEOUTS_SECONDS: dict[str, float] = {
    "5:adblock_enable": 420.0,
    "5:adblock_disable": 120.0,
    "5:adblock_update": 420.0,
    "6:set_domain": 120.0,
    "6:setup_domain_custom": 420.0,
    "6:setup_domain_cloudflare": 420.0,
    "6:domain_guard_check": 190.0,
    "6:domain_guard_renew": 320.0,
    "6:refresh_account_info": 240.0,
    "7:run": 190.0,
    "8:reload_nginx": 60.0,
    "8:renew_cert": 420.0,
    "9:restart_edge_gateway": 90.0,
    "9:restart_badvpn": 90.0,
    "11:restart_edge_gateway": 90.0,
    "11:restart_badvpn": 90.0,
    "12:create_backup": 240.0,
    "12:restore_latest": 420.0,
    "12:restore_from_upload": 420.0,
    "5:warp_restart": 90.0,
    "5:warp_tier_switch_free": 420.0,
    "5:warp_tier_switch_plus": 420.0,
    "5:warp_tier_reconnect": 420.0,
    "7:setup_domain_custom": 420.0,
    "7:setup_domain_cloudflare": 420.0,
    "7:domain_guard_check": 190.0,
    "7:domain_guard_renew": 320.0,
    "8:run": 190.0,
    "6:warp_restart": 90.0,
    "6:warp_tier_switch_free": 420.0,
    "6:warp_tier_switch_plus": 420.0,
    "6:warp_tier_reconnect": 420.0,
    # Backward compatibility for older menu numbering.
    "5:setup_domain_custom": 420.0,
    "5:setup_domain_cloudflare": 420.0,
    "5:domain_guard_check": 190.0,
    "5:domain_guard_renew": 320.0,
    "6:run": 190.0,
    "4:warp_restart": 90.0,
    "4:warp_tier_switch_free": 420.0,
    "4:warp_tier_switch_plus": 420.0,
    "4:warp_tier_reconnect": 420.0,
}

TELEGRAM_TOKEN_RE = re.compile(r"\b\d{6,}:[A-Za-z0-9_-]{20,}\b")
DISCORD_TOKEN_RE = re.compile(r"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{20,}\b")


def _mask_secret(raw: str) -> str:
    text = str(raw or "").strip()
    if not text:
        return text
    if len(text) <= 8:
        return "********"
    return f"{text[:4]}****{text[-4:]}"


def _sanitize_text(raw: str) -> str:
    text = str(raw or "")
    text = TELEGRAM_TOKEN_RE.sub(lambda m: _mask_secret(m.group(0)), text)
    text = DISCORD_TOKEN_RE.sub(lambda m: _mask_secret(m.group(0)), text)
    return text


@dataclass
class BackendActionResponse:
    ok: bool
    code: str
    title: str
    message: str
    data: dict


@dataclass(frozen=True)
class BackendUserOption:
    proto: str
    username: str


@dataclass(frozen=True)
class BackendInboundOption:
    tag: str


@dataclass(frozen=True)
class BackendDomainOption:
    entry: str


@dataclass(frozen=True)
class BackendRootDomainOption:
    root_domain: str


class BackendError(RuntimeError):
    pass


class BackendClient:
    def __init__(self, base_url: str, shared_secret: str) -> None:
        self._base_url = base_url.rstrip("/")
        self._headers = {"X-Internal-Shared-Secret": shared_secret}

    def _new_client(self, timeout: float) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=self._base_url,
            headers=self._headers,
            timeout=timeout,
            follow_redirects=False,
            limits=httpx.Limits(max_keepalive_connections=5, max_connections=10),
        )

    async def run_action(self, menu_id: str, action: str, params: dict[str, str]) -> BackendActionResponse:
        timeout = ACTION_TIMEOUTS_SECONDS.get(f"{menu_id}:{action}", DEFAULT_TIMEOUT_SECONDS)
        payload = {"action": action, "params": params}

        try:
            async with self._new_client(timeout=timeout) as client:
                response = await client.post(f"/api/menu/{menu_id}/action", json=payload)
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise BackendError(f"HTTP {exc.response.status_code}: {_sanitize_text(body[:400])}") from exc
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        if not isinstance(data, dict):
            raise BackendError("Response backend tidak valid (bukan JSON object).")

        return BackendActionResponse(
            ok=bool(data.get("ok", False)),
            code=str(data.get("code") or "unknown"),
            title=str(data.get("title") or "Result"),
            message=str(data.get("message") or ""),
            data=data.get("data") if isinstance(data.get("data"), dict) else {},
        )

    async def get_main_menu(self, timeout: float = 8.0) -> dict:
        try:
            async with self._new_client(timeout=timeout) as client:
                response = await client.get("/api/main-menu")
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise BackendError(f"HTTP {exc.response.status_code}: {_sanitize_text(body[:400])}") from exc
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        if not isinstance(data, dict):
            raise BackendError("Response backend main-menu tidak valid.")
        return data

    async def list_user_options(self, proto: str | None = None) -> list[BackendUserOption]:
        params = {"proto": proto} if proto else None
        try:
            async with self._new_client(timeout=15.0) as client:
                response = await client.get("/api/users/options", params=params)
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise BackendError(f"HTTP {exc.response.status_code}: {_sanitize_text(body[:400])}") from exc
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        users_raw = data.get("users") if isinstance(data, dict) else None
        if not isinstance(users_raw, list):
            return []

        out: list[BackendUserOption] = []
        for item in users_raw:
            if not isinstance(item, dict):
                continue
            p = str(item.get("proto") or "").strip().lower()
            u = str(item.get("username") or "").strip()
            if not p or not u:
                continue
            out.append(BackendUserOption(proto=p, username=u))
        return out

    async def get_qac_user_summary(self, proto: str, username: str) -> dict[str, str]:
        params = {"proto": proto, "username": username}
        try:
            async with self._new_client(timeout=15.0) as client:
                response = await client.get("/api/qac/user-summary", params=params)
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise BackendError(f"HTTP {exc.response.status_code}: {_sanitize_text(body[:400])}") from exc
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        if not isinstance(data, dict):
            raise BackendError("Response backend qac summary tidak valid.")
        if not bool(data.get("ok")):
            raise BackendError(str(data.get("error") or "Gagal membaca QAC summary."))
        summary = data.get("summary")
        if not isinstance(summary, dict):
            raise BackendError("Payload QAC summary tidak valid.")
        return {str(k): str(v) for k, v in summary.items()}

    async def list_inbound_options(self) -> list[BackendInboundOption]:
        try:
            async with self._new_client(timeout=15.0) as client:
                response = await client.get("/api/inbounds/options")
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise BackendError(f"HTTP {exc.response.status_code}: {_sanitize_text(body[:400])}") from exc
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        inb_raw = data.get("inbounds") if isinstance(data, dict) else None
        if not isinstance(inb_raw, list):
            return []

        out: list[BackendInboundOption] = []
        for item in inb_raw:
            if not isinstance(item, dict):
                continue
            tag = str(item.get("tag") or "").strip()
            if not tag:
                continue
            out.append(BackendInboundOption(tag=tag))
        return out

    async def list_warp_domain_options(self, mode: str | None = None) -> list[BackendDomainOption]:
        params = {"mode": mode} if mode else None
        try:
            async with self._new_client(timeout=15.0) as client:
                response = await client.get("/api/network/domain-options", params=params)
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise BackendError(f"HTTP {exc.response.status_code}: {_sanitize_text(body[:400])}") from exc
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        raw_entries = data.get("entries") if isinstance(data, dict) else None
        if not isinstance(raw_entries, list):
            return []

        out: list[BackendDomainOption] = []
        for item in raw_entries:
            if not isinstance(item, dict):
                continue
            entry = str(item.get("entry") or "").strip()
            if not entry:
                continue
            out.append(BackendDomainOption(entry=entry))
        return out

    async def list_adblock_manual_options(self) -> list[BackendDomainOption]:
        try:
            async with self._new_client(timeout=15.0) as client:
                response = await client.get("/api/network/adblock/manual-options")
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise BackendError(f"HTTP {exc.response.status_code}: {_sanitize_text(body[:400])}") from exc
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        raw_entries = data.get("entries") if isinstance(data, dict) else None
        if not isinstance(raw_entries, list):
            return []
        out: list[BackendDomainOption] = []
        for item in raw_entries:
            if not isinstance(item, dict):
                continue
            entry = str(item.get("entry") or "").strip()
            if not entry:
                continue
            out.append(BackendDomainOption(entry=entry))
        return out

    async def list_adblock_url_options(self) -> list[BackendDomainOption]:
        try:
            async with self._new_client(timeout=15.0) as client:
                response = await client.get("/api/network/adblock/url-options")
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise BackendError(f"HTTP {exc.response.status_code}: {_sanitize_text(body[:400])}") from exc
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        raw_entries = data.get("entries") if isinstance(data, dict) else None
        if not isinstance(raw_entries, list):
            return []
        out: list[BackendDomainOption] = []
        for item in raw_entries:
            if not isinstance(item, dict):
                continue
            entry = str(item.get("entry") or "").strip()
            if not entry:
                continue
            out.append(BackendDomainOption(entry=entry))
        return out

    async def list_domain_root_options(self) -> list[BackendRootDomainOption]:
        try:
            async with self._new_client(timeout=15.0) as client:
                response = await client.get("/api/domain/root-options")
                response.raise_for_status()
                data = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise BackendError(f"HTTP {exc.response.status_code}: {_sanitize_text(body[:400])}") from exc
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        raw_roots = data.get("roots") if isinstance(data, dict) else None
        if not isinstance(raw_roots, list):
            return []

        out: list[BackendRootDomainOption] = []
        for item in raw_roots:
            if not isinstance(item, dict):
                continue
            root_domain = str(item.get("root_domain") or "").strip().lower()
            if not root_domain:
                continue
            out.append(BackendRootDomainOption(root_domain=root_domain))
        return out

    async def health(self) -> dict:
        try:
            async with self._new_client(timeout=8.0) as client:
                response = await client.get("/health")
                response.raise_for_status()
                data = response.json()
        except Exception as exc:
            raise BackendError(_sanitize_text(str(exc))) from exc

        if not isinstance(data, dict):
            raise BackendError("Response health backend tidak valid.")
        return data

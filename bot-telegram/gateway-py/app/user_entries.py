from __future__ import annotations

from .backend_client import BackendClient


async def load_menu_user_entries(
    backend: BackendClient,
    *,
    protocols: tuple[str, ...],
) -> list[dict[str, str]]:
    proto_filter = None
    if len(protocols) == 1:
        proto_filter = protocols[0]

    options = await backend.list_user_options(proto=proto_filter)
    users: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for option in options:
        proto = str(option.proto or "").strip().lower()
        username = str(option.username or "").strip()
        if proto not in protocols or not username:
            continue
        key = (proto, username)
        if key in seen:
            continue
        seen.add(key)
        users.append({"proto": proto, "username": username})

    users.sort(key=lambda item: (str(item.get("username") or "").lower(), str(item.get("proto") or "").lower()))
    return users

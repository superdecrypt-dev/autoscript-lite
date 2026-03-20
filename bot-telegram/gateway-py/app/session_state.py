from __future__ import annotations

from typing import Any, Iterable


def chat_scope_id(chat_id: int | str | None) -> str:
    return str(chat_id or "").strip()


def store_pending_state(user_data: dict[str, Any], key: str, pending: dict, chat_id: int | str | None) -> dict:
    state = dict(pending)
    state["origin_chat_id"] = chat_scope_id(chat_id)
    user_data[key] = state
    return state


def get_pending_state(
    user_data: dict[str, Any],
    key: str,
    chat_id: int | str | None,
    *,
    other_chat_text: str,
) -> tuple[dict | None, str]:
    pending = user_data.get(key)
    if not isinstance(pending, dict):
        return None, ""

    current_chat_id = chat_scope_id(chat_id)
    origin_chat_id = chat_scope_id(pending.get("origin_chat_id"))
    if origin_chat_id and current_chat_id and origin_chat_id != current_chat_id:
        return None, other_chat_text

    if current_chat_id and not origin_chat_id:
        pending = store_pending_state(user_data, key, pending, current_chat_id)
    return pending, ""


def clear_pending_states(user_data: dict[str, Any], keys: Iterable[str]) -> None:
    for key in keys:
        user_data.pop(key, None)


def has_pending_state_in_other_chat(
    user_data: dict[str, Any],
    keys: Iterable[str],
    chat_id: int | str | None,
) -> bool:
    current_chat_id = chat_scope_id(chat_id)
    if not current_chat_id:
        return False

    for key in keys:
        pending = user_data.get(key)
        if not isinstance(pending, dict):
            continue
        origin_chat_id = chat_scope_id(pending.get("origin_chat_id"))
        if origin_chat_id and origin_chat_id != current_chat_id:
            return True
    return False


def _state_bucket(user_data: dict[str, Any], key: str) -> dict[str, dict]:
    raw = user_data.get(key)
    if isinstance(raw, dict):
        return raw
    store: dict[str, dict] = {}
    user_data[key] = store
    return store


def set_menu_parent_page(
    user_data: dict[str, Any],
    state_key: str,
    menu_id: str,
    *,
    chat_id: int | str | None,
    parent_page: int,
) -> None:
    store = _state_bucket(user_data, state_key)
    store[menu_id] = {
        "origin_chat_id": chat_scope_id(chat_id),
        "page": max(0, int(parent_page)),
    }


def get_menu_parent_page(
    user_data: dict[str, Any],
    state_key: str,
    menu_id: str,
    *,
    chat_id: int | str | None,
    safe_int,
) -> int:
    raw = _state_bucket(user_data, state_key).get(menu_id)
    if not isinstance(raw, dict):
        return 0
    current_chat_id = chat_scope_id(chat_id)
    origin_chat_id = chat_scope_id(raw.get("origin_chat_id"))
    if origin_chat_id and current_chat_id and origin_chat_id != current_chat_id:
        return 0
    return max(0, safe_int(str(raw.get("page") or "0"), default=0))


def set_qac_selection(
    user_data: dict[str, Any],
    state_key: str,
    menu_id: str,
    *,
    chat_id: int | str | None,
    proto: str,
    username: str,
) -> None:
    store = _state_bucket(user_data, state_key)
    store[menu_id] = {
        "origin_chat_id": chat_scope_id(chat_id),
        "proto": str(proto or "").strip().lower(),
        "username": str(username or "").strip(),
    }


def clear_qac_selection(user_data: dict[str, Any], state_key: str, menu_id: str) -> None:
    store = _state_bucket(user_data, state_key)
    store.pop(menu_id, None)


def get_qac_selection(
    user_data: dict[str, Any],
    state_key: str,
    menu_id: str,
    *,
    chat_id: int | str | None,
    allowed_protocols: Iterable[str],
) -> dict | None:
    raw = _state_bucket(user_data, state_key).get(menu_id)
    if not isinstance(raw, dict):
        return None
    current_chat_id = chat_scope_id(chat_id)
    origin_chat_id = chat_scope_id(raw.get("origin_chat_id"))
    if origin_chat_id and current_chat_id and origin_chat_id != current_chat_id:
        return None
    proto = str(raw.get("proto") or "").strip().lower()
    username = str(raw.get("username") or "").strip()
    if not proto or not username:
        return None
    if proto not in tuple(allowed_protocols):
        return None
    return {"proto": proto, "username": username}

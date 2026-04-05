from __future__ import annotations

import html

from telegram import InlineKeyboardButton, InlineKeyboardMarkup

from .commands_loader import MenuSpec


def qac_picker_title(menu_id: str, *, xray_qac_menu_id: str) -> str:
    if menu_id == xray_qac_menu_id:
        return "Xray QAC"
    return "Quota & Access Control"


def qac_selection_params(menu_id: str, selection: dict | None, *, xray_qac_menu_id: str) -> dict[str, str]:
    if not isinstance(selection, dict):
        return {}
    proto = str(selection.get("proto") or "").strip().lower()
    username = str(selection.get("username") or "").strip()
    if not username:
        return {}
    params = {"username": username}
    if menu_id == xray_qac_menu_id and proto:
        params["proto"] = proto
    return params


def qac_selection_label(menu_id: str, selection: dict | None, *, xray_qac_menu_id: str) -> str:
    if not isinstance(selection, dict):
        return "-"
    proto = str(selection.get("proto") or "").strip().lower()
    username = str(selection.get("username") or "").strip()
    if not username:
        return "-"
    if menu_id == xray_qac_menu_id and proto:
        return f"{username}@{proto}"
    return username


def qac_picker_entry_label(menu_id: str, proto: str, username: str, *, xray_qac_menu_id: str) -> str:
    if menu_id == xray_qac_menu_id:
        return f"{username}@{proto}"
    return username


def qac_menu_text(
    menu: MenuSpec,
    selection: dict,
    summary: dict[str, str] | None,
    page: int,
    total_pages: int,
    *,
    xray_qac_menu_id: str,
) -> str:
    lines = [f"<b>{html.escape(menu.label)}</b>"]
    if menu.description:
        lines.append(html.escape(menu.description))

    active_label = qac_selection_label(menu.id, selection, xray_qac_menu_id=xray_qac_menu_id)
    if summary:
        lines.extend(
            [
                "",
                "<pre>"
                + html.escape(
                    "\n".join(
                        [
                            f"Username       : {str(summary.get('username') or active_label)}",
                            f"Quota Limit    : {str(summary.get('quota_limit') or '-')}",
                            f"Quota Used     : {str(summary.get('quota_used') or '-')}",
                            f"Expired At     : {str(summary.get('expired_at') or '-')}",
                            f"IP Limit       : {str(summary.get('ip_limit') or '-')}",
                            f"Block Reason   : {str(summary.get('block_reason') or '-')}",
                            f"IP Limit Max   : {str(summary.get('ip_limit_max') or '-')}",
                            f"Speed Download : {str(summary.get('speed_download') or '-')}",
                            f"Speed Upload   : {str(summary.get('speed_upload') or '-')}",
                            f"Speed Limit    : {str(summary.get('speed_limit') or '-')}",
                        ]
                    )
                )
                + "</pre>",
            ]
        )
    else:
        lines.extend(["", f"User aktif: <code>{html.escape(active_label)}</code>"])

    lines.extend(["", f"Halaman aksi <code>{page + 1}/{max(total_pages, 1)}</code>", "Pilih action:"])
    return "\n".join(lines)


def qac_menu_keyboard(
    menu: MenuSpec,
    page: int,
    *,
    callback_sep: str,
    base_markup: InlineKeyboardMarkup,
) -> InlineKeyboardMarkup:
    rows = list(base_markup.inline_keyboard)
    utility_row = [
        InlineKeyboardButton("🔄 Refresh Summary", callback_data=f"qac_refresh{callback_sep}{menu.id}{callback_sep}{page}"),
        InlineKeyboardButton("🔁 Ganti User", callback_data=f"qac_pick_menu{callback_sep}{menu.id}{callback_sep}{page}"),
    ]
    if rows and rows[-1]:
        footer_callbacks = {str(btn.callback_data or "") for btn in rows[-1]}
        if "h" in footer_callbacks or any(
            cb == f"m{callback_sep}{menu.parent_menu}" or cb.startswith(f"m{callback_sep}{menu.parent_menu}{callback_sep}")
            for cb in footer_callbacks
        ):
            rows.insert(-1, utility_row)
        else:
            rows.append(utility_row)
    else:
        rows.append(utility_row)
    return InlineKeyboardMarkup(rows)


def qac_pick_keyboard(
    menu_id: str,
    return_menu_id: str,
    page: int,
    users: list[dict[str, str]],
    menu_page: int,
    *,
    callback_sep: str,
    delete_pick_page_size: int,
    short_button_label,
    rows_from_buttons,
    xray_qac_menu_id: str,
) -> InlineKeyboardMarkup:
    rows: list[list[InlineKeyboardButton]] = []
    start = page * delete_pick_page_size
    chunk = users[start : start + delete_pick_page_size]

    user_buttons: list[InlineKeyboardButton] = []
    for idx, item in enumerate(chunk, start=start):
        label = qac_picker_entry_label(
            menu_id,
            str(item.get("proto") or ""),
            str(item.get("username") or ""),
            xray_qac_menu_id=xray_qac_menu_id,
        )
        user_buttons.append(
            InlineKeyboardButton(
                short_button_label(label, max_len=22),
                callback_data=f"qac_pick{callback_sep}{idx}",
            )
        )
    rows.extend(rows_from_buttons(user_buttons))

    total_pages = ((len(users) - 1) // delete_pick_page_size) + 1 if users else 1
    if total_pages > 1:
        nav: list[InlineKeyboardButton] = []
        if page > 0:
            nav.append(InlineKeyboardButton("◀️ Prev", callback_data=f"qac_page{callback_sep}{page - 1}"))
        nav.append(InlineKeyboardButton(f"{page + 1}/{total_pages}", callback_data="noop"))
        if page + 1 < total_pages:
            nav.append(InlineKeyboardButton("Next ▶️", callback_data=f"qac_page{callback_sep}{page + 1}"))
        rows.append(nav)

    rows.append(
        [
            InlineKeyboardButton(
                "⬅️ Kembali",
                callback_data=f"m{callback_sep}{return_menu_id}{callback_sep}{max(menu_page, 0)}",
            )
        ]
    )
    return InlineKeyboardMarkup(rows)


def qac_pick_text(
    menu_id: str,
    page: int,
    users: list[dict[str, str]],
    *,
    delete_pick_page_size: int,
    xray_qac_menu_id: str,
) -> str:
    total_pages = ((len(users) - 1) // delete_pick_page_size) + 1 if users else 1
    return (
        f"<b>{html.escape(qac_picker_title(menu_id, xray_qac_menu_id=xray_qac_menu_id))}</b>\n"
        "Pilih user dulu untuk membuka menu QAC.\n\n"
        f"Total user: <code>{len(users)}</code>\n"
        f"Halaman: <code>{page + 1}/{total_pages}</code>"
    )

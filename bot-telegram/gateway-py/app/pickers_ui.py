from __future__ import annotations

import html

from telegram import InlineKeyboardButton, InlineKeyboardMarkup


    if menu_id == xray_user_menu_id:
        return "Xray Users"
    return "User Management"


    if menu_id == xray_user_menu_id:
        return "Xray Users"
    return "Accounts"


def account_picker_entry_label(menu_id: str, proto: str, username: str, *, xray_user_menu_id: str) -> str:
    if menu_id == xray_user_menu_id:
        return f"{username}@{proto}"
    return username


def account_picker_return_keyboard(menu_id: str, menu_page: int, *, callback_sep: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        [[InlineKeyboardButton("⬅️ Kembali", callback_data=f"m{callback_sep}{menu_id}{callback_sep}{max(menu_page, 0)}")]]
    )


def account_pick_keyboard(
    menu_id: str,
    page: int,
    users: list[dict[str, str]],
    menu_page: int,
    *,
    callback_sep: str,
    delete_pick_page_size: int,
    short_button_label,
    rows_from_buttons,
    xray_user_menu_id: str,
) -> InlineKeyboardMarkup:
    rows: list[list[InlineKeyboardButton]] = []
    start = page * delete_pick_page_size
    chunk = users[start : start + delete_pick_page_size]

    user_buttons: list[InlineKeyboardButton] = []
    for idx, item in enumerate(chunk, start=start):
        label = account_picker_entry_label(
            menu_id,
            str(item.get("proto") or ""),
            str(item.get("username") or ""),
            xray_user_menu_id=xray_user_menu_id,
        )
        user_buttons.append(
            InlineKeyboardButton(
                short_button_label(label, max_len=22),
                callback_data=f"acc_pick{callback_sep}{idx}",
            )
        )
    rows.extend(rows_from_buttons(user_buttons))

    total_pages = ((len(users) - 1) // delete_pick_page_size) + 1 if users else 1
    if total_pages > 1:
        nav: list[InlineKeyboardButton] = []
        if page > 0:
            nav.append(InlineKeyboardButton("◀️ Prev", callback_data=f"acc_page{callback_sep}{page - 1}"))
        nav.append(InlineKeyboardButton(f"{page + 1}/{total_pages}", callback_data="noop"))
        if page + 1 < total_pages:
            nav.append(InlineKeyboardButton("Next ▶️", callback_data=f"acc_page{callback_sep}{page + 1}"))
        rows.append(nav)

    rows.extend(account_picker_return_keyboard(menu_id, menu_page, callback_sep=callback_sep).inline_keyboard)
    return InlineKeyboardMarkup(rows)


def account_pick_text(
    menu_id: str,
    action_label: str,
    page: int,
    users: list[dict[str, str]],
    *,
    delete_pick_page_size: int,
    xray_user_menu_id: str,
) -> str:
    total_pages = ((len(users) - 1) // delete_pick_page_size) + 1 if users else 1
    return (
        "Pilih user dulu dari daftar.\n\n"
        f"Total user: <code>{len(users)}</code>\n"
        f"Halaman: <code>{page + 1}/{total_pages}</code>"
    )


def delete_pick_proto_keyboard(
    menu_id: str,
    menu_page: int,
    *,
    callback_sep: str,
    protocols: tuple[str, ...],
    rows_from_buttons,
) -> InlineKeyboardMarkup:
    rows: list[list[InlineKeyboardButton]] = []
    proto_buttons = [
        InlineKeyboardButton(
            proto.upper(),
            callback_data=f"dup_proto{callback_sep}{menu_id}{callback_sep}{proto}{callback_sep}{max(menu_page, 0)}",
        )
        for proto in protocols
    ]
    rows.extend(rows_from_buttons(proto_buttons))
    rows.append(
        [[InlineKeyboardButton("⬅️ Kembali", callback_data=f"m{callback_sep}{menu_id}{callback_sep}{max(menu_page, 0)}")]]
    )
    return InlineKeyboardMarkup(rows)


def delete_pick_return_keyboard(
    menu_id: str,
    menu_page: int,
    *,
    callback_sep: str,
    protocols: tuple[str, ...],
) -> InlineKeyboardMarkup:
    rows: list[list[InlineKeyboardButton]] = []
    if len(protocols) > 1:
        rows.append(
            [
                InlineKeyboardButton(
                    "↩️ Ganti Protocol",
                    callback_data=f"dup_proto_menu{callback_sep}{menu_id}{callback_sep}{max(menu_page, 0)}",
                )
            ]
        )
    rows.append(
        [[InlineKeyboardButton("⬅️ Kembali", callback_data=f"m{callback_sep}{menu_id}{callback_sep}{max(menu_page, 0)}")]]
    )
    return InlineKeyboardMarkup(rows)


def protocol_choices_for_action(
    menu_id: str,
    action_id: str,
    *,
    scoped: tuple[str, ...],
    user_protocols: tuple[str, ...],
    xray_protocols: tuple[str, ...],
) -> tuple[str, ...]:
    if scoped != user_protocols:
        return scoped
    return xray_protocols


def delete_pick_users_keyboard(
    menu_id: str,
    page: int,
    users: list[str],
    menu_page: int,
    *,
    callback_sep: str,
    delete_pick_page_size: int,
    short_button_label,
    rows_from_buttons,
    return_keyboard: InlineKeyboardMarkup,
) -> InlineKeyboardMarkup:
    rows: list[list[InlineKeyboardButton]] = []
    start = page * delete_pick_page_size
    chunk = users[start : start + delete_pick_page_size]

    user_buttons: list[InlineKeyboardButton] = []
    for idx, username in enumerate(chunk, start=start):
        user_buttons.append(
            InlineKeyboardButton(
                short_button_label(username, max_len=22),
                callback_data=f"dup_user{callback_sep}{idx}",
            )
        )
    rows.extend(rows_from_buttons(user_buttons))

    total_pages = ((len(users) - 1) // delete_pick_page_size) + 1 if users else 1
    if total_pages > 1:
        nav: list[InlineKeyboardButton] = []
        if page > 0:
            nav.append(InlineKeyboardButton("◀️ Prev", callback_data=f"dup_page{callback_sep}{page - 1}"))
        nav.append(InlineKeyboardButton(f"{page + 1}/{total_pages}", callback_data="noop"))
        if page + 1 < total_pages:
            nav.append(InlineKeyboardButton("Next ▶️", callback_data=f"dup_page{callback_sep}{page + 1}"))
        rows.append(nav)

    rows.extend(return_keyboard.inline_keyboard)
    return InlineKeyboardMarkup(rows)


def delete_pick_text_proto(
    menu_id: str,
    *,
    xray_user_menu_id: str,
) -> str:
    return (
        "Pilih protocol dulu, lalu pilih username dari daftar."
    )


def delete_pick_text_users(
    menu_id: str,
    proto: str,
    page: int,
    users: list[str],
    *,
    delete_pick_page_size: int,
    xray_user_menu_id: str,
) -> str:
    total_pages = ((len(users) - 1) // delete_pick_page_size) + 1 if users else 1
    return (
        f"Protocol: <code>{html.escape(proto.upper())}</code>\n"
        f"Total user: <code>{len(users)}</code>\n"
        f"Halaman: <code>{page + 1}/{total_pages}</code>\n"
        "Pilih user yang mau dihapus:"
    )

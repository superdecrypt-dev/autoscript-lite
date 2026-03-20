from __future__ import annotations

from typing import Any

from telegram import InlineKeyboardButton, InlineKeyboardMarkup

from .commands_loader import ActionSpec, MenuSpec


def short_button_label(text: str, max_len: int) -> str:
    if len(text) <= max_len:
        return text
    if max_len < 4:
        return text[:max_len]
    return text[: max_len - 3] + "..."


def rows_from_buttons(buttons: list[InlineKeyboardButton], per_row: int) -> list[list[InlineKeyboardButton]]:
    rows: list[list[InlineKeyboardButton]] = []
    for idx in range(0, len(buttons), per_row):
        rows.append(buttons[idx : idx + per_row])
    return rows


def action_visible(runtime: Any, action: ActionSpec) -> bool:
    if action.dangerous and not runtime.config.mutations_enabled:
        return False
    return True


def visible_actions(runtime: Any, menu: MenuSpec) -> list[ActionSpec]:
    return [action for action in menu.actions if action_visible(runtime, action)]


def visible_main_menus(runtime: Any) -> list[MenuSpec]:
    return [
        menu
        for menu in runtime.catalog.menus
        if not menu.hidden and visible_actions(runtime, menu)
    ]


def menu_pages(runtime: Any, menu: MenuSpec, *, actions_per_page: int) -> int:
    total = len(visible_actions(runtime, menu))
    if total <= 0:
        return 1
    return ((total - 1) // actions_per_page) + 1


def main_menu_keyboard(
    runtime: Any,
    *,
    callback_sep: str,
    buttons_per_row: int,
    button_label_max: int,
) -> InlineKeyboardMarkup:
    buttons: list[InlineKeyboardButton] = []
    for menu in visible_main_menus(runtime):
        if not visible_actions(runtime, menu):
            continue
        buttons.append(
            InlineKeyboardButton(
                short_button_label(menu.label, button_label_max),
                callback_data=f"m{callback_sep}{menu.id}",
            )
        )

    rows = rows_from_buttons(buttons, buttons_per_row)
    rows.append([InlineKeyboardButton("🔄 Refresh", callback_data="h")])
    return InlineKeyboardMarkup(rows)


def menu_keyboard(
    runtime: Any,
    menu: MenuSpec,
    page: int,
    *,
    parent_page: int,
    actions_per_page: int,
    buttons_per_row: int,
    button_label_max: int,
    callback_sep: str,
) -> InlineKeyboardMarkup:
    visible = visible_actions(runtime, menu)
    total_pages = menu_pages(runtime, menu, actions_per_page=actions_per_page)
    page = max(0, min(page, total_pages - 1))

    start = page * actions_per_page
    chunk = visible[start : start + actions_per_page]

    buttons: list[InlineKeyboardButton] = []
    for action in chunk:
        buttons.append(
            InlineKeyboardButton(
                short_button_label(action.label, button_label_max),
                callback_data=f"a{callback_sep}{menu.id}{callback_sep}{page}{callback_sep}{action.id}",
            )
        )

    rows = rows_from_buttons(buttons, buttons_per_row)

    if total_pages > 1:
        nav: list[InlineKeyboardButton] = []
        if page > 0:
            nav.append(InlineKeyboardButton("◀️ Prev", callback_data=f"p{callback_sep}{menu.id}{callback_sep}{page - 1}"))
        nav.append(InlineKeyboardButton(f"{page + 1}/{total_pages}", callback_data="noop"))
        if page + 1 < total_pages:
            nav.append(InlineKeyboardButton("Next ▶️", callback_data=f"p{callback_sep}{menu.id}{callback_sep}{page + 1}"))
        rows.append(nav)

    footer: list[InlineKeyboardButton] = []
    if menu.parent_menu:
        footer.append(
            InlineKeyboardButton(
                "⬅️ Kembali",
                callback_data=f"m{callback_sep}{menu.parent_menu}{callback_sep}{max(parent_page, 0)}",
            )
        )
    footer.append(InlineKeyboardButton("🏠 Main Menu", callback_data="h"))
    rows.append(footer)
    return InlineKeyboardMarkup(rows)


def result_keyboard(menu_id: str, page: int, *, callback_sep: str, qac_menu_ids: set[str]) -> InlineKeyboardMarkup:
    back_label = "⬅️ Kembali ke Panel QAC" if menu_id in qac_menu_ids else "⬅️ Kembali ke Action"
    return InlineKeyboardMarkup(
        [
            [InlineKeyboardButton(back_label, callback_data=f"m{callback_sep}{menu_id}{callback_sep}{max(page, 0)}")],
            [InlineKeyboardButton("🏠 Main Menu", callback_data="h")],
        ]
    )


def confirm_keyboard(menu_id: str, page: int, *, callback_sep: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("✅ Jalankan", callback_data="rc"),
                InlineKeyboardButton("❌ Batal", callback_data=f"cf{callback_sep}{menu_id}{callback_sep}{max(page, 0)}"),
            ],
        ]
    )

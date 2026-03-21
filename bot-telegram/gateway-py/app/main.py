from __future__ import annotations
import asyncio
import io
import logging
import os
import socket
import time
from dataclasses import dataclass
import html
from pathlib import Path

from telegram import BotCommand, InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.error import BadRequest, NetworkError
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from .backend_client import (
    BackendClient,
    BackendDomainOption,
    BackendError,
    BackendInboundOption,
    BackendRootDomainOption,
    BackendUserOption,
)
from .commands_loader import ActionSpec, CommandCatalog, MenuSpec
from .config import AppConfig, load_config
from .file_transfer import (
    cleanup_uploaded_archive,
    format_size,
    resolve_local_download,
    resolve_restore_upload_dir,
)
from .redaction import configure_masked_logging, sanitize_secret_text
from .session_state import (
    chat_scope_id,
    clear_pending_states,
    clear_qac_selection as session_clear_qac_selection,
    get_menu_parent_page as session_get_menu_parent_page,
    get_pending_state as session_get_pending_state,
    get_qac_selection as session_get_qac_selection,
    has_pending_state_in_other_chat as session_has_pending_state_in_other_chat,
    set_menu_parent_page as session_set_menu_parent_page,
    set_qac_selection as session_set_qac_selection,
    store_pending_state as session_store_pending_state,
)
from .user_entries import load_menu_user_entries
from .pickers_ui import (
    account_pick_keyboard as picker_account_pick_keyboard,
    account_pick_text as picker_account_pick_text,
    account_picker_return_keyboard as picker_account_picker_return_keyboard,
    account_picker_title as picker_account_picker_title,
    delete_pick_proto_keyboard as picker_delete_pick_proto_keyboard,
    delete_pick_return_keyboard as picker_delete_pick_return_keyboard,
    delete_pick_text_proto as picker_delete_pick_text_proto,
    delete_pick_text_users as picker_delete_pick_text_users,
    delete_pick_users_keyboard as picker_delete_pick_users_keyboard,
    delete_picker_title as picker_delete_picker_title,
    protocol_choices_for_action as picker_protocol_choices_for_action,
)
from .qac_ui import (
    qac_menu_keyboard as qac_ui_menu_keyboard,
    qac_menu_text as qac_ui_menu_text,
    qac_pick_keyboard as qac_ui_pick_keyboard,
    qac_pick_text as qac_ui_pick_text,
    qac_picker_title as qac_ui_picker_title,
    qac_selection_label as qac_ui_selection_label,
    qac_selection_params as qac_ui_selection_params,
)
from .ui_helpers import (
    action_visible as ui_action_visible,
    confirm_keyboard as ui_confirm_keyboard,
    main_menu_keyboard as ui_main_menu_keyboard,
    menu_keyboard as ui_menu_keyboard,
    menu_pages as ui_menu_pages,
    result_keyboard as ui_result_keyboard,
    rows_from_buttons as ui_rows_from_buttons,
    short_button_label as ui_short_button_label,
    visible_actions as ui_visible_actions,
    visible_main_menus as ui_visible_main_menus,
)
from .render import (
    action_form_prompt,
    action_result_text,
    confirm_text,
    decode_download_payload,
    main_menu_text,
    menu_text,
    sanitize_download_attachment,
)


LOGGER = logging.getLogger("bot-telegram-gateway")
BACKEND_MENU_SYNC_TIMEOUT_SECONDS = 30.0
BACKEND_MENU_SYNC_RETRY_INTERVAL_SECONDS = 1.0
CALLBACK_SEP = "|"
ACTIONS_PER_PAGE = 6
BUTTONS_PER_ROW = 2
BUTTON_LABEL_MAX = 28
CALLBACK_DATA_MAX_LEN = 96
CLEANUP_FULL_SWEEP = -1
CLEANUP_MAX_LIMIT = 200
CLEANUP_KEEP_MESSAGES = 1
CLEANUP_MAX_SCAN_IDS = 2000
DELETE_PICK_PAGE_SIZE = 12
FORM_CHOICE_PAGE_SIZE = 12
XRAY_PROTOCOLS = ("vless", "vmess", "trojan")
USER_PROTOCOLS = XRAY_PROTOCOLS + ("ssh",)
XRAY_USER_MENU_ID = "22"
SSH_USER_MENU_ID = "23"
XRAY_QAC_MENU_ID = "24"
SSH_QAC_MENU_ID = "25"
BACKUP_MENU_ID = "32"
SSH_NETWORK_MENU_IDS = {"34", "37", "38", "39", "40", "41"}
DELETE_PICK_MENU_IDS = {XRAY_USER_MENU_ID, SSH_USER_MENU_ID}
QAC_MENU_IDS = {XRAY_QAC_MENU_ID, SSH_QAC_MENU_ID}
ACCOUNT_PICK_ACTION_IDS = {"account_info", "delete_user", "extend_expiry", "reset_password", "reset_credential"}
ROOT_DOMAIN_FALLBACK_OPTIONS = (
    "vyxara1.web.id",
    "vyxara2.web.id",
)
FORM_CHOICE_MANUAL_VALUE = "__manual_input__"
FORM_CHOICE_SKIP_VALUE = "__skip_optional__"
FORM_CHOICE_USERNAME_ACTIONS = {
    "extend_expiry",
    "account_info",
    "reset_password",
    "reset_credential",
    "detail",
    "set_quota_limit",
    "reset_quota_used",
    "manual_block",
    "ip_limit_enable",
    "set_ip_limit",
    "unlock_ip_lock",
    "set_speed_download",
    "set_speed_upload",
    "speed_limit",
    "set_warp_user_mode",
    "routing_ssh_user_inherit",
    "routing_ssh_user_direct",
    "routing_ssh_user_warp",
    "warp_ssh_user_enable",
    "warp_ssh_user_disable",
    "warp_ssh_user_inherit",
}
SSH_ONLY_PROTOCOL_ACTIONS = {
    "reset_password",
}
KEY_PENDING_FORM = "pending_form"
KEY_PENDING_CONFIRM = "pending_confirm"
KEY_PENDING_DELETE_PICK = "pending_delete_pick"
KEY_PENDING_QAC_PICK = "pending_qac_pick"
KEY_PENDING_ACCOUNT_PICK = "pending_account_pick"
KEY_PENDING_UPLOAD_RESTORE = "pending_upload_restore"
KEY_LAST_ACTION_TS = "last_action_ts"
KEY_LAST_CLEANUP_TS = "last_cleanup_ts"
KEY_QAC_SELECTIONS = "qac_selections"
KEY_MENU_PARENT_PAGES = "menu_parent_pages"
PENDING_STATE_KEYS = (
    KEY_PENDING_FORM,
    KEY_PENDING_CONFIRM,
    KEY_PENDING_DELETE_PICK,
    KEY_PENDING_QAC_PICK,
    KEY_PENDING_ACCOUNT_PICK,
    KEY_PENDING_UPLOAD_RESTORE,
)
PENDING_OTHER_CHAT_TEXT = "Sesi aktif ada di chat lain. Lanjutkan dari chat asal atau mulai ulang dengan /menu."
BOT_ROOT = Path(__file__).resolve().parents[2]
BOT_HOME = Path((os.getenv("BOT_HOME") or "").strip() or str(BOT_ROOT))
BOT_STATE_DIR = Path(os.getenv("BOT_STATE_DIR", "/var/lib/bot-telegram"))
UPLOAD_RESTORE_MAX_BYTES = 20 * 1024 * 1024
UPLOAD_RESTORE_DIRS = (
    BOT_STATE_DIR / "tmp" / "uploads",
    BOT_HOME / "runtime" / "tmp" / "uploads",
)
DOWNLOAD_LOCAL_ALLOW_DIRS = (
    BOT_STATE_DIR / "backups" / "archives",
    BOT_HOME / "runtime" / "backups" / "archives",
)


@dataclass
class Runtime:
    config: AppConfig
    catalog: CommandCatalog
    backend: BackendClient
    hostname: str
    main_menu_header: str = ""


def _get_runtime(context: ContextTypes.DEFAULT_TYPE) -> Runtime:
    runtime = context.application.bot_data.get("runtime")
    if not isinstance(runtime, Runtime):
        raise RuntimeError("Runtime belum terinisialisasi.")
    return runtime


def _main_menu_message(runtime: Runtime) -> str:
    return main_menu_text(
        runtime.hostname,
        len(_visible_main_menus(runtime)),
        runtime.main_menu_header,
    )


def _catalog_from_main_menu_payload(main_menu: dict) -> tuple[CommandCatalog, str]:
    menus = main_menu.get("menus") if isinstance(main_menu, dict) else None
    if not isinstance(menus, list):
        raise RuntimeError("payload menus tidak valid")
    catalog = CommandCatalog.from_payload({"menus": menus})
    header_text = str(main_menu.get("header_text") or "").strip() if isinstance(main_menu, dict) else ""
    return catalog, header_text


async def _refresh_main_menu_snapshot(runtime: Runtime, timeout: float = 5.0) -> None:
    main_menu = await runtime.backend.get_main_menu(timeout=timeout)
    catalog, header_text = _catalog_from_main_menu_payload(main_menu)
    runtime.catalog = catalog
    runtime.main_menu_header = header_text


def _update_log_context(update: object) -> str:
    if not isinstance(update, Update):
        return "update=none"

    parts: list[str] = []
    if update.update_id is not None:
        parts.append(f"update_id={update.update_id}")
    if update.effective_chat is not None and update.effective_chat.id is not None:
        parts.append(f"chat_id={update.effective_chat.id}")
    if update.effective_user is not None and update.effective_user.id is not None:
        parts.append(f"user_id={update.effective_user.id}")
    if update.callback_query is not None:
        parts.append("kind=callback")
    elif update.message is not None:
        parts.append("kind=message")
    else:
        parts.append("kind=unknown")
    return " ".join(parts) if parts else "update=unknown"


async def on_error(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    err = context.error
    err_type = err.__class__.__name__ if err is not None else "UnknownError"
    err_text = sanitize_secret_text(str(err) if err is not None else "unknown")
    update_ctx = _update_log_context(update)
    exc_info = (type(err), err, err.__traceback__) if err is not None else None

    if isinstance(err, NetworkError):
        LOGGER.warning("Transient Telegram network error (%s) %s: %s", err_type, update_ctx, err_text)
        return

    LOGGER.error("Unhandled bot error (%s) %s: %s", err_type, update_ctx, err_text, exc_info=exc_info)

    if not isinstance(update, Update):
        return

    chat = update.effective_chat
    if chat is None or chat.id is None:
        return

    try:
        if update.callback_query is not None:
            try:
                await update.callback_query.answer("Terjadi error sementara.", show_alert=True)
                return
            except Exception:
                pass
        await context.bot.send_message(
            chat_id=chat.id,
            text="Terjadi error sementara di bot. Coba ulangi action atau jalankan /menu.",
        )
    except Exception as notify_exc:
        LOGGER.warning(
            "Gagal mengirim notifikasi error ke chat %s: %s",
            chat.id,
            sanitize_secret_text(str(notify_exc)),
        )


def _is_authorized(runtime: Runtime, update: Update) -> tuple[bool, str]:
    if runtime.config.allow_unrestricted_access:
        return True, ""

    user_id = str(update.effective_user.id) if update.effective_user else ""
    chat_id = str(update.effective_chat.id) if update.effective_chat else ""

    if runtime.config.admin_user_ids and user_id not in runtime.config.admin_user_ids:
        return False, "Akses ditolak: user Telegram belum terdaftar sebagai admin."

    if runtime.config.admin_chat_ids and chat_id not in runtime.config.admin_chat_ids:
        return False, "Akses ditolak: chat ini belum diizinkan untuk menu bot."

    return True, ""


def _clear_pending(context: ContextTypes.DEFAULT_TYPE) -> None:
    pending_confirm = context.user_data.get(KEY_PENDING_CONFIRM)
    if isinstance(pending_confirm, dict):
        action_id = str(pending_confirm.get("action_id") or "").strip()
        params = pending_confirm.get("params") if isinstance(pending_confirm.get("params"), dict) else {}
        if action_id == "restore_from_upload" and isinstance(params, dict):
            cleanup_uploaded_archive(str(params.get("upload_path") or ""), UPLOAD_RESTORE_DIRS)
    clear_pending_states(
        context.user_data,
        (
            KEY_PENDING_FORM,
            KEY_PENDING_CONFIRM,
            KEY_PENDING_DELETE_PICK,
            KEY_PENDING_ACCOUNT_PICK,
            KEY_PENDING_UPLOAD_RESTORE,
        ),
    )


def _chat_scope_id(chat_id: int | str | None) -> str:
    return chat_scope_id(chat_id)


def _store_pending_state(
    context: ContextTypes.DEFAULT_TYPE,
    key: str,
    pending: dict,
    chat_id: int | str | None,
) -> dict:
    return session_store_pending_state(context.user_data, key, pending, chat_id)


def _get_pending_state(
    context: ContextTypes.DEFAULT_TYPE,
    key: str,
    chat_id: int | str | None,
) -> tuple[dict | None, str]:
    return session_get_pending_state(
        context.user_data,
        key,
        chat_id,
        other_chat_text=PENDING_OTHER_CHAT_TEXT,
    )


def _set_menu_parent_page(
    context: ContextTypes.DEFAULT_TYPE,
    menu_id: str,
    *,
    chat_id: int | str | None,
    parent_page: int,
) -> None:
    session_set_menu_parent_page(
        context.user_data,
        KEY_MENU_PARENT_PAGES,
        menu_id,
        chat_id=chat_id,
        parent_page=parent_page,
    )


def _get_menu_parent_page(
    context: ContextTypes.DEFAULT_TYPE,
    menu_id: str,
    *,
    chat_id: int | str | None,
) -> int:
    return session_get_menu_parent_page(
        context.user_data,
        KEY_MENU_PARENT_PAGES,
        menu_id,
        chat_id=chat_id,
        safe_int=_safe_int,
    )


def _has_pending_state_in_other_chat(context: ContextTypes.DEFAULT_TYPE, chat_id: int | str | None) -> bool:
    return session_has_pending_state_in_other_chat(context.user_data, PENDING_STATE_KEYS, chat_id)


def _cooldown_remaining(
    context: ContextTypes.DEFAULT_TYPE,
    *,
    user_id: str,
    key: str,
    min_interval_sec: float,
) -> float:
    if min_interval_sec <= 0:
        return 0.0

    now = time.monotonic()
    scope = context.application.bot_data.setdefault("_cooldowns", {})
    user_scope = scope.setdefault(user_id, {})
    try:
        prev = float(user_scope.get(key, 0.0))
    except Exception:
        prev = 0.0

    elapsed = now - prev
    if elapsed < min_interval_sec:
        return min_interval_sec - elapsed

    user_scope[key] = now
    return 0.0


def _throttle_message(seconds_left: float) -> str:
    if seconds_left <= 1:
        return "Terlalu cepat. Coba lagi dalam ~1 detik."
    return f"Terlalu cepat. Coba lagi dalam ~{int(seconds_left + 0.99)} detik."


def _short_button_label(text: str, max_len: int = BUTTON_LABEL_MAX) -> str:
    return ui_short_button_label(text, max_len)


def _rows_from_buttons(buttons: list[InlineKeyboardButton], per_row: int = BUTTONS_PER_ROW) -> list[list[InlineKeyboardButton]]:
    return ui_rows_from_buttons(buttons, per_row)


def _action_visible(runtime: Runtime, action: ActionSpec) -> bool:
    return ui_action_visible(runtime, action)


def _visible_actions(runtime: Runtime, menu: MenuSpec) -> list[ActionSpec]:
    return ui_visible_actions(runtime, menu)


def _visible_main_menus(runtime: Runtime) -> list[MenuSpec]:
    return ui_visible_main_menus(runtime)


def _callback_chat_id(update: Update) -> int:
    query = update.callback_query
    if query is not None and query.message is not None:
        return query.message.chat.id
    if update.effective_chat is not None:
        return update.effective_chat.id
    raise RuntimeError("Chat ID callback tidak tersedia.")


def _main_menu_keyboard(runtime: Runtime) -> InlineKeyboardMarkup:
    return ui_main_menu_keyboard(
        runtime,
        callback_sep=CALLBACK_SEP,
        buttons_per_row=BUTTONS_PER_ROW,
        button_label_max=BUTTON_LABEL_MAX,
    )


def _menu_pages(runtime: Runtime, menu: MenuSpec) -> int:
    return ui_menu_pages(runtime, menu, actions_per_page=ACTIONS_PER_PAGE)


def _menu_keyboard(runtime: Runtime, menu: MenuSpec, page: int, *, parent_page: int = 0) -> InlineKeyboardMarkup:
    return ui_menu_keyboard(
        runtime,
        menu,
        page,
        parent_page=parent_page,
        actions_per_page=ACTIONS_PER_PAGE,
        buttons_per_row=BUTTONS_PER_ROW,
        button_label_max=BUTTON_LABEL_MAX,
        callback_sep=CALLBACK_SEP,
    )


def _result_keyboard(menu_id: str, page: int = 0) -> InlineKeyboardMarkup:
    return ui_result_keyboard(menu_id, page, callback_sep=CALLBACK_SEP, qac_menu_ids=QAC_MENU_IDS)


def _confirm_keyboard(menu_id: str, page: int = 0) -> InlineKeyboardMarkup:
    return ui_confirm_keyboard(menu_id, page, callback_sep=CALLBACK_SEP)


def _safe_int(raw: str, default: int = 0) -> int:
    try:
        return int(raw)
    except Exception:
        return default


def _menu_protocol_scope(menu_id: str) -> tuple[str, ...]:
    if menu_id in {XRAY_USER_MENU_ID, XRAY_QAC_MENU_ID}:
        return XRAY_PROTOCOLS
    if menu_id in {SSH_USER_MENU_ID, SSH_QAC_MENU_ID} | SSH_NETWORK_MENU_IDS:
        return ("ssh",)
    return USER_PROTOCOLS


def _qac_picker_title(menu_id: str) -> str:
    return qac_ui_picker_title(
        menu_id,
        xray_qac_menu_id=XRAY_QAC_MENU_ID,
        ssh_qac_menu_id=SSH_QAC_MENU_ID,
    )


def _set_qac_selection(
    context: ContextTypes.DEFAULT_TYPE,
    menu_id: str,
    *,
    chat_id: int | str | None,
    proto: str,
    username: str,
) -> None:
    session_set_qac_selection(
        context.user_data,
        KEY_QAC_SELECTIONS,
        menu_id,
        chat_id=chat_id,
        proto=proto,
        username=username,
    )


def _clear_qac_selection(context: ContextTypes.DEFAULT_TYPE, menu_id: str) -> None:
    session_clear_qac_selection(context.user_data, KEY_QAC_SELECTIONS, menu_id)


def _get_qac_selection(
    context: ContextTypes.DEFAULT_TYPE,
    menu_id: str,
    *,
    chat_id: int | str | None,
) -> dict | None:
    return session_get_qac_selection(
        context.user_data,
        KEY_QAC_SELECTIONS,
        menu_id,
        chat_id=chat_id,
        allowed_protocols=_menu_protocol_scope(menu_id),
    )


def _qac_selection_params(menu_id: str, selection: dict | None) -> dict[str, str]:
    return qac_ui_selection_params(
        menu_id,
        selection,
        xray_qac_menu_id=XRAY_QAC_MENU_ID,
    )


def _qac_selection_label(menu_id: str, selection: dict | None) -> str:
    return qac_ui_selection_label(
        menu_id,
        selection,
        xray_qac_menu_id=XRAY_QAC_MENU_ID,
    )


def _qac_picker_entry_label(menu_id: str, proto: str, username: str) -> str:
    if menu_id == XRAY_QAC_MENU_ID:
        return f"{username}@{proto}"
    return username


def _qac_menu_text(menu: MenuSpec, selection: dict, summary: dict[str, str] | None, page: int, total_pages: int) -> str:
    return qac_ui_menu_text(
        menu,
        selection,
        summary,
        page,
        total_pages,
        xray_qac_menu_id=XRAY_QAC_MENU_ID,
        ssh_qac_menu_id=SSH_QAC_MENU_ID,
    )


def _qac_menu_keyboard(runtime: Runtime, menu: MenuSpec, page: int, *, parent_page: int = 0) -> InlineKeyboardMarkup:
    return qac_ui_menu_keyboard(
        menu,
        page,
        callback_sep=CALLBACK_SEP,
        base_markup=_menu_keyboard(runtime, menu, page, parent_page=parent_page),
    )


def _qac_pick_keyboard(menu_id: str, page: int, users: list[dict[str, str]], menu_page: int) -> InlineKeyboardMarkup:
    return qac_ui_pick_keyboard(
        menu_id,
        page,
        users,
        menu_page,
        callback_sep=CALLBACK_SEP,
        delete_pick_page_size=DELETE_PICK_PAGE_SIZE,
        short_button_label=_short_button_label,
        rows_from_buttons=_rows_from_buttons,
        xray_qac_menu_id=XRAY_QAC_MENU_ID,
    )


def _qac_pick_text(menu_id: str, page: int, users: list[dict[str, str]]) -> str:
    return qac_ui_pick_text(
        menu_id,
        page,
        users,
        delete_pick_page_size=DELETE_PICK_PAGE_SIZE,
        xray_qac_menu_id=XRAY_QAC_MENU_ID,
        ssh_qac_menu_id=SSH_QAC_MENU_ID,
    )


async def _load_qac_user_entries(runtime: Runtime, menu_id: str) -> list[dict[str, str]]:
    return await load_menu_user_entries(runtime.backend, protocols=_menu_protocol_scope(menu_id))


def _delete_picker_title(menu_id: str) -> str:
    return picker_delete_picker_title(
        menu_id,
        xray_user_menu_id=XRAY_USER_MENU_ID,
        ssh_user_menu_id=SSH_USER_MENU_ID,
    )


def _account_picker_title(menu_id: str) -> str:
    return picker_account_picker_title(
        menu_id,
        xray_user_menu_id=XRAY_USER_MENU_ID,
        ssh_user_menu_id=SSH_USER_MENU_ID,
    )


def _account_picker_entry_label(menu_id: str, proto: str, username: str) -> str:
    if menu_id == XRAY_USER_MENU_ID:
        return f"{username}@{proto}"
    return username


def _account_picker_return_keyboard(menu_id: str, menu_page: int) -> InlineKeyboardMarkup:
    return picker_account_picker_return_keyboard(
        menu_id,
        menu_page,
        callback_sep=CALLBACK_SEP,
    )


def _account_pick_keyboard(menu_id: str, page: int, users: list[dict[str, str]], menu_page: int) -> InlineKeyboardMarkup:
    return picker_account_pick_keyboard(
        menu_id,
        page,
        users,
        menu_page,
        callback_sep=CALLBACK_SEP,
        delete_pick_page_size=DELETE_PICK_PAGE_SIZE,
        short_button_label=_short_button_label,
        rows_from_buttons=_rows_from_buttons,
        xray_user_menu_id=XRAY_USER_MENU_ID,
    )


def _account_pick_text(menu_id: str, action_label: str, page: int, users: list[dict[str, str]]) -> str:
    return picker_account_pick_text(
        menu_id,
        action_label,
        page,
        users,
        delete_pick_page_size=DELETE_PICK_PAGE_SIZE,
        xray_user_menu_id=XRAY_USER_MENU_ID,
        ssh_user_menu_id=SSH_USER_MENU_ID,
    )


async def _load_account_user_entries(runtime: Runtime, menu_id: str) -> list[dict[str, str]]:
    return await load_menu_user_entries(runtime.backend, protocols=_menu_protocol_scope(menu_id))


async def _show_account_user_picker(
    *,
    runtime: Runtime,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    query,
    menu_id: str,
    action_id: str,
    page: int = 0,
    menu_page: int = 0,
) -> None:
    menu = runtime.catalog.get_menu(menu_id)
    action = runtime.catalog.get_action(menu_id, action_id)
    if menu is None or action is None:
        await query.answer("Action tidak ditemukan.", show_alert=True)
        return

    try:
        users = await _load_account_user_entries(runtime, menu_id)
    except BackendError as exc:
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=(
                "<b>❌ Gagal Ambil Daftar User</b>\n"
                f"<pre>{html.escape(str(exc)[:1200])}</pre>"
            ),
            reply_markup=_account_picker_return_keyboard(menu_id, menu_page),
        )
        return

    if not users:
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=(
                f"<b>{html.escape(_account_picker_title(menu_id))} · {html.escape(action.label)}</b>\n"
                "Belum ada user untuk dipilih."
            ),
            reply_markup=_account_picker_return_keyboard(menu_id, menu_page),
        )
        return

    page_max = ((len(users) - 1) // DELETE_PICK_PAGE_SIZE)
    page = max(0, min(page, page_max))
    _store_pending_state(
        context,
        KEY_PENDING_ACCOUNT_PICK,
        {
            "menu_id": menu_id,
            "action_id": action_id,
            "users": users,
            "page": page,
            "menu_page": max(0, menu_page),
        },
        chat_id,
    )
    await _send_or_edit(
        query=query,
        chat_id=chat_id,
        context=context,
        text=_account_pick_text(menu_id, action.label, page, users),
        reply_markup=_account_pick_keyboard(menu_id, page, users, menu_page),
    )


def _delete_pick_proto_keyboard(menu_id: str, menu_page: int) -> InlineKeyboardMarkup:
    return picker_delete_pick_proto_keyboard(
        menu_id,
        menu_page,
        callback_sep=CALLBACK_SEP,
        protocols=_menu_protocol_scope(menu_id),
        rows_from_buttons=_rows_from_buttons,
    )


def _delete_pick_return_keyboard(menu_id: str, menu_page: int) -> InlineKeyboardMarkup:
    return picker_delete_pick_return_keyboard(
        menu_id,
        menu_page,
        callback_sep=CALLBACK_SEP,
        protocols=_menu_protocol_scope(menu_id),
    )


def _protocol_choices_for_action(menu_id: str, action_id: str) -> tuple[str, ...]:
    return picker_protocol_choices_for_action(
        menu_id,
        action_id,
        scoped=_menu_protocol_scope(menu_id),
        user_protocols=USER_PROTOCOLS,
        ssh_only_protocol_actions=SSH_ONLY_PROTOCOL_ACTIONS,
        xray_protocols=XRAY_PROTOCOLS,
    )


def _delete_pick_users_keyboard(menu_id: str, page: int, users: list[str], menu_page: int) -> InlineKeyboardMarkup:
    return picker_delete_pick_users_keyboard(
        menu_id,
        page,
        users,
        menu_page,
        callback_sep=CALLBACK_SEP,
        delete_pick_page_size=DELETE_PICK_PAGE_SIZE,
        short_button_label=_short_button_label,
        rows_from_buttons=_rows_from_buttons,
        return_keyboard=_delete_pick_return_keyboard(menu_id, menu_page),
    )


def _delete_pick_text_proto(menu_id: str) -> str:
    return picker_delete_pick_text_proto(
        menu_id,
        xray_user_menu_id=XRAY_USER_MENU_ID,
        ssh_user_menu_id=SSH_USER_MENU_ID,
    )


def _delete_pick_text_users(menu_id: str, proto: str, page: int, users: list[str]) -> str:
    return picker_delete_pick_text_users(
        menu_id,
        proto,
        page,
        users,
        delete_pick_page_size=DELETE_PICK_PAGE_SIZE,
        xray_user_menu_id=XRAY_USER_MENU_ID,
        ssh_user_menu_id=SSH_USER_MENU_ID,
    )


async def _show_delete_user_proto_picker(
    *,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    query,
    menu_id: str,
    menu_page: int = 0,
) -> None:
    context.user_data.pop(KEY_PENDING_DELETE_PICK, None)
    protocols = _menu_protocol_scope(menu_id)
    if len(protocols) == 1:
        await _show_delete_user_list_picker(
            runtime=_get_runtime(context),
            context=context,
            chat_id=chat_id,
            query=query,
            menu_id=menu_id,
            proto=protocols[0],
            page=0,
            menu_page=menu_page,
        )
        return
    await _send_or_edit(
        query=query,
        chat_id=chat_id,
        context=context,
        text=_delete_pick_text_proto(menu_id),
        reply_markup=_delete_pick_proto_keyboard(menu_id, menu_page),
    )


async def _show_delete_user_list_picker(
    *,
    runtime: Runtime,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    query,
    menu_id: str,
    proto: str,
    page: int = 0,
    menu_page: int = 0,
) -> None:
    try:
        options: list[BackendUserOption] = await runtime.backend.list_user_options(proto=proto)
    except BackendError as exc:
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=(
                "<b>❌ Gagal Ambil Daftar User</b>\n"
                f"<pre>{html.escape(str(exc)[:1200])}</pre>"
            ),
            reply_markup=_delete_pick_return_keyboard(menu_id, menu_page),
        )
        return

    usernames = list(dict.fromkeys([o.username for o in options if o.proto == proto]))
    if not usernames:
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=(
                f"<b>{html.escape(_delete_picker_title(menu_id))} · Delete User</b>\n"
                f"Protocol <code>{html.escape(proto.upper())}</code> belum punya user."
            ),
            reply_markup=_delete_pick_return_keyboard(menu_id, menu_page),
        )
        return

    page_max = ((len(usernames) - 1) // DELETE_PICK_PAGE_SIZE)
    page = max(0, min(page, page_max))
    _store_pending_state(
        context,
        KEY_PENDING_DELETE_PICK,
        {
            "menu_id": menu_id,
            "proto": proto,
            "users": usernames,
            "page": page,
            "menu_page": max(0, menu_page),
        },
        chat_id,
    )
    await _send_or_edit(
        query=query,
        chat_id=chat_id,
        context=context,
        text=_delete_pick_text_users(menu_id, proto, page, usernames),
        reply_markup=_delete_pick_users_keyboard(menu_id, page, usernames, menu_page),
    )


async def _render_qac_menu(
    *,
    runtime: Runtime,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    query,
    menu: MenuSpec,
    page: int = 0,
) -> None:
    selection = _get_qac_selection(context, menu.id, chat_id=chat_id)
    if selection is None:
        await _show_qac_user_picker(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            query=query,
            menu_id=menu.id,
            menu_page=page,
        )
        return
    try:
        users = await _load_qac_user_entries(runtime, menu.id)
    except BackendError as exc:
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=(
                f"<b>{html.escape(_qac_picker_title(menu.id))}</b>\n"
                "Gagal memvalidasi user aktif.\n\n"
                f"<pre>{html.escape(str(exc)[:1200])}</pre>"
            ),
            reply_markup=InlineKeyboardMarkup(
                [[InlineKeyboardButton("⬅️ Kembali", callback_data=f"m{CALLBACK_SEP}{menu.id}{CALLBACK_SEP}{max(page, 0)}")]]
            ),
        )
        return

    if not any(
        str(item.get("proto") or "").strip().lower() == str(selection.get("proto") or "").strip().lower()
        and str(item.get("username") or "").strip() == str(selection.get("username") or "").strip()
        for item in users
    ):
        _clear_qac_selection(context, menu.id)
        await _show_qac_user_picker(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            query=query,
            menu_id=menu.id,
            menu_page=page,
        )
        return
    summary: dict[str, str] | None = None
    try:
        summary = await runtime.backend.get_qac_user_summary(
            str(selection.get("proto") or ""),
            str(selection.get("username") or ""),
        )
    except BackendError:
        summary = None
    total_pages = _menu_pages(runtime, menu)
    page = max(0, min(page, total_pages - 1))
    await _send_or_edit(
        query=query,
        chat_id=chat_id,
        context=context,
        text=_qac_menu_text(menu, selection, summary, page, total_pages),
        reply_markup=_qac_menu_keyboard(runtime, menu, page),
    )


async def _show_qac_user_picker(
    *,
    runtime: Runtime,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    query,
    menu_id: str,
    page: int = 0,
    menu_page: int = 0,
) -> None:
    try:
        users = await _load_qac_user_entries(runtime, menu_id)
    except BackendError as exc:
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=(
                f"<b>{html.escape(_qac_picker_title(menu_id))}</b>\n"
                "Gagal mengambil daftar user.\n\n"
                f"<pre>{html.escape(str(exc)[:1200])}</pre>"
            ),
            reply_markup=InlineKeyboardMarkup(
                [[InlineKeyboardButton("⬅️ Kembali", callback_data=f"m{CALLBACK_SEP}{menu_id}{CALLBACK_SEP}{max(menu_page, 0)}")]]
            ),
        )
        return

    context.user_data.pop(KEY_PENDING_QAC_PICK, None)
    if not users:
        _clear_qac_selection(context, menu_id)
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=(
                f"<b>{html.escape(_qac_picker_title(menu_id))}</b>\n"
                "Belum ada user yang bisa dipilih."
            ),
            reply_markup=InlineKeyboardMarkup(
                [[InlineKeyboardButton("⬅️ Kembali", callback_data=f"m{CALLBACK_SEP}{menu_id}{CALLBACK_SEP}{max(menu_page, 0)}")]]
            ),
        )
        return

    page_max = ((len(users) - 1) // DELETE_PICK_PAGE_SIZE)
    page = max(0, min(page, page_max))
    _store_pending_state(
        context,
        KEY_PENDING_QAC_PICK,
        {
            "menu_id": menu_id,
            "users": users,
            "page": page,
            "menu_page": max(0, menu_page),
        },
        chat_id,
    )
    await _send_or_edit(
        query=query,
        chat_id=chat_id,
        context=context,
        text=_qac_pick_text(menu_id, page, users),
        reply_markup=_qac_pick_keyboard(menu_id, page, users, menu_page),
    )


def _serialize_choice_options(options: list[tuple[str, str]]) -> list[dict[str, str]]:
    return [{"label": str(label), "value": str(value)} for label, value in options]


def _is_truthy(raw: str) -> bool:
    val = str(raw or "").strip().lower()
    return val in {"1", "true", "on", "yes", "y", "enable", "enabled"}


def _field_is_required(pending: dict, field: ActionSpec) -> bool:
    if field.required:
        return True

    # Add User: saat speed limit ON, nilai down/up wajib diisi.
    if field.id in {"speed_down_mbit", "speed_up_mbit"}:
        params = pending.get("params") if isinstance(pending.get("params"), dict) else {}
        return _is_truthy(str(params.get("speed_limit_enabled") or ""))

    return False


def _pending_choice_options(pending: dict) -> list[dict[str, str]]:
    raw = pending.get("choice_options")
    if not isinstance(raw, list):
        return []
    out: list[dict[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        label = str(item.get("label") or "").strip()
        value = str(item.get("value") or "").strip()
        if not label and not value:
            continue
        out.append({"label": label or value, "value": value or label})
    return out


def _pending_prefilled_fields(pending: dict) -> set[str]:
    raw = pending.get("prefilled_fields")
    if not isinstance(raw, (list, tuple, set)):
        return set()
    return {str(item).strip() for item in raw if str(item).strip()}


def _display_form_field_indices(action: ActionSpec, pending: dict) -> list[int]:
    prefilled = _pending_prefilled_fields(pending)
    params = pending.get("params") if isinstance(pending.get("params"), dict) else {}
    speed_limit_value = str(params.get("speed_limit_enabled") or "").strip()
    hide_speed_fields = bool(speed_limit_value) and not _is_truthy(speed_limit_value)

    indices: list[int] = []
    for idx, field in enumerate(action.modal.fields):
        if field.id in prefilled:
            continue
        if hide_speed_fields and field.id in {"speed_down_mbit", "speed_up_mbit"}:
            continue
        indices.append(idx)
    return indices


def _display_form_progress(action: ActionSpec, pending: dict, current_idx: int) -> tuple[int, int]:
    indices = _display_form_field_indices(action, pending)
    if not indices:
        return 1, 1
    total = len(indices)
    if current_idx in indices:
        return indices.index(current_idx) + 1, total
    completed = sum(1 for idx in indices if idx <= current_idx)
    return max(1, min(completed, total)), total


def _is_click_only_field(action_id: str, field_id: str) -> bool:
    return action_id == "setup_domain_cloudflare" and field_id == "root_domain"


def _choice_total_pages(choice_options: list[dict[str, str]]) -> int:
    if not choice_options:
        return 1
    return ((len(choice_options) - 1) // FORM_CHOICE_PAGE_SIZE) + 1


def _choice_keyboard(menu_id: str, choice_options: list[dict[str, str]], page: int, *, menu_page: int = 0) -> InlineKeyboardMarkup:
    rows: list[list[InlineKeyboardButton]] = []
    if choice_options:
        start = page * FORM_CHOICE_PAGE_SIZE
        chunk = choice_options[start : start + FORM_CHOICE_PAGE_SIZE]
        option_buttons: list[InlineKeyboardButton] = []
        for idx, item in enumerate(chunk, start=start):
            option_buttons.append(
                InlineKeyboardButton(
                    _short_button_label(str(item.get("label") or str(item.get("value") or "")), max_len=22),
                    callback_data=f"pfc{CALLBACK_SEP}{idx}",
                )
            )
        rows.extend(_rows_from_buttons(option_buttons))

    total_pages = _choice_total_pages(choice_options)
    if total_pages > 1:
        nav: list[InlineKeyboardButton] = []
        if page > 0:
            nav.append(InlineKeyboardButton("◀️ Prev", callback_data=f"pfp{CALLBACK_SEP}{page - 1}"))
        nav.append(InlineKeyboardButton(f"{page + 1}/{total_pages}", callback_data="noop"))
        if page + 1 < total_pages:
            nav.append(InlineKeyboardButton("Next ▶️", callback_data=f"pfp{CALLBACK_SEP}{page + 1}"))
        rows.append(nav)

    rows.append([InlineKeyboardButton("❌ Batal", callback_data=f"cf{CALLBACK_SEP}{menu_id}{CALLBACK_SEP}{max(menu_page, 0)}")])
    return InlineKeyboardMarkup(rows)


async def _resolve_form_choice_options(runtime: Runtime, pending: dict, field_id: str) -> list[tuple[str, str]]:
    menu_id = str(pending.get("menu_id") or "").strip()
    action_id = str(pending.get("action_id") or "").strip()
    params = pending.get("params") if isinstance(pending.get("params"), dict) else {}

    if field_id == "proto":
        return [(proto.upper(), proto) for proto in _protocol_choices_for_action(menu_id, action_id)]

    if field_id == "enabled":
        if action_id == "manual_block":
            return [("BLOCK", "on"), ("UNBLOCK", "off")]
        if action_id in {"ip_limit_enable", "speed_limit"}:
            return [("ENABLE", "on"), ("DISABLE", "off")]

    if field_id in {"enabled", "proxied", "allow_existing_same_ip", "speed_limit_enabled"}:
        return [("ON", "on"), ("OFF", "off")]

    if field_id == "mode":
        if action_id == "extend_expiry":
            return [("Extend (+hari)", "extend"), ("Set Tanggal", "set")]
        if action_id == "set_warp_global_mode":
            return [("Direct", "direct"), ("Warp", "warp")]
        if action_id in {"set_warp_user_mode", "set_warp_inbound_mode", "set_warp_domain_mode"}:
            return [("Direct", "direct"), ("Warp", "warp"), ("Off (inherit)", "off")]

    if field_id == "strategy":
        if action_id == "set_dns_query_strategy":
            return [
                ("UseIP", "UseIP"),
                ("UseIPv4", "UseIPv4"),
                ("UseIPv6", "UseIPv6"),
                ("PreferIPv4", "PreferIPv4"),
                ("PreferIPv6", "PreferIPv6"),
            ]

    if field_id == "subdomain_mode":
        return [("AUTO", "auto"), ("MANUAL", "manual")]

    if field_id == "root_domain" and action_id == "setup_domain_cloudflare":
        try:
            options: list[BackendRootDomainOption] = await runtime.backend.list_domain_root_options()
            roots = list(dict.fromkeys([o.root_domain for o in options if o.root_domain]))
        except BackendError:
            roots = []

        if not roots:
            roots = list(ROOT_DOMAIN_FALLBACK_OPTIONS)
        return [(root, root) for root in roots]

    if field_id == "days":
        return [("7", "7"), ("30", "30"), ("60", "60"), ("90", "90")]

    if field_id == "quota_gb":
        return [("10", "10"), ("50", "50"), ("100", "100"), ("200", "200")]

    if field_id == "ip_limit":
        return [("OFF (0)", "0"), ("1", "1"), ("2", "2"), ("3", "3")]

    if field_id == "speed_down_mbit":
        return [("10", "10"), ("20", "20"), ("50", "50"), ("100", "100")]

    if field_id == "speed_up_mbit":
        return [("5", "5"), ("10", "10"), ("20", "20"), ("50", "50")]

    if field_id == "limit":
        return [("10", "10"), ("15", "15"), ("25", "25"), ("50", "50"), ("100", "100")]

    if field_id == "username" and action_id in FORM_CHOICE_USERNAME_ACTIONS:
        proto = str(params.get("proto") or "").strip().lower()
        if not proto:
            scoped_protocols = _menu_protocol_scope(menu_id)
            if len(scoped_protocols) == 1:
                proto = scoped_protocols[0]
        if proto not in _protocol_choices_for_action(menu_id, action_id):
            return []
        try:
            options: list[BackendUserOption] = await runtime.backend.list_user_options(proto=proto)
        except BackendError:
            return []
        usernames = list(dict.fromkeys([o.username for o in options if o.proto == proto and o.username]))
        return [(u, u) for u in usernames]

    if field_id == "inbound_tag" and action_id == "set_warp_inbound_mode":
        try:
            options: list[BackendInboundOption] = await runtime.backend.list_inbound_options()
        except BackendError:
            return []
        tags = list(dict.fromkeys([o.tag for o in options if o.tag]))
        return [(tag, tag) for tag in tags]

    if field_id == "entry" and action_id == "set_warp_domain_mode":
        mode = str(params.get("mode") or "").strip().lower()
        mode_q = mode if mode in {"direct", "warp"} else None
        try:
            options: list[BackendDomainOption] = await runtime.backend.list_warp_domain_options(mode=mode_q)
        except BackendError:
            return []
        entries = list(dict.fromkeys([o.entry for o in options if o.entry]))
        return [(ent, ent) for ent in entries]

    if field_id == "domain" and action_id == "delete_adblock_domain":
        try:
            options = await runtime.backend.list_adblock_manual_options()
        except BackendError:
            return []
        entries = list(dict.fromkeys([o.entry for o in options if o.entry]))
        return [(ent, ent) for ent in entries]

    if field_id == "url" and action_id == "delete_adblock_url_source":
        try:
            options = await runtime.backend.list_adblock_url_options()
        except BackendError:
            return []
        entries = list(dict.fromkeys([o.entry for o in options if o.entry]))
        return [(ent, ent) for ent in entries]

    return []


async def _render_pending_choice_prompt(
    *,
    runtime: Runtime,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    pending: dict,
    query=None,
) -> None:
    menu = runtime.catalog.get_menu(str(pending.get("menu_id", "")))
    action = runtime.catalog.get_action(str(pending.get("menu_id", "")), str(pending.get("action_id", "")))
    if menu is None or action is None or action.modal is None:
        raise RuntimeError("State pilihan input tidak valid.")

    idx = int(pending.get("index", 0))
    if idx < 0 or idx >= len(action.modal.fields):
        raise RuntimeError("Index pilihan input tidak valid.")
    field = action.modal.fields[idx]
    step_no, total_steps = _display_form_progress(action, pending, idx)

    choice_options = _pending_choice_options(pending)
    page_max = _choice_total_pages(choice_options) - 1
    page = max(0, min(int(pending.get("choice_page", 0)), page_max))
    pending["choice_page"] = page
    _store_pending_state(context, KEY_PENDING_FORM, pending, chat_id)

    await _send_or_edit(
        query=query,
        chat_id=chat_id,
        context=context,
        text=(
            f"{action_form_prompt(menu, action, field, step_no, total_steps, params=pending.get('params'))}\n\n"
            "Pilih nilainya lewat tombol."
        ),
        reply_markup=_choice_keyboard(menu.id, choice_options, page, menu_page=_safe_int(str(pending.get("page") or "0"), default=0)),
    )


def _manual_input_prompt(menu: MenuSpec, action: ActionSpec, field, idx: int, total: int, *, params: dict | None = None) -> str:
    return (
        f"{action_form_prompt(menu, action, field, idx, total, params=params)}\n\n"
        "Mode input manual aktif. Ketik nilainya sekarang."
    )


async def _send_or_edit(
    *,
    query,
    chat_id: int,
    context: ContextTypes.DEFAULT_TYPE,
    text: str,
    reply_markup: InlineKeyboardMarkup | None = None,
) -> None:
    if query is not None:
        try:
            await query.edit_message_text(text=text, reply_markup=reply_markup, parse_mode=ParseMode.HTML)
            return
        except BadRequest as exc:
            # Hindari duplikasi pesan saat payload tidak berubah.
            if "message is not modified" in str(exc).lower():
                return
            LOGGER.debug("Edit message gagal, fallback kirim pesan baru: %s", exc)
        except Exception as exc:
            LOGGER.debug("Edit message exception, fallback kirim pesan baru: %s", exc)

    await context.bot.send_message(
        chat_id=chat_id,
        text=text,
        parse_mode=ParseMode.HTML,
        reply_markup=reply_markup,
    )


async def _run_action(
    *,
    runtime: Runtime,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    menu_id: str,
    action_id: str,
    params: dict[str, str],
    page: int,
    query,
) -> None:
    try:
        result = await runtime.backend.run_action(menu_id=menu_id, action=action_id, params=params)
    except BackendError as exc:
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=(
                "<b>❌ Backend Error</b>\n"
                "Tidak bisa menjalankan action.\n\n"
                f"<pre>{str(exc)[:1800]}</pre>"
            ),
            reply_markup=_result_keyboard(menu_id, page),
        )
        return

    await _send_or_edit(
        query=query,
        chat_id=chat_id,
        context=context,
        text=action_result_text(result),
        reply_markup=_result_keyboard(menu_id, page),
    )

    local_attachment = resolve_local_download(result.data, allow_dirs=DOWNLOAD_LOCAL_ALLOW_DIRS)
    if local_attachment is not None:
        filename, local_path = local_attachment
        try:
            with local_path.open("rb") as fp:
                await context.bot.send_document(
                    chat_id=chat_id,
                    document=fp,
                    filename=filename,
                    caption=f"File hasil: {filename}",
                )
        except Exception as exc:
            LOGGER.warning("Gagal kirim lampiran lokal %s: %s", local_path, exc)
        return

    attachment = decode_download_payload(result.data)
    if attachment is None:
        return

    filename, payload = attachment
    if not payload:
        return
    allow_password = bool(result.data.get("allow_sensitive_output")) if isinstance(result.data, dict) else False
    filename, payload = sanitize_download_attachment(filename, payload, allow_password=allow_password)

    bio = io.BytesIO(payload)
    bio.name = filename
    try:
        await context.bot.send_document(
            chat_id=chat_id,
            document=bio,
            filename=filename,
            caption=f"File hasil: {filename}",
        )
    except Exception as exc:
        LOGGER.warning("Gagal kirim lampiran %s: %s", filename, exc)


def _prefilled_action_params(
    context: ContextTypes.DEFAULT_TYPE,
    *,
    menu_id: str,
    action_id: str,
    chat_id: int,
) -> dict[str, str]:
    if menu_id not in QAC_MENU_IDS or action_id == "summary":
        return {}
    return _qac_selection_params(menu_id, _get_qac_selection(context, menu_id, chat_id=chat_id))


async def _start_action_flow(
    *,
    runtime: Runtime,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    user_id: str,
    query,
    menu: MenuSpec,
    action: ActionSpec,
    initial_params: dict[str, str],
    page: int = 0,
) -> None:
    if action.mode == "modal" and action.modal and len(action.modal.fields) > 0:
        initial_index = 0
        while initial_index < len(action.modal.fields) and action.modal.fields[initial_index].id in initial_params:
            initial_index += 1
        if initial_index >= len(action.modal.fields):
            params = dict(initial_params)
            if action.confirm:
                _store_pending_state(
                    context,
                    KEY_PENDING_CONFIRM,
                    {
                        "menu_id": menu.id,
                        "action_id": action.id,
                        "params": params,
                        "page": page,
                    },
                    chat_id,
                )
                await _send_or_edit(
                    query=query,
                    chat_id=chat_id,
                    context=context,
                    text=confirm_text(menu, action, params),
                    reply_markup=_confirm_keyboard(menu.id, page),
                )
                return

            wait = _cooldown_remaining(
                context,
                user_id=user_id,
                key=KEY_LAST_ACTION_TS,
                min_interval_sec=runtime.config.action_cooldown_seconds,
            )
            if wait > 0:
                await query.answer(_throttle_message(wait), show_alert=True)
                return

            await _send_or_edit(
                query=query,
                chat_id=chat_id,
                context=context,
                text="<b>⏳ Menjalankan action...</b>",
                reply_markup=_result_keyboard(menu.id, page),
            )
            await _run_action(
                runtime=runtime,
                context=context,
                chat_id=chat_id,
                menu_id=menu.id,
                action_id=action.id,
                params=params,
                page=page,
                query=query,
            )
            return

        pending_form = _store_pending_state(
            context,
            KEY_PENDING_FORM,
            {
                "menu_id": menu.id,
                "action_id": action.id,
                "index": initial_index,
                "params": dict(initial_params),
                "page": page,
                "prefilled_fields": [
                    field.id
                    for field in action.modal.fields
                    if field.id in initial_params
                ],
            },
            chat_id,
        )
        await _prompt_next_form_field(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            pending=pending_form,
            query=query,
        )
        return

    params = dict(initial_params)
    if action.confirm:
        _store_pending_state(
            context,
            KEY_PENDING_CONFIRM,
            {
                "menu_id": menu.id,
                "action_id": action.id,
                "params": params,
                "page": page,
            },
            chat_id,
        )
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=confirm_text(menu, action, params),
            reply_markup=_confirm_keyboard(menu.id, page),
        )
        return

    wait = _cooldown_remaining(
        context,
        user_id=user_id,
        key=KEY_LAST_ACTION_TS,
        min_interval_sec=runtime.config.action_cooldown_seconds,
    )
    if wait > 0:
        await query.answer(_throttle_message(wait), show_alert=True)
        return

    await _send_or_edit(
        query=query,
        chat_id=chat_id,
        context=context,
        text="<b>⏳ Menjalankan action...</b>",
        reply_markup=_result_keyboard(menu.id, page),
    )
    await _run_action(
        runtime=runtime,
        context=context,
        chat_id=chat_id,
        menu_id=menu.id,
        action_id=action.id,
        params=params,
        page=page,
        query=query,
    )


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    runtime = _get_runtime(context)
    ok, reason = _is_authorized(runtime, update)
    if not ok:
        await update.effective_message.reply_text(reason)
        return

    await update.effective_message.reply_text(
        "Selamat datang. Gunakan /menu untuk membuka kontrol server.",
    )


def _parse_cleanup_limit(context: ContextTypes.DEFAULT_TYPE) -> tuple[int | None, str]:
    if not context.args:
        return CLEANUP_FULL_SWEEP, ""

    raw = str(context.args[0]).strip()
    if not raw.isdigit():
        return None, f"Argumen cleanup harus angka 1-{CLEANUP_MAX_LIMIT}. Contoh: /cleanup 80"

    limit = int(raw)
    if limit < 1 or limit > CLEANUP_MAX_LIMIT:
        return None, f"Batas cleanup harus antara 1 sampai {CLEANUP_MAX_LIMIT}."

    return limit, ""


async def cmd_cleanup(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    runtime = _get_runtime(context)
    ok, reason = _is_authorized(runtime, update)
    if not ok:
        if update.effective_message:
            await update.effective_message.reply_text(reason)
        return

    chat = update.effective_chat
    msg = update.effective_message
    if chat is None or msg is None:
        return

    user_id = str(update.effective_user.id) if update.effective_user else ""
    wait = _cooldown_remaining(
        context,
        user_id=user_id,
        key=KEY_LAST_CLEANUP_TS,
        min_interval_sec=runtime.config.cleanup_cooldown_seconds,
    )
    if wait > 0:
        await msg.reply_text(_throttle_message(wait))
        return

    limit, err = _parse_cleanup_limit(context)
    if limit is None:
        await msg.reply_text(err)
        return

    _clear_pending(context)

    deleted = 0
    skipped = 0
    anchor_message_id = int(msg.message_id)
    scan_message_id = anchor_message_id
    full_sweep = limit == CLEANUP_FULL_SWEEP
    target_deleted = max(anchor_message_id - CLEANUP_KEEP_MESSAGES, 0) if full_sweep else int(limit)
    max_scan = max(CLEANUP_MAX_SCAN_IDS, int(limit) + CLEANUP_KEEP_MESSAGES) if not full_sweep else CLEANUP_MAX_SCAN_IDS
    scanned = 0

    # Hapus sampai target jumlah pesan TERHAPUS tercapai, bukan sekadar jumlah ID yang dipindai.
    while scan_message_id >= 1 and deleted < target_deleted and scanned < max_scan:
        try:
            await context.bot.delete_message(chat_id=chat.id, message_id=scan_message_id)
            deleted += 1
        except Exception:
            skipped += 1
        scan_message_id -= 1
        scanned += 1

    suffix = ""
    if full_sweep and scanned >= max_scan and deleted < target_deleted:
        suffix = f" (dibatasi scan maksimal {max_scan} message-id)"

    await context.bot.send_message(
        chat_id=chat.id,
        text=f"🧹 Cleanup selesai: {deleted} pesan dihapus, {skipped} dilewati.{suffix}",
    )


async def cmd_menu(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    runtime = _get_runtime(context)
    ok, reason = _is_authorized(runtime, update)
    if not ok:
        await update.effective_message.reply_text(reason)
        return

    _clear_pending(context)
    try:
        await _refresh_main_menu_snapshot(runtime)
    except Exception as exc:
        LOGGER.warning("Refresh main menu snapshot gagal: %s", sanitize_secret_text(str(exc)))

    await update.effective_message.reply_text(
        _main_menu_message(runtime),
        parse_mode=ParseMode.HTML,
        reply_markup=_main_menu_keyboard(runtime),
    )


async def _prompt_next_form_field(
    *,
    runtime: Runtime,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    pending: dict,
    query=None,
) -> None:
    menu = runtime.catalog.get_menu(str(pending.get("menu_id", "")))
    action = runtime.catalog.get_action(str(pending.get("menu_id", "")), str(pending.get("action_id", "")))
    if menu is None or action is None or action.modal is None:
        raise RuntimeError("State form tidak valid.")

    idx = int(pending.get("index", 0))
    if idx < 0 or idx >= len(action.modal.fields):
        raise RuntimeError("Index form tidak valid.")

    field = action.modal.fields[idx]
    click_only_field = _is_click_only_field(action.id, field.id)
    choice_options = await _resolve_form_choice_options(runtime, pending, field.id)
    choice_with_manual: list[tuple[str, str]] = list(choice_options)
    if not click_only_field:
        if choice_options:
            choice_with_manual.append(("✍️ Lainnya (input manual)", FORM_CHOICE_MANUAL_VALUE))
        else:
            choice_with_manual.append(("✍️ Input Manual", FORM_CHOICE_MANUAL_VALUE))
    if not click_only_field and not _field_is_required(pending, field):
        choice_with_manual.append(("⏭️ Lewati", FORM_CHOICE_SKIP_VALUE))

    pending.pop("manual_entry", None)
    pending["choice_options"] = _serialize_choice_options(choice_with_manual)
    pending["choice_page"] = 0
    _store_pending_state(context, KEY_PENDING_FORM, pending, chat_id)
    await _render_pending_choice_prompt(
        runtime=runtime,
        context=context,
        chat_id=chat_id,
        pending=pending,
        query=query,
    )


async def _submit_pending_form_value(
    *,
    runtime: Runtime,
    context: ContextTypes.DEFAULT_TYPE,
    chat_id: int,
    pending: dict,
    raw_value: str,
    query=None,
    reply_message=None,
) -> None:
    menu_id = str(pending.get("menu_id", ""))
    action_id = str(pending.get("action_id", ""))
    menu = runtime.catalog.get_menu(menu_id)
    action = runtime.catalog.get_action(menu_id, action_id)
    if menu is None or action is None or action.modal is None:
        _clear_pending(context)
        if reply_message is not None:
            await reply_message.reply_text("Sesi input rusak. Jalankan /menu lagi.")
        elif query is not None:
            await query.answer("Sesi input rusak. Jalankan /menu lagi.", show_alert=True)
        return

    idx = int(pending.get("index", 0))
    if idx < 0 or idx >= len(action.modal.fields):
        _clear_pending(context)
        if reply_message is not None:
            await reply_message.reply_text("Sesi input sudah selesai. Jalankan /menu lagi.")
        elif query is not None:
            await query.answer("Sesi input sudah selesai. Jalankan /menu lagi.", show_alert=True)
        return

    field = action.modal.fields[idx]
    value = str(raw_value or "").strip()
    manual_entry = bool(pending.get("manual_entry"))
    if manual_entry and len(value) > runtime.config.max_manual_input_len:
        msg = f"Input terlalu panjang (maks {runtime.config.max_manual_input_len} karakter)."
        if reply_message is not None:
            await reply_message.reply_text(msg)
        elif query is not None:
            await query.answer(msg, show_alert=True)
        return

    choice_options = _pending_choice_options(pending)
    if choice_options and not manual_entry:
        allowed = {str(item.get("value") or "") for item in choice_options}
        if value not in allowed:
            if reply_message is not None:
                await reply_message.reply_text("Untuk field ini gunakan tombol pilihan yang tersedia.")
            elif query is not None:
                await query.answer("Gunakan tombol pilihan.", show_alert=True)
            return

        if value == FORM_CHOICE_MANUAL_VALUE:
            pending.pop("choice_options", None)
            pending.pop("choice_page", None)
            pending["manual_entry"] = True
            _store_pending_state(context, KEY_PENDING_FORM, pending, chat_id)
            step_no, total_steps = _display_form_progress(action, pending, idx)
            text = _manual_input_prompt(
                menu,
                action,
                field,
                step_no,
                total_steps,
                params=pending.get("params"),
            )
            menu_page = _safe_int(str(pending.get("page") or "0"), default=0)
            markup = InlineKeyboardMarkup(
                [[InlineKeyboardButton("❌ Batal", callback_data=f"cf{CALLBACK_SEP}{menu_id}{CALLBACK_SEP}{menu_page}")]]
            )
            if query is not None:
                await _send_or_edit(
                    query=query,
                    chat_id=chat_id,
                    context=context,
                    text=text,
                    reply_markup=markup,
                )
            elif reply_message is not None:
                await reply_message.reply_text(
                    text,
                    parse_mode=ParseMode.HTML,
                    reply_markup=markup,
                )
            return

        if value == FORM_CHOICE_SKIP_VALUE:
            value = ""
    elif value.lower() in {"-", "skip", "lewati"}:
        value = ""

    if manual_entry:
        pending.pop("manual_entry", None)

    if _field_is_required(pending, field) and not value:
        if reply_message is not None:
            await reply_message.reply_text("Field ini wajib diisi. Coba lagi.")
        elif query is not None:
            await query.answer("Field ini wajib diisi.", show_alert=True)
        await _prompt_next_form_field(runtime=runtime, context=context, chat_id=chat_id, pending=pending, query=query)
        return

    params = pending.get("params") if isinstance(pending.get("params"), dict) else {}
    if value:
        params[field.id] = value

    pending["params"] = params
    next_idx = idx + 1
    if field.id == "speed_limit_enabled" and not _is_truthy(value):
        # Saat speed limit OFF/skip, lewati field speed down/up.
        while next_idx < len(action.modal.fields):
            next_field_id = action.modal.fields[next_idx].id
            if next_field_id not in {"speed_down_mbit", "speed_up_mbit"}:
                break
            next_idx += 1

    pending["index"] = next_idx
    pending.pop("choice_options", None)
    pending.pop("choice_page", None)
    _store_pending_state(context, KEY_PENDING_FORM, pending, chat_id)

    if pending["index"] < len(action.modal.fields):
        await _prompt_next_form_field(runtime=runtime, context=context, chat_id=chat_id, pending=pending, query=query)
        return

    context.user_data.pop(KEY_PENDING_FORM, None)
    menu_page = _safe_int(str(pending.get("page") or "0"), default=0)

    if action.confirm:
        _store_pending_state(
            context,
            KEY_PENDING_CONFIRM,
            {
                "menu_id": menu_id,
                "action_id": action_id,
                "params": params,
                "page": menu_page,
            },
            chat_id,
        )
        if query is not None:
            await _send_or_edit(
                query=query,
                chat_id=chat_id,
                context=context,
                text=confirm_text(menu, action, params),
                reply_markup=_confirm_keyboard(menu_id, menu_page),
            )
        elif reply_message is not None:
            await reply_message.reply_text(
                confirm_text(menu, action, params),
                parse_mode=ParseMode.HTML,
                reply_markup=_confirm_keyboard(menu_id, menu_page),
            )
        return

    if query is not None:
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text="<b>⏳ Menjalankan action...</b>",
            reply_markup=_result_keyboard(menu_id, menu_page),
        )
    elif reply_message is not None:
        await reply_message.reply_text("⏳ Menjalankan action...")

    await _run_action(
        runtime=runtime,
        context=context,
        chat_id=chat_id,
        menu_id=menu_id,
        action_id=action_id,
        params=params,
        page=menu_page,
        query=query,
    )


async def on_document_input(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    runtime = _get_runtime(context)
    ok, reason = _is_authorized(runtime, update)
    if not ok:
        if update.effective_message:
            await update.effective_message.reply_text(reason)
        return

    msg = update.effective_message
    chat = update.effective_chat
    doc = msg.document if msg else None
    if msg is None or chat is None or doc is None:
        return

    pending_upload, pending_upload_err = _get_pending_state(context, KEY_PENDING_UPLOAD_RESTORE, chat.id if chat else None)
    if pending_upload is None:
        if pending_upload_err:
            await msg.reply_text(pending_upload_err)
        return

    name = str(doc.file_name or "").strip()
    if not name.lower().endswith(".tar.gz"):
        await msg.reply_text("File restore harus berekstensi .tar.gz")
        return

    size_bytes = int(doc.file_size or 0)
    if size_bytes > UPLOAD_RESTORE_MAX_BYTES:
        await msg.reply_text(
            (
                "Ukuran file terlalu besar untuk restore upload.\n"
                f"Maksimal: {format_size(UPLOAD_RESTORE_MAX_BYTES)}\n"
                f"File ini: {format_size(size_bytes)}"
            )
        )
        return

    upload_dir = resolve_restore_upload_dir(UPLOAD_RESTORE_DIRS)
    upload_id = f"{int(time.time())}-{doc.file_unique_id}"
    upload_name = f"restore-upload-{upload_id}.tar.gz"
    upload_path = upload_dir / upload_name

    try:
        tg_file = await doc.get_file()
        await tg_file.download_to_drive(custom_path=str(upload_path))
    except Exception as exc:
        LOGGER.warning("Gagal download file restore upload: %s", exc)
        await msg.reply_text("Gagal mengunduh file dari Telegram. Coba kirim ulang.")
        return

    menu_id = str(pending_upload.get("menu_id") or BACKUP_MENU_ID)
    action_id = str(pending_upload.get("action_id") or "restore_from_upload")
    menu_page = _safe_int(str(pending_upload.get("page") or "0"), default=0)
    menu = runtime.catalog.get_menu(menu_id)
    action = runtime.catalog.get_action(menu_id, action_id)
    if menu is None or action is None:
        context.user_data.pop(KEY_PENDING_UPLOAD_RESTORE, None)
        cleanup_uploaded_archive(str(upload_path), UPLOAD_RESTORE_DIRS)
        await msg.reply_text("Action restore upload tidak ditemukan. Jalankan /menu lagi.")
        return

    params = {"upload_path": str(upload_path)}
    context.user_data.pop(KEY_PENDING_UPLOAD_RESTORE, None)
    _store_pending_state(
        context,
        KEY_PENDING_CONFIRM,
        {
            "menu_id": menu_id,
            "action_id": action_id,
            "params": params,
            "page": menu_page,
        },
        chat.id,
    )

    confirm_msg = (
        f"<b>Konfirmasi: {html.escape(menu.label)} · {html.escape(action.label)}</b>\n\n"
        f"- File: <code>{html.escape(name or upload_name)}</code>\n"
        f"- Ukuran: <code>{html.escape(format_size(size_bytes))}</code>\n\n"
        "Lanjutkan eksekusi restore?"
    )
    await msg.reply_text(
        confirm_msg,
        parse_mode=ParseMode.HTML,
        reply_markup=_confirm_keyboard(menu_id, menu_page),
    )


async def on_text_input(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    runtime = _get_runtime(context)
    ok, reason = _is_authorized(runtime, update)
    if not ok:
        await update.effective_message.reply_text(reason)
        return

    pending_upload, pending_upload_err = _get_pending_state(
        context,
        KEY_PENDING_UPLOAD_RESTORE,
        update.effective_chat.id if update.effective_chat else None,
    )
    if pending_upload is not None:
        await update.effective_message.reply_text(
            "Sesi restore upload aktif. Kirim file backup .tar.gz atau tekan Batal."
        )
        return
    if pending_upload_err:
        await update.effective_message.reply_text(pending_upload_err)
        return

    pending, pending_err = _get_pending_state(
        context,
        KEY_PENDING_FORM,
        update.effective_chat.id if update.effective_chat else None,
    )
    if pending is None:
        if pending_err:
            await update.effective_message.reply_text(pending_err)
        return

    await _submit_pending_form_value(
        runtime=runtime,
        context=context,
        chat_id=update.effective_chat.id,
        pending=pending,
        raw_value=(update.effective_message.text or ""),
        query=None,
        reply_message=update.effective_message,
    )


async def on_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    runtime = _get_runtime(context)
    query = update.callback_query
    if query is None:
        return

    ok, reason = _is_authorized(runtime, update)
    if not ok:
        await query.answer(reason, show_alert=True)
        return

    data = str(query.data or "")
    if not data or len(data) > CALLBACK_DATA_MAX_LEN:
        await query.answer("Payload callback tidak valid.", show_alert=True)
        return
    await query.answer()
    chat_id = _callback_chat_id(update)
    user_id = str(update.effective_user.id) if update.effective_user else ""

    if data == "noop":
        return

    if _has_pending_state_in_other_chat(context, chat_id):
        await query.answer(PENDING_OTHER_CHAT_TEXT, show_alert=True)
        return

    if data == "h":
        _clear_pending(context)
        try:
            await _refresh_main_menu_snapshot(runtime)
        except Exception as exc:
            LOGGER.warning("Refresh main menu snapshot gagal: %s", sanitize_secret_text(str(exc)))
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=_main_menu_message(runtime),
            reply_markup=_main_menu_keyboard(runtime),
        )
        return

    if data.startswith(f"cf{CALLBACK_SEP}"):
        _clear_pending(context)
        parts = data.split(CALLBACK_SEP)
        menu_id = parts[1] if len(parts) > 1 else ""
        page = _safe_int(parts[2] if len(parts) > 2 else "0", default=0)
        menu = runtime.catalog.get_menu(menu_id)
        if menu is None:
            await _send_or_edit(
                query=query,
                chat_id=chat_id,
                context=context,
                text=_main_menu_message(runtime),
                reply_markup=_main_menu_keyboard(runtime),
            )
            return
        if menu_id in QAC_MENU_IDS:
            await _render_qac_menu(
                runtime=runtime,
                context=context,
                chat_id=chat_id,
                query=query,
                menu=menu,
                page=page,
            )
            return
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=menu_text(menu, page, _menu_pages(runtime, menu)),
            reply_markup=_menu_keyboard(runtime, menu, page),
        )
        return

    if data.startswith(f"pfp{CALLBACK_SEP}"):
        pending, pending_err = _get_pending_state(context, KEY_PENDING_FORM, chat_id)
        if pending is None:
            if pending_err:
                await query.answer(pending_err, show_alert=True)
                return
            await query.answer("Sesi input tidak aktif.", show_alert=True)
            return
        choice_options = _pending_choice_options(pending)
        if not choice_options:
            await query.answer("Pilihan tombol tidak tersedia.", show_alert=True)
            return
        parts = data.split(CALLBACK_SEP)
        page = _safe_int(parts[1] if len(parts) > 1 else "0", default=0)
        page_max = _choice_total_pages(choice_options) - 1
        page = max(0, min(page, page_max))
        pending["choice_page"] = page
        _store_pending_state(context, KEY_PENDING_FORM, pending, chat_id)
        await _render_pending_choice_prompt(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            pending=pending,
            query=query,
        )
        return

    if data.startswith(f"pfc{CALLBACK_SEP}"):
        pending, pending_err = _get_pending_state(context, KEY_PENDING_FORM, chat_id)
        if pending is None:
            if pending_err:
                await query.answer(pending_err, show_alert=True)
                return
            await query.answer("Sesi input tidak aktif.", show_alert=True)
            return
        choice_options = _pending_choice_options(pending)
        if not choice_options:
            await query.answer("Pilihan tombol tidak tersedia.", show_alert=True)
            return
        parts = data.split(CALLBACK_SEP)
        idx = _safe_int(parts[1] if len(parts) > 1 else "-1", default=-1)
        if idx < 0 or idx >= len(choice_options):
            await query.answer("Pilihan tidak valid.", show_alert=True)
            return
        value = str(choice_options[idx].get("value") or "")
        await _submit_pending_form_value(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            pending=pending,
            raw_value=value,
            query=query,
            reply_message=None,
        )
        return

    if data.startswith(f"acc_page{CALLBACK_SEP}"):
        state, state_err = _get_pending_state(context, KEY_PENDING_ACCOUNT_PICK, chat_id)
        if state is None:
            if state_err:
                await query.answer(state_err, show_alert=True)
                return
            await query.answer("Sesi pemilihan akun tidak aktif.", show_alert=True)
            return
        menu_id = str(state.get("menu_id") or XRAY_USER_MENU_ID)
        action_id = str(state.get("action_id") or "").strip()
        users = state.get("users") if isinstance(state.get("users"), list) else []
        menu_page = _safe_int(str(state.get("menu_page") or "0"), default=0)
        if menu_id not in DELETE_PICK_MENU_IDS or action_id not in ACCOUNT_PICK_ACTION_IDS or not users:
            await query.answer("Sesi pemilihan akun tidak valid.", show_alert=True)
            return
        parts = data.split(CALLBACK_SEP)
        page = _safe_int(parts[1] if len(parts) > 1 else "0", default=0)
        page_max = ((len(users) - 1) // DELETE_PICK_PAGE_SIZE)
        page = max(0, min(page, page_max))
        state["page"] = page
        _store_pending_state(context, KEY_PENDING_ACCOUNT_PICK, state, chat_id)
        menu = runtime.catalog.get_menu(menu_id)
        action = runtime.catalog.get_action(menu_id, action_id)
        if menu is None or action is None:
            await query.answer("Action tidak ditemukan.", show_alert=True)
            return
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=_account_pick_text(menu_id, action.label, page, users),
            reply_markup=_account_pick_keyboard(menu_id, page, users, menu_page),
        )
        return

    if data.startswith(f"acc_pick{CALLBACK_SEP}"):
        state, state_err = _get_pending_state(context, KEY_PENDING_ACCOUNT_PICK, chat_id)
        if state is None:
            if state_err:
                await query.answer(state_err, show_alert=True)
                return
            await query.answer("Sesi pemilihan akun tidak aktif.", show_alert=True)
            return
        menu_id = str(state.get("menu_id") or XRAY_USER_MENU_ID)
        action_id = str(state.get("action_id") or "").strip()
        users = state.get("users") if isinstance(state.get("users"), list) else []
        menu_page = _safe_int(str(state.get("menu_page") or "0"), default=0)
        if menu_id not in DELETE_PICK_MENU_IDS or action_id not in ACCOUNT_PICK_ACTION_IDS or not users:
            await query.answer("Sesi pemilihan akun tidak valid.", show_alert=True)
            return
        parts = data.split(CALLBACK_SEP)
        idx = _safe_int(parts[1] if len(parts) > 1 else "-1", default=-1)
        if idx < 0 or idx >= len(users):
            await query.answer("User tidak valid.", show_alert=True)
            return
        selected = users[idx] if isinstance(users[idx], dict) else {}
        proto = str(selected.get("proto") or "").strip().lower()
        username = str(selected.get("username") or "").strip()
        if not username or proto not in _menu_protocol_scope(menu_id):
            await query.answer("User tidak valid.", show_alert=True)
            return
        context.user_data.pop(KEY_PENDING_ACCOUNT_PICK, None)

        menu = runtime.catalog.get_menu(menu_id)
        action = runtime.catalog.get_action(menu_id, action_id)
        if menu is None or action is None:
            await query.answer("Action tidak ditemukan.", show_alert=True)
            return

        initial_params = {"username": username}
        if menu_id == XRAY_USER_MENU_ID:
            initial_params["proto"] = proto
        await _start_action_flow(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            user_id=user_id,
            query=query,
            menu=menu,
            action=action,
            initial_params=initial_params,
            page=menu_page,
        )
        return

    if data.startswith(f"dup_proto_menu{CALLBACK_SEP}"):
        parts = data.split(CALLBACK_SEP)
        menu_id = parts[1] if len(parts) > 1 else XRAY_USER_MENU_ID
        menu_page = _safe_int(parts[2] if len(parts) > 2 else "0", default=0)
        await _show_delete_user_proto_picker(
            context=context,
            chat_id=chat_id,
            query=query,
            menu_id=menu_id,
            menu_page=menu_page,
        )
        return

    if data.startswith(f"dup_proto{CALLBACK_SEP}"):
        parts = data.split(CALLBACK_SEP)
        if len(parts) not in {3, 4}:
            await query.answer("Protocol tidak valid.", show_alert=True)
            return
        menu_id = str(parts[1]).strip()
        proto = parts[2].strip().lower()
        menu_page = _safe_int(parts[3] if len(parts) > 3 else "0", default=0)
        if menu_id not in DELETE_PICK_MENU_IDS or proto not in _menu_protocol_scope(menu_id):
            await query.answer("Protocol tidak valid.", show_alert=True)
            return
        await _show_delete_user_list_picker(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            query=query,
            menu_id=menu_id,
            proto=proto,
            page=0,
            menu_page=menu_page,
        )
        return

    if data.startswith(f"dup_page{CALLBACK_SEP}"):
        state, state_err = _get_pending_state(context, KEY_PENDING_DELETE_PICK, chat_id)
        if state is None:
            if state_err:
                await query.answer(state_err, show_alert=True)
                return
            await query.answer("Sesi pemilihan user tidak aktif.", show_alert=True)
            return
        proto = str(state.get("proto") or "").strip().lower()
        menu_id = str(state.get("menu_id") or XRAY_USER_MENU_ID)
        users = state.get("users") if isinstance(state.get("users"), list) else []
        menu_page = _safe_int(str(state.get("menu_page") or "0"), default=0)
        if proto not in _menu_protocol_scope(menu_id) or not users:
            await query.answer("Sesi pemilihan user tidak valid.", show_alert=True)
            return
        parts = data.split(CALLBACK_SEP)
        page = _safe_int(parts[1] if len(parts) > 1 else "0", default=0)
        page_max = ((len(users) - 1) // DELETE_PICK_PAGE_SIZE)
        page = max(0, min(page, page_max))
        state["page"] = page
        _store_pending_state(context, KEY_PENDING_DELETE_PICK, state, chat_id)
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=_delete_pick_text_users(menu_id, proto, page, users),
            reply_markup=_delete_pick_users_keyboard(menu_id, page, users, menu_page),
        )
        return

    if data.startswith(f"dup_user{CALLBACK_SEP}"):
        state, state_err = _get_pending_state(context, KEY_PENDING_DELETE_PICK, chat_id)
        if state is None:
            if state_err:
                await query.answer(state_err, show_alert=True)
                return
            await query.answer("Sesi pemilihan user tidak aktif.", show_alert=True)
            return
        proto = str(state.get("proto") or "").strip().lower()
        menu_id = str(state.get("menu_id") or XRAY_USER_MENU_ID)
        users = state.get("users") if isinstance(state.get("users"), list) else []
        if proto not in _menu_protocol_scope(menu_id) or not users:
            await query.answer("Sesi pemilihan user tidak valid.", show_alert=True)
            return
        parts = data.split(CALLBACK_SEP)
        idx = _safe_int(parts[1] if len(parts) > 1 else "-1", default=-1)
        if idx < 0 or idx >= len(users):
            await query.answer("User tidak valid.", show_alert=True)
            return
        username = str(users[idx])
        context.user_data.pop(KEY_PENDING_DELETE_PICK, None)

        menu = runtime.catalog.get_menu(menu_id)
        action = runtime.catalog.get_action(menu_id, "delete_user")
        if menu is None or action is None:
            await query.answer("Action tidak ditemukan.", show_alert=True)
            return

        params = {
            "proto": proto,
            "username": username,
        }
        _store_pending_state(
            context,
            KEY_PENDING_CONFIRM,
            {
                "menu_id": menu_id,
                "action_id": "delete_user",
                "params": params,
                "page": menu_page,
            },
            chat_id,
        )
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=confirm_text(menu, action, params),
            reply_markup=_confirm_keyboard(menu_id, menu_page),
        )
        return

    if data.startswith(f"qac_pick_menu{CALLBACK_SEP}"):
        parts = data.split(CALLBACK_SEP)
        menu_id = parts[1] if len(parts) > 1 else XRAY_QAC_MENU_ID
        menu_page = _safe_int(parts[2] if len(parts) > 2 else "0", default=0)
        await _show_qac_user_picker(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            query=query,
            menu_id=menu_id,
            page=0,
            menu_page=menu_page,
        )
        return

    if data.startswith(f"qac_refresh{CALLBACK_SEP}"):
        parts = data.split(CALLBACK_SEP)
        menu_id = parts[1] if len(parts) > 1 else XRAY_QAC_MENU_ID
        page = _safe_int(parts[2] if len(parts) > 2 else "0", default=0)
        menu = runtime.catalog.get_menu(menu_id)
        if menu is None or menu_id not in QAC_MENU_IDS:
            await query.answer("Menu QAC tidak ditemukan.", show_alert=True)
            return
        await _render_qac_menu(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            query=query,
            menu=menu,
            page=page,
        )
        return

    if data.startswith(f"qac_page{CALLBACK_SEP}"):
        state, state_err = _get_pending_state(context, KEY_PENDING_QAC_PICK, chat_id)
        if state is None:
            if state_err:
                await query.answer(state_err, show_alert=True)
                return
            await query.answer("Sesi pemilihan user QAC tidak aktif.", show_alert=True)
            return
        menu_id = str(state.get("menu_id") or XRAY_QAC_MENU_ID)
        users = state.get("users") if isinstance(state.get("users"), list) else []
        menu_page = _safe_int(str(state.get("menu_page") or "0"), default=0)
        if menu_id not in QAC_MENU_IDS or not users:
            await query.answer("Sesi pemilihan user QAC tidak valid.", show_alert=True)
            return
        parts = data.split(CALLBACK_SEP)
        page = _safe_int(parts[1] if len(parts) > 1 else "0", default=0)
        page_max = ((len(users) - 1) // DELETE_PICK_PAGE_SIZE)
        page = max(0, min(page, page_max))
        state["page"] = page
        _store_pending_state(context, KEY_PENDING_QAC_PICK, state, chat_id)
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=_qac_pick_text(menu_id, page, users),
            reply_markup=_qac_pick_keyboard(menu_id, page, users, menu_page),
        )
        return

    if data.startswith(f"qac_pick{CALLBACK_SEP}"):
        state, state_err = _get_pending_state(context, KEY_PENDING_QAC_PICK, chat_id)
        if state is None:
            if state_err:
                await query.answer(state_err, show_alert=True)
                return
            await query.answer("Sesi pemilihan user QAC tidak aktif.", show_alert=True)
            return
        menu_id = str(state.get("menu_id") or XRAY_QAC_MENU_ID)
        users = state.get("users") if isinstance(state.get("users"), list) else []
        menu_page = _safe_int(str(state.get("menu_page") or "0"), default=0)
        if menu_id not in QAC_MENU_IDS or not users:
            await query.answer("Sesi pemilihan user QAC tidak valid.", show_alert=True)
            return
        parts = data.split(CALLBACK_SEP)
        idx = _safe_int(parts[1] if len(parts) > 1 else "-1", default=-1)
        if idx < 0 or idx >= len(users):
            await query.answer("User tidak valid.", show_alert=True)
            return
        selected = users[idx] if isinstance(users[idx], dict) else {}
        proto = str(selected.get("proto") or "").strip().lower()
        username = str(selected.get("username") or "").strip()
        if proto not in _menu_protocol_scope(menu_id) or not username:
            await query.answer("User tidak valid.", show_alert=True)
            return
        context.user_data.pop(KEY_PENDING_QAC_PICK, None)
        _set_qac_selection(
            context,
            menu_id,
            chat_id=chat_id,
            proto=proto,
            username=username,
        )
        menu = runtime.catalog.get_menu(menu_id)
        if menu is None:
            await query.answer("Menu QAC tidak ditemukan.", show_alert=True)
            return
        await _render_qac_menu(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            query=query,
            menu=menu,
            page=menu_page,
        )
        return

    if data == "rc":
        pending, pending_err = _get_pending_state(context, KEY_PENDING_CONFIRM, chat_id)
        if pending is None:
            if pending_err:
                await query.answer(pending_err, show_alert=True)
                return
            await query.answer("Tidak ada aksi yang menunggu konfirmasi.", show_alert=True)
            return

        wait = _cooldown_remaining(
            context,
            user_id=user_id,
            key=KEY_LAST_ACTION_TS,
            min_interval_sec=runtime.config.action_cooldown_seconds,
        )
        if wait > 0:
            await query.answer(_throttle_message(wait), show_alert=True)
            return

        menu_id = str(pending.get("menu_id", ""))
        action_id = str(pending.get("action_id", ""))
        params = pending.get("params") if isinstance(pending.get("params"), dict) else {}
        page = _safe_int(str(pending.get("page") or "0"), default=0)
        context.user_data.pop(KEY_PENDING_CONFIRM, None)

        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text="<b>⏳ Menjalankan action...</b>",
            reply_markup=_result_keyboard(menu_id, page),
        )
        await _run_action(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            menu_id=menu_id,
            action_id=action_id,
            params=params,
            page=page,
            query=query,
        )
        if action_id == "restore_from_upload":
            cleanup_uploaded_archive(str(params.get("upload_path") or ""), UPLOAD_RESTORE_DIRS)
        return

    parts = data.split(CALLBACK_SEP)
    kind = parts[0]

    if kind == "m" and len(parts) in {2, 3}:
        _clear_pending(context)
        menu = runtime.catalog.get_menu(parts[1])
        if menu is None:
            await query.answer("Menu tidak ditemukan.", show_alert=True)
            return
        page = _safe_int(parts[2] if len(parts) > 2 else "0", default=0)
        if not _visible_actions(runtime, menu):
            await query.answer("Tidak ada action yang aktif di menu ini.", show_alert=True)
            return
        parent_page = _get_menu_parent_page(context, menu.id, chat_id=chat_id)
        if menu.id in QAC_MENU_IDS:
            await _render_qac_menu(
                runtime=runtime,
                context=context,
                chat_id=chat_id,
                query=query,
                menu=menu,
                page=page,
            )
            return
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=menu_text(menu, page, _menu_pages(runtime, menu)),
            reply_markup=_menu_keyboard(runtime, menu, page, parent_page=parent_page),
        )
        return

    if kind == "p" and len(parts) == 3:
        menu = runtime.catalog.get_menu(parts[1])
        if menu is None:
            await query.answer("Menu tidak ditemukan.", show_alert=True)
            return
        if not _visible_actions(runtime, menu):
            await query.answer("Tidak ada action yang aktif di menu ini.", show_alert=True)
            return
        try:
            page = int(parts[2])
        except ValueError:
            page = 0
        page = max(0, min(page, _menu_pages(runtime, menu) - 1))
        parent_page = _get_menu_parent_page(context, menu.id, chat_id=chat_id)
        if menu.id in QAC_MENU_IDS:
            await _render_qac_menu(
                runtime=runtime,
                context=context,
                chat_id=chat_id,
                query=query,
                menu=menu,
                page=page,
            )
            return
        await _send_or_edit(
            query=query,
            chat_id=chat_id,
            context=context,
            text=menu_text(menu, page, _menu_pages(runtime, menu)),
            reply_markup=_menu_keyboard(runtime, menu, page, parent_page=parent_page),
        )
        return

    if kind == "a" and len(parts) in {3, 4}:
        menu_id = parts[1]
        if len(parts) > 3:
            page = _safe_int(parts[2], default=0)
            action_id = parts[3]
        else:
            page = 0
            action_id = parts[2]
        menu = runtime.catalog.get_menu(menu_id)
        action = runtime.catalog.get_action(menu_id, action_id)
        if menu is None or action is None:
            await query.answer("Action tidak ditemukan.", show_alert=True)
            return
        if not _action_visible(runtime, action):
            await query.answer("Action ini sedang nonaktif.", show_alert=True)
            return

        _clear_pending(context)

        if menu_id in DELETE_PICK_MENU_IDS and action_id in ACCOUNT_PICK_ACTION_IDS:
            await _show_account_user_picker(
                runtime=runtime,
                context=context,
                chat_id=chat_id,
                query=query,
                menu_id=menu_id,
                action_id=action_id,
                page=0,
                menu_page=page,
            )
            return

        if action.mode == "menu":
            target_menu_id = str(action.target_menu or "").strip()
            target_menu = runtime.catalog.get_menu(target_menu_id)
            if target_menu is None:
                await query.answer("Submenu tidak ditemukan.", show_alert=True)
                return
            if not _visible_actions(runtime, target_menu):
                await query.answer("Tidak ada action yang aktif di submenu ini.", show_alert=True)
                return
            _set_menu_parent_page(context, target_menu.id, chat_id=chat_id, parent_page=page)
            if target_menu.id in QAC_MENU_IDS:
                await _render_qac_menu(
                    runtime=runtime,
                    context=context,
                    chat_id=chat_id,
                    query=query,
                    menu=target_menu,
                    page=0,
                )
                return
            await _send_or_edit(
                query=query,
                chat_id=chat_id,
                context=context,
                text=menu_text(target_menu, 0, _menu_pages(runtime, target_menu)),
                reply_markup=_menu_keyboard(runtime, target_menu, 0, parent_page=page),
            )
            return

        if menu_id == BACKUP_MENU_ID and action_id == "restore_from_upload":
            _store_pending_state(
                context,
                KEY_PENDING_UPLOAD_RESTORE,
                {
                    "menu_id": menu_id,
                    "action_id": action_id,
                    "page": page,
                },
                chat_id,
            )
            await _send_or_edit(
                query=query,
                chat_id=chat_id,
                context=context,
                text=(
                    "<b>Restore Upload</b>\n"
                    "Kirim file backup berekstensi <code>.tar.gz</code> lewat Telegram.\n"
                    f"Ukuran maksimal: <code>{html.escape(format_size(UPLOAD_RESTORE_MAX_BYTES))}</code>\n\n"
                    "Setelah file diterima, bot akan minta konfirmasi sebelum restore dijalankan."
                ),
                reply_markup=InlineKeyboardMarkup(
                    [[InlineKeyboardButton("❌ Batal", callback_data=f"cf{CALLBACK_SEP}{menu_id}{CALLBACK_SEP}{page}")]]
                ),
            )
            return

        initial_params = _prefilled_action_params(
            context,
            menu_id=menu_id,
            action_id=action_id,
            chat_id=chat_id,
        )
        if menu_id in QAC_MENU_IDS and action_id != "summary" and not initial_params:
            await _show_qac_user_picker(
                runtime=runtime,
                context=context,
                chat_id=chat_id,
                query=query,
                menu_id=menu_id,
                page=0,
                menu_page=page,
            )
            return

        await _start_action_flow(
            runtime=runtime,
            context=context,
            chat_id=chat_id,
            user_id=user_id,
            query=query,
            menu=menu,
            action=action,
            initial_params=initial_params,
            page=page,
        )
        return

    await query.answer("Interaksi tidak dikenali. Jalankan /menu lagi.", show_alert=True)


def _load_main_menu_snapshot_from_backend_or_die(backend: BackendClient) -> tuple[CommandCatalog, str]:
    deadline = time.monotonic() + BACKEND_MENU_SYNC_TIMEOUT_SECONDS
    attempt = 0
    last_error: Exception | None = None

    while True:
        attempt += 1
        try:
            main_menu = asyncio.run(backend.get_main_menu())
            catalog, header_text = _catalog_from_main_menu_payload(main_menu)
            LOGGER.info(
                "Backend menu sync complete: menus=%s attempts=%s",
                len(catalog.menus),
                attempt,
            )
            return catalog, header_text
        except (BackendError, RuntimeError) as exc:
            last_error = exc

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(f"Sinkronisasi menu backend gagal: {last_error}") from last_error

        sleep_for = min(BACKEND_MENU_SYNC_RETRY_INTERVAL_SECONDS, remaining)
        LOGGER.warning(
            "Backend menu sync belum siap (attempt=%s retry_in=%.1fs): %s",
            attempt,
            sleep_for,
            last_error,
        )
        time.sleep(sleep_for)


async def post_init(application: Application) -> None:
    runtime = application.bot_data.get("runtime")
    if isinstance(runtime, Runtime):
        try:
            health = await runtime.backend.health()
            LOGGER.info("Backend health: %s", health)
        except Exception as exc:
            LOGGER.warning("Backend health check saat startup gagal: %s", exc)

    try:
        await application.bot.set_my_commands(
            [
                BotCommand("menu", "Open menu utama"),
                BotCommand("cleanup", "Hapus pesan menumpuk"),
            ]
        )
    except Exception as exc:
        LOGGER.warning("Gagal set bot commands: %s", exc)


def main() -> None:
    configure_masked_logging()

    config = load_config()
    backend = BackendClient(config.backend_base_url, config.shared_secret)
    catalog, header_text = _load_main_menu_snapshot_from_backend_or_die(backend)

    runtime = Runtime(
        config=config,
        catalog=catalog,
        backend=backend,
        hostname=socket.gethostname(),
        main_menu_header=header_text,
    )

    application = Application.builder().token(config.token).post_init(post_init).build()
    application.bot_data["runtime"] = runtime

    application.add_handler(CommandHandler("start", cmd_start))
    application.add_handler(CommandHandler("menu", cmd_menu))
    application.add_handler(CommandHandler("cleanup", cmd_cleanup))

    application.add_handler(CallbackQueryHandler(on_callback))
    application.add_handler(MessageHandler(filters.Document.ALL, on_document_input))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text_input))
    application.add_error_handler(on_error)

    LOGGER.info("Starting bot-telegram-gateway")
    # Python 3.12 no longer guarantees a default loop for the main thread.
    # PTB still expects one when entering run_polling().
    asyncio.set_event_loop(asyncio.new_event_loop())
    application.run_polling(allowed_updates=["message", "callback_query"])


if __name__ == "__main__":
    main()

from __future__ import annotations

import logging
import re
from typing import Any


TELEGRAM_TOKEN_RE = re.compile(r"\b\d{6,}:[A-Za-z0-9_-]{20,}\b")
THREE_SEGMENT_TOKEN_RE = re.compile(r"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{20,}\b")
BEARER_RE = re.compile(r"(?i)\bBearer\s+([A-Za-z0-9._~-]{16,})")
# Xray UUID v4 regex
UUID_RE = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")


def mask_secret(value: str) -> str:
    raw = str(value or "").strip()
    if not raw:
        return raw
    if len(raw) <= 8:
        return "********"
    return f"{raw[:4]}****{raw[-4:]}"


def sanitize_secret_text(value: str, *, mask_bearer: bool = True) -> str:
    text = str(value or "")
    text = TELEGRAM_TOKEN_RE.sub(lambda match: mask_secret(match.group(0)), text)
    text = THREE_SEGMENT_TOKEN_RE.sub(lambda match: mask_secret(match.group(0)), text)
    text = UUID_RE.sub(lambda match: mask_secret(match.group(0)), text)
    if mask_bearer:
        text = BEARER_RE.sub(lambda match: f"Bearer {mask_secret(match.group(1))}", text)
    return text


def _sanitize_secret_value(value: Any):
    if isinstance(value, str):
        return sanitize_secret_text(value)
    if isinstance(value, tuple):
        return tuple(_sanitize_secret_value(item) for item in value)
    if isinstance(value, list):
        return [_sanitize_secret_value(item) for item in value]
    if isinstance(value, dict):
        return {key: _sanitize_secret_value(item) for key, item in value.items()}
    return value


class SecretMaskingFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            if isinstance(record.msg, str):
                record.msg = sanitize_secret_text(record.msg)
            record.args = _sanitize_secret_value(record.args)
            if isinstance(record.exc_text, str):
                record.exc_text = sanitize_secret_text(record.exc_text)
            if isinstance(record.stack_info, str):
                record.stack_info = sanitize_secret_text(record.stack_info)
        except Exception:
            pass
        return True


def configure_masked_logging(level: int = logging.INFO) -> None:
    logging.basicConfig(
        format="%(asctime)s | %(name)s | %(levelname)s | %(message)s",
        level=level,
    )

    root_logger = logging.getLogger()
    masking_filter = SecretMaskingFilter()
    for handler in root_logger.handlers:
        handler.addFilter(masking_filter)

    # Suppress low-value request logs
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)

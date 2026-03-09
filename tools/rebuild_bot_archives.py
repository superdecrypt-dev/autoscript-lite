#!/usr/bin/env python3
from __future__ import annotations

import stat
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
FIXED_ZIP_DT = (2026, 1, 1, 0, 0, 0)

BOT_CONFIGS = {
    "bot-discord": {
        "archive": REPO_ROOT / "bot_discord.zip",
        "extra_skip_roots": {("gateway-ts", "dist")},
    },
    "bot-telegram": {
        "archive": REPO_ROOT / "bot_telegram.zip",
        "extra_skip_roots": set(),
    },
}

COMMON_SKIP_DIRS = {".venv", "node_modules", "__pycache__"}
COMMON_RUNTIME_EPHEMERAL = {("runtime", "logs"), ("runtime", "tmp")}


def should_include(root: Path, path: Path, extra_skip_roots: set[tuple[str, ...]]) -> bool:
    rel_parts = path.relative_to(root).parts
    if any(part in COMMON_SKIP_DIRS for part in rel_parts):
        return False
    if path.suffix == ".pyc":
        return False
    if rel_parts[:2] in COMMON_RUNTIME_EPHEMERAL and path.name != ".gitkeep":
        return False
    for skip_root in extra_skip_roots:
        if rel_parts[: len(skip_root)] == skip_root:
            return False
    return path.is_file()


def iter_included_files(root: Path, extra_skip_roots: set[tuple[str, ...]]):
    for path in sorted(root.rglob("*")):
        if should_include(root, path, extra_skip_roots):
            yield path


def write_archive(bot_dir: Path, archive_path: Path, extra_skip_roots: set[tuple[str, ...]]) -> None:
    tmp_path = archive_path.with_suffix(archive_path.suffix + ".tmp")
    with zipfile.ZipFile(tmp_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in iter_included_files(bot_dir, extra_skip_roots):
            rel = path.relative_to(bot_dir.parent).as_posix()
            info = zipfile.ZipInfo(rel)
            info.date_time = FIXED_ZIP_DT
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = ((stat.S_IFREG | 0o644) << 16)
            zf.writestr(info, path.read_bytes())

    tmp_path.replace(archive_path)


def main() -> None:
    for bot_name, cfg in BOT_CONFIGS.items():
        bot_dir = REPO_ROOT / bot_name
        archive_path = cfg["archive"]
        extra_skip_roots = cfg["extra_skip_roots"]
        write_archive(bot_dir, archive_path, extra_skip_roots)
        print(f"{bot_name} rebuilt -> {archive_path.name}")


if __name__ == "__main__":
    main()

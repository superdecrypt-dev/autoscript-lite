from __future__ import annotations

from pathlib import Path


def format_size(num: int) -> str:
    n = max(0, int(num))
    if n >= 1024**3:
        return f"{n / (1024**3):.2f} GiB"
    if n >= 1024**2:
        return f"{n / (1024**2):.2f} MiB"
    if n >= 1024:
        return f"{n / 1024:.2f} KiB"
    return f"{n} B"


def is_subpath(path: Path, base: Path) -> bool:
    try:
        rp = path.resolve()
        rb = base.resolve()
    except Exception:
        return False
    return rp == rb or rb in rp.parents


def resolve_restore_upload_dir(upload_restore_dirs: tuple[Path, ...]) -> Path:
    for candidate in upload_restore_dirs:
        try:
            candidate.mkdir(parents=True, exist_ok=True)
            return candidate
        except Exception:
            continue
    return upload_restore_dirs[0]


def cleanup_uploaded_archive(raw_path: str, upload_restore_dirs: tuple[Path, ...]) -> None:
    path_text = str(raw_path or "").strip()
    if not path_text:
        return
    try:
        resolved = Path(path_text).resolve()
    except Exception:
        return
    if not any(is_subpath(resolved, root) for root in upload_restore_dirs):
        return
    try:
        resolved.unlink(missing_ok=True)
    except Exception:
        pass


def cleanup_stale_uploaded_archives(upload_restore_dirs: tuple[Path, ...]) -> int:
    deleted = 0
    seen: set[Path] = set()
    for root in upload_restore_dirs:
        try:
            resolved_root = root.resolve()
        except Exception:
            continue
        if resolved_root in seen:
            continue
        seen.add(resolved_root)
        try:
            for candidate in resolved_root.glob("restore-upload-*.tar.gz"):
                if not candidate.is_file():
                    continue
                cleanup_uploaded_archive(str(candidate), upload_restore_dirs)
                deleted += 1
        except Exception:
            continue
    return deleted


def resolve_local_download(
    data: dict,
    *,
    allow_dirs: tuple[Path, ...],
) -> tuple[str, Path] | None:
    raw_path = str(data.get("download_local_path") or "").strip()
    if not raw_path:
        return None
    try:
        resolved = Path(raw_path).resolve()
    except Exception:
        return None
    if not resolved.exists() or not resolved.is_file():
        return None
    if not any(is_subpath(resolved, root) for root in allow_dirs):
        return None

    filename = str(data.get("download_filename") or "").strip() or resolved.name
    return filename, resolved

from __future__ import annotations

import io
import json
import os
import pwd
import re
import tarfile
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

from ..utils.locks import file_lock
from .system import run_cmd

BACKUP_LOCK_FILE = "/var/lock/xray-backup-restore.lock"
BACKUP_SCHEMA_VERSION = 1
BACKUP_RETENTION_KEEP = 10
MAX_UPLOAD_ARCHIVE_BYTES = 20 * 1024 * 1024
MAX_UPLOAD_RESTORE_MEMBER_BYTES = 32 * 1024 * 1024
MAX_UPLOAD_RESTORE_TOTAL_BYTES = 256 * 1024 * 1024
MAX_UPLOAD_RESTORE_ENTRIES = 20_000
MAX_RESTORE_MANIFEST_BYTES = 4 * 1024 * 1024
STREAM_CHUNK_BYTES = 1024 * 1024

BOT_HOME = Path(os.getenv("BOT_HOME") or Path(__file__).resolve().parents[3])
BOT_STATE_DIR = Path(os.getenv("BOT_STATE_DIR", "/var/lib/bot-telegram"))
GATEWAY_RUN_USER = (os.getenv("GATEWAY_RUN_USER") or "bot-telegram-gateway").strip() or "bot-telegram-gateway"
BACKUP_ROOT_DIR = BOT_STATE_DIR / "backups"
BACKUP_ARCHIVES_DIR = BACKUP_ROOT_DIR / "archives"
BACKUP_SAFETY_DIR = BACKUP_ROOT_DIR / "safety"
UPLOAD_DIR_PRIMARY = BOT_STATE_DIR / "tmp" / "uploads"
UPLOAD_DIR_ALT = BOT_HOME / "runtime" / "tmp" / "uploads"
EDGE_RUNTIME_ENV_FILE = Path("/etc/default/edge-runtime")
BADVPN_RUNTIME_ENV_FILE = Path("/etc/default/badvpn-udpgw")

BACKUP_SOURCE_PATHS = (
    Path("/usr/local/etc/xray/conf.d"),
    Path("/etc/nginx/conf.d/xray.conf"),
    Path("/opt/account"),
    Path("/opt/quota"),
    Path("/opt/speed"),
    Path("/etc/xray-speed/config.json"),
    Path("/var/lib/xray-speed/state.json"),
    Path("/var/lib/xray-manage/network_state.json"),
    EDGE_RUNTIME_ENV_FILE,
    BADVPN_RUNTIME_ENV_FILE,
    Path("/etc/wireproxy/config.conf"),
    Path("/etc/xray/domain"),
    Path("/opt/cert/fullchain.pem"),
    Path("/opt/cert/privkey.pem"),
)

RESTORE_ALLOWED_DIRS = (
    Path("/usr/local/etc/xray/conf.d"),
    Path("/opt/account"),
    Path("/opt/quota"),
    Path("/opt/speed"),
)
RESTORE_ALLOWED_FILES = (
    Path("/etc/nginx/conf.d/xray.conf"),
    Path("/etc/xray-speed/config.json"),
    Path("/var/lib/xray-speed/state.json"),
    Path("/var/lib/xray-manage/network_state.json"),
    EDGE_RUNTIME_ENV_FILE,
    BADVPN_RUNTIME_ENV_FILE,
    Path("/etc/wireproxy/config.conf"),
    Path("/etc/xray/domain"),
    Path("/opt/cert/fullchain.pem"),
    Path("/opt/cert/privkey.pem"),
)

VALIDATION_COMMANDS = (
    ["xray", "run", "-test", "-confdir", "/usr/local/etc/xray/conf.d"],
    ["nginx", "-t"],
)
REQUIRED_RESTART_SERVICES = (
    "xray",
    "nginx",
    "xray-speed",
    "xray-expired",
    "xray-quota",
    "xray-limit-ip",
)
OPTIONAL_RESTART_SERVICES = ("wireproxy", "sshws-stunnel", "edge-mux", "badvpn-udpgw")


def _now_utc_text() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _fmt_size(num: int) -> str:
    n = max(0, int(num))
    if n >= 1024**3:
        return f"{n / (1024**3):.2f} GiB"
    if n >= 1024**2:
        return f"{n / (1024**2):.2f} MiB"
    if n >= 1024:
        return f"{n / 1024:.2f} KiB"
    return f"{n} B"


def _gateway_identity() -> tuple[int, int] | None:
    try:
        entry = pwd.getpwnam(GATEWAY_RUN_USER)
    except Exception:
        return None
    return int(entry.pw_uid), int(entry.pw_gid)


def _set_path_owner_mode(path: Path, *, uid: int | None = None, gid: int | None = None, mode: int | None = None) -> None:
    try:
        os.chown(path, -1 if uid is None else uid, -1 if gid is None else gid)
    except Exception:
        pass
    if mode is not None:
        try:
            path.chmod(mode)
        except Exception:
            pass


def _ensure_backup_dirs() -> None:
    gateway_identity = _gateway_identity()
    for p in (BACKUP_ARCHIVES_DIR, BACKUP_SAFETY_DIR, UPLOAD_DIR_PRIMARY):
        p.mkdir(parents=True, exist_ok=True)
    _set_path_owner_mode(BACKUP_SAFETY_DIR, mode=0o700)

    if gateway_identity is None:
        _set_path_owner_mode(BACKUP_ARCHIVES_DIR, mode=0o700)
        _set_path_owner_mode(UPLOAD_DIR_PRIMARY, mode=0o700)
        return

    gateway_uid, gateway_gid = gateway_identity
    _set_path_owner_mode(BACKUP_ROOT_DIR, gid=gateway_gid, mode=0o750)
    _set_path_owner_mode(BACKUP_ARCHIVES_DIR, gid=gateway_gid, mode=0o2750)
    _set_path_owner_mode(UPLOAD_DIR_PRIMARY.parent, gid=gateway_gid, mode=0o750)
    _set_path_owner_mode(UPLOAD_DIR_PRIMARY, uid=gateway_uid, gid=gateway_gid, mode=0o2770)


def _adjust_archive_permissions(path: Path) -> None:
    gateway_identity = _gateway_identity()
    if gateway_identity is None:
        return

    _, gateway_gid = gateway_identity
    _set_path_owner_mode(path, gid=gateway_gid, mode=0o640)


class _CountingReader:
    def __init__(self, reader) -> None:
        self._reader = reader
        self.total_bytes = 0

    def read(self, size: int = -1) -> bytes:
        chunk = self._reader.read(size)
        if chunk:
            self.total_bytes += len(chunk)
        return chunk


def _iter_backup_files() -> list[Path]:
    out: list[Path] = []
    seen: set[str] = set()
    for base in BACKUP_SOURCE_PATHS:
        if base.is_file():
            key = str(base)
            if key not in seen:
                seen.add(key)
                out.append(base)
            continue
        if not base.is_dir():
            continue
        for fp in sorted(base.rglob("*")):
            if not fp.is_file():
                continue
            key = str(fp)
            if key in seen:
                continue
            seen.add(key)
            out.append(fp)
    return out


def _iter_backup_directories(files: list[Path]) -> list[dict[str, int | str]]:
    desired: dict[str, dict[str, int | str]] = {}
    allowed_roots = [base.resolve() for base in RESTORE_ALLOWED_DIRS if base.exists() and base.is_dir()]
    for root in allowed_roots:
        rel = _to_rel_path(root)
        try:
            st = root.stat()
        except Exception:
            continue
        desired[rel] = {
            "path": rel,
            "uid": int(st.st_uid),
            "gid": int(st.st_gid),
            "mode": int(st.st_mode & 0o777) or 0o755,
        }

    for fp in files:
        try:
            parent = fp.parent.resolve()
        except Exception:
            continue
        for root in allowed_roots:
            if not _is_subpath(parent, root):
                continue
            cur = parent
            while True:
                rel = _to_rel_path(cur)
                if rel not in desired:
                    try:
                        st = cur.stat()
                    except Exception:
                        break
                    desired[rel] = {
                        "path": rel,
                        "uid": int(st.st_uid),
                        "gid": int(st.st_gid),
                        "mode": int(st.st_mode & 0o777) or 0o755,
                    }
                if cur == root or cur.parent == cur or cur == Path("/"):
                    break
                cur = cur.parent
            break
    return sorted(desired.values(), key=lambda item: str(item["path"]))


def _to_rel_path(path: Path) -> str:
    return str(path).lstrip("/")


def _enforce_retention(directory: Path, keep: int = BACKUP_RETENTION_KEEP) -> list[str]:
    files = [p for p in directory.glob("*.tar.gz") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    failed: list[str] = []
    for old in files[keep:]:
        try:
            old.unlink()
        except Exception:
            failed.append(old.name)
    return failed


def _add_backup_payloads(
    tf: tarfile.TarFile,
    files: list[Path],
) -> tuple[bool, str, list[dict[str, Any]] | None]:
    entries: list[dict[str, Any]] = []
    for fp in files:
        rel = _to_rel_path(fp)
        try:
            st = fp.stat()
            size = int(st.st_size)
            mtime = int(st.st_mtime)
            mode = int(st.st_mode & 0o777) or 0o600
            uid = int(st.st_uid)
            gid = int(st.st_gid)
        except Exception as exc:
            return False, f"Gagal membaca metadata file backup {fp}: {exc}", None

        info = tarfile.TarInfo(f"payload/{rel}")
        info.size = size
        info.mtime = mtime
        info.mode = mode

        try:
            with fp.open("rb") as src:
                reader = _CountingReader(src)
                tf.addfile(info, reader)
                if reader.total_bytes != size:
                    return (
                        False,
                        (
                            f"Ukuran payload berubah saat backup untuk {fp} "
                            f"({reader.total_bytes} != {size})."
                        ),
                        None,
                    )
        except Exception as exc:
            return False, f"Gagal menambahkan file backup {fp}: {exc}", None

        entries.append(
            {
                "path": rel,
                "size_bytes": size,
                "uid": uid,
                "gid": gid,
                "mode": mode,
            }
        )
    return True, "ok", entries


def _create_backup_archive(kind: str) -> tuple[bool, str, dict[str, Any] | None]:
    _ensure_backup_dirs()
    dst_dir = BACKUP_SAFETY_DIR if kind == "safety" else BACKUP_ARCHIVES_DIR
    files = _iter_backup_files()
    if not files:
        return False, "Tidak ada file yang bisa dibackup.", None
    directories = _iter_backup_directories(files)

    backup_id = f"{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S%f')}-{uuid.uuid4().hex[:8]}"
    filename = f"{kind}-backup-{backup_id}.tar.gz"
    archive_path = dst_dir / filename

    try:
        with tarfile.open(archive_path, "w:gz") as tf:
            ok_entries, msg_entries, manifest_entries = _add_backup_payloads(tf, files)
            if not ok_entries or manifest_entries is None:
                raise RuntimeError(msg_entries)

            manifest = {
                "schema_version": BACKUP_SCHEMA_VERSION,
                "backup_id": backup_id,
                "kind": kind,
                "created_at_utc": _now_utc_text(),
                "include_cert": True,
                "include_runtime_env": True,
                "entries": manifest_entries,
                "directories": directories,
            }
            manifest_raw = json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
            info = tarfile.TarInfo("manifest.json")
            info.size = len(manifest_raw)
            info.mtime = int(datetime.now(timezone.utc).timestamp())
            info.mode = 0o600
            tf.addfile(info, io.BytesIO(manifest_raw))
    except Exception as exc:
        try:
            archive_path.unlink(missing_ok=True)
        except Exception:
            pass
        return False, f"Gagal membuat arsip backup: {exc}", None

    _adjust_archive_permissions(archive_path)
    retention_failed_files = _enforce_retention(dst_dir)
    size_bytes = int(archive_path.stat().st_size) if archive_path.exists() else 0
    data = {
        "backup_id": backup_id,
        "kind": kind,
        "archive_path": str(archive_path),
        "archive_filename": archive_path.name,
        "size_bytes": size_bytes,
        "retention_failed_files": retention_failed_files,
    }
    return True, "ok", data


def _is_subpath(path: Path, base: Path) -> bool:
    try:
        rp = path.resolve()
        rb = base.resolve()
    except Exception:
        return False
    return rp == rb or rb in rp.parents


def _is_allowed_restore_target(path: Path) -> bool:
    target = path.resolve()
    for base in RESTORE_ALLOWED_DIRS:
        if _is_subpath(target, base):
            return True
    for file_path in RESTORE_ALLOWED_FILES:
        if target == file_path.resolve():
            return True
    return False


def _normalize_member_name(raw: str) -> tuple[bool, str]:
    name = str(raw or "").strip()
    if not name:
        return False, "Nama member archive kosong."
    p = PurePosixPath(name)
    if p.is_absolute():
        return False, f"Member archive path absolut tidak diizinkan: {name}"
    if ".." in p.parts:
        return False, f"Member archive path traversal terdeteksi: {name}"
    return True, str(p)


def _validate_archive_file(archive_path: Path) -> tuple[bool, str]:
    if not archive_path.exists() or not archive_path.is_file():
        return False, f"File archive tidak ditemukan: {archive_path}"
    if not str(archive_path.name).lower().endswith(".tar.gz"):
        return False, "File restore harus berekstensi .tar.gz"
    return True, "ok"


def _validate_upload_archive_path(upload_path: str) -> tuple[bool, str, Path | None]:
    raw = str(upload_path or "").strip()
    if not raw:
        return False, "upload_path wajib diisi.", None
    p = Path(raw)
    try:
        rp = p.resolve()
    except Exception as exc:
        return False, f"Path upload tidak valid: {exc}", None

    allowed_roots = (UPLOAD_DIR_PRIMARY, UPLOAD_DIR_ALT)
    if not any(_is_subpath(rp, root) for root in allowed_roots):
        return False, "Path upload berada di lokasi yang tidak diizinkan.", None

    ok, msg = _validate_archive_file(rp)
    if not ok:
        return False, msg, None

    size_bytes = int(rp.stat().st_size)
    if size_bytes > MAX_UPLOAD_ARCHIVE_BYTES:
        return (
            False,
            (
                f"Ukuran file upload terlalu besar ({_fmt_size(size_bytes)}). "
                f"Maksimal {_fmt_size(MAX_UPLOAD_ARCHIVE_BYTES)}."
            ),
            None,
        )
    return True, "ok", rp


def _load_and_validate_manifest(
    archive_path: Path,
    *,
    max_member_bytes: int | None = None,
    max_total_bytes: int | None = None,
    max_entries: int | None = None,
) -> tuple[bool, str, dict[str, Any] | None, list[dict[str, Any]] | None]:
    ok_file, msg_file = _validate_archive_file(archive_path)
    if not ok_file:
        return False, msg_file, None, None

    try:
        with tarfile.open(archive_path, "r:gz") as tf:
            payload_members: dict[str, tarfile.TarInfo] = {}
            manifest_member: tarfile.TarInfo | None = None

            for member in tf.getmembers():
                ok_name, name_or_err = _normalize_member_name(member.name)
                if not ok_name:
                    return False, str(name_or_err), None, None
                norm_name = str(name_or_err)
                if norm_name == "manifest.json":
                    manifest_member = member
                    continue
                if member.isfile() and norm_name.startswith("payload/"):
                    rel = norm_name[len("payload/") :].lstrip("/")
                    payload_members[rel] = member

            if manifest_member is None or not manifest_member.isfile():
                return False, "manifest.json tidak ditemukan di archive.", None, None
            if int(manifest_member.size) > MAX_RESTORE_MANIFEST_BYTES:
                return (
                    False,
                    (
                        "manifest.json terlalu besar "
                        f"({_fmt_size(int(manifest_member.size))}); "
                        f"maksimal {_fmt_size(MAX_RESTORE_MANIFEST_BYTES)}."
                    ),
                    None,
                    None,
                )

            raw_manifest = tf.extractfile(manifest_member)
            if raw_manifest is None:
                return False, "manifest.json tidak bisa dibaca.", None, None
            manifest = json.loads(raw_manifest.read().decode("utf-8", errors="ignore"))
            if not isinstance(manifest, dict):
                return False, "manifest.json tidak valid.", None, None
            if int(manifest.get("schema_version") or 0) != BACKUP_SCHEMA_VERSION:
                return False, "Versi manifest tidak didukung.", None, None

            directories_raw = manifest.get("directories")
            directories: list[dict[str, Any]] = []
            if directories_raw is not None:
                if not isinstance(directories_raw, list):
                    return False, "Manifest directories tidak valid.", None, None
                for item in directories_raw:
                    if not isinstance(item, dict):
                        return False, "Manifest directory entry tidak valid.", None, None
                    rel = str(item.get("path") or "").strip().lstrip("/")
                    if not rel:
                        return False, "Directory path kosong pada manifest.", None, None
                    ok_rel, rel_norm_or_err = _normalize_member_name(rel)
                    if not ok_rel:
                        return False, str(rel_norm_or_err), None, None
                    rel_norm = str(rel_norm_or_err)
                    target = Path("/") / rel_norm
                    if not any(_is_subpath(target, base) for base in RESTORE_ALLOWED_DIRS):
                        return False, f"Directory restore tidak diizinkan: /{rel_norm}", None, None
                    normalized_dir: dict[str, Any] = {"path": rel_norm}
                    for key in ("uid", "gid", "mode"):
                        if key not in item:
                            continue
                        try:
                            normalized_dir[key] = int(item.get(key))
                        except Exception:
                            return False, f"{key} tidak valid untuk directory /{rel_norm}", None, None
                    directories.append(normalized_dir)

            entries_raw = manifest.get("entries")
            if not isinstance(entries_raw, list) or not entries_raw:
                return False, "Manifest entries kosong/tidak valid.", None, None
            if max_entries is not None and len(entries_raw) > max_entries:
                return (
                    False,
                    f"Jumlah file restore melebihi batas upload ({len(entries_raw)} > {max_entries}).",
                    None,
                    None,
                )

            entries: list[dict[str, Any]] = []
            total_payload_bytes = 0
            for item in entries_raw:
                if not isinstance(item, dict):
                    return False, "Manifest entry tidak valid.", None, None
                rel = str(item.get("path") or "").strip().lstrip("/")
                try:
                    size = int(item.get("size_bytes"))
                except Exception:
                    return False, f"size_bytes tidak valid untuk {rel}", None, None

                if not rel:
                    return False, "Entry path kosong pada manifest.", None, None
                ok_rel, rel_norm_or_err = _normalize_member_name(rel)
                if not ok_rel:
                    return False, str(rel_norm_or_err), None, None
                rel_norm = str(rel_norm_or_err)
                if rel_norm not in payload_members:
                    return False, f"Payload file tidak ditemukan: {rel_norm}", None, None
                if size < 0:
                    return False, f"Ukuran file tidak valid untuk {rel_norm}", None, None
                if max_member_bytes is not None and size > max_member_bytes:
                    return (
                        False,
                        (
                            f"Ukuran payload {rel_norm} terlalu besar "
                            f"({_fmt_size(size)}); maksimal {_fmt_size(max_member_bytes)}."
                        ),
                        None,
                        None,
                    )

                target = Path("/") / rel_norm
                if not _is_allowed_restore_target(target):
                    return False, f"Path restore tidak diizinkan: /{rel_norm}", None, None

                member = payload_members[rel_norm]
                if int(member.size) != size:
                    return False, f"Ukuran file mismatch untuk {rel_norm}", None, None
                total_payload_bytes += size
                if max_total_bytes is not None and total_payload_bytes > max_total_bytes:
                    return (
                        False,
                        (
                            "Total payload restore melebihi batas upload "
                            f"({_fmt_size(total_payload_bytes)} > {_fmt_size(max_total_bytes)})."
                        ),
                        None,
                        None,
                    )

                fp = tf.extractfile(member)
                if fp is None:
                    return False, f"Gagal membaca payload: {rel_norm}", None, None
                ok_count, count_or_err = _count_reader(fp, expected_size=size)
                if not ok_count:
                    return False, f"Payload {rel_norm} tidak valid: {count_or_err}", None, None

                normalized_entry: dict[str, Any] = {"path": rel_norm, "size_bytes": size}
                for key in ("uid", "gid", "mode"):
                    if key not in item:
                        continue
                    try:
                        normalized_entry[key] = int(item.get(key))
                    except Exception:
                        return False, f"{key} tidak valid untuk {rel_norm}", None, None
                entries.append(normalized_entry)

            manifest_norm = dict(manifest)
            manifest_norm["directories"] = directories
            return True, "ok", manifest_norm, entries
    except Exception as exc:
        return False, f"Gagal membaca archive: {exc}", None, None


def _write_bytes_atomic(path: Path, payload: bytes) -> tuple[bool, str]:
    parent = path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        return False, f"Gagal menyiapkan direktori {parent}: {exc}"

    uid = 0
    gid = 0
    mode = 0o600
    if path.exists():
        try:
            st = path.stat()
            uid = int(st.st_uid)
            gid = int(st.st_gid)
            mode = int(st.st_mode & 0o777)
        except Exception:
            pass

    fd = -1
    tmp_path = ""
    try:
        fd, tmp_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(parent))
        with os.fdopen(fd, "wb") as fp:
            fd = -1
            fp.write(payload)
            fp.flush()
            os.fsync(fp.fileno())
        try:
            os.chmod(tmp_path, mode)
        except Exception:
            pass
        try:
            os.chown(tmp_path, uid, gid)
        except Exception:
            pass
        os.replace(tmp_path, str(path))
    except Exception as exc:
        if fd >= 0:
            try:
                os.close(fd)
            except Exception:
                pass
        if tmp_path:
            try:
                Path(tmp_path).unlink(missing_ok=True)
            except Exception:
                pass
        return False, f"Gagal menulis file {path}: {exc}"
    return True, "ok"


def _count_reader(reader, *, expected_size: int) -> tuple[bool, str]:
    total = 0
    while True:
        chunk = reader.read(STREAM_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > expected_size:
            return False, f"ukuran payload melebihi manifest ({total} > {expected_size})"
    if total != expected_size:
        return False, f"ukuran payload tidak sesuai manifest ({total} != {expected_size})"
    return True, "ok"


def _apply_path_metadata(path: Path, *, uid: int, gid: int, mode: int, kind: str) -> tuple[bool, str]:
    try:
        os.chmod(path, mode)
    except Exception as exc:
        return False, f"Gagal set mode {kind} {path}: {exc}"
    try:
        os.chown(path, uid, gid)
    except Exception as exc:
        return False, f"Gagal set owner {kind} {path}: {exc}"
    return True, "ok"


def _write_stream_atomic(
    path: Path,
    source,
    *,
    expected_size: int,
    restore_uid: int | None = None,
    restore_gid: int | None = None,
    restore_mode: int | None = None,
) -> tuple[bool, str]:
    parent = path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        return False, f"Gagal menyiapkan direktori {parent}: {exc}"

    uid = 0
    gid = 0
    mode = 0o600
    if path.exists():
        try:
            st = path.stat()
            uid = int(st.st_uid)
            gid = int(st.st_gid)
            mode = int(st.st_mode & 0o777)
        except Exception:
            pass
    if isinstance(restore_uid, int):
        uid = restore_uid
    if isinstance(restore_gid, int):
        gid = restore_gid
    if isinstance(restore_mode, int) and restore_mode > 0:
        mode = restore_mode

    fd = -1
    tmp_path = ""
    try:
        fd, tmp_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(parent))
        with os.fdopen(fd, "wb") as fp:
            fd = -1
            total = 0
            while True:
                chunk = source.read(STREAM_CHUNK_BYTES)
                if not chunk:
                    break
                total += len(chunk)
                if total > expected_size:
                    raise ValueError(f"ukuran payload melebihi manifest ({total} > {expected_size})")
                fp.write(chunk)
            if total != expected_size:
                raise ValueError(f"ukuran payload tidak sesuai manifest ({total} != {expected_size})")
            fp.flush()
            os.fsync(fp.fileno())
        os.replace(tmp_path, str(path))
        ok_meta, msg_meta = _apply_path_metadata(path, uid=uid, gid=gid, mode=mode, kind="file restore")
        if not ok_meta:
            return False, msg_meta
    except Exception as exc:
        if fd >= 0:
            try:
                os.close(fd)
            except Exception:
                pass
        if tmp_path:
            try:
                Path(tmp_path).unlink(missing_ok=True)
            except Exception:
                pass
        return False, f"Gagal menulis file {path}: {exc}"
    return True, "ok"


def _iter_existing_restore_files() -> list[Path]:
    out: list[Path] = []
    seen: set[str] = set()
    for base in RESTORE_ALLOWED_DIRS:
        if not base.exists() or not base.is_dir():
            continue
        for fp in sorted(base.rglob("*")):
            if not fp.is_file():
                continue
            key = str(fp.resolve())
            if key in seen:
                continue
            seen.add(key)
            out.append(fp)
    for fp in RESTORE_ALLOWED_FILES:
        if not fp.exists() or not fp.is_file():
            continue
        key = str(fp.resolve())
        if key in seen:
            continue
        seen.add(key)
        out.append(fp)
    return out


def _prune_restore_scope(entries: list[dict[str, Any]]) -> tuple[bool, str]:
    desired: set[Path] = set()
    for item in entries:
        desired.add((Path("/") / str(item["path"])).resolve())

    for fp in _iter_existing_restore_files():
        try:
            if fp.resolve() in desired:
                continue
            fp.unlink()
        except Exception as exc:
            return False, f"Gagal membersihkan file restore stale {fp}: {exc}"

    for base in RESTORE_ALLOWED_DIRS:
        if not base.exists() or not base.is_dir():
            continue
        for d in sorted((p for p in base.rglob("*") if p.is_dir()), reverse=True):
            try:
                d.rmdir()
            except OSError:
                continue
            except Exception as exc:
                return False, f"Gagal membersihkan direktori restore stale {d}: {exc}"
    return True, "ok"


def _apply_directory_metadata(directories: list[dict[str, Any]]) -> tuple[bool, str]:
    for item in directories:
        path = Path("/") / str(item["path"])
        try:
            path.mkdir(parents=True, exist_ok=True)
        except Exception as exc:
            return False, f"Gagal menyiapkan direktori restore {path}: {exc}"
        try:
            st = path.stat()
            uid = int(item["uid"]) if "uid" in item else int(st.st_uid)
            gid = int(item["gid"]) if "gid" in item else int(st.st_gid)
            mode = int(item["mode"]) if "mode" in item else int(st.st_mode & 0o777)
        except Exception as exc:
            return False, f"Gagal membaca metadata direktori restore {path}: {exc}"
        ok_meta, msg_meta = _apply_path_metadata(path, uid=uid, gid=gid, mode=mode, kind="direktori restore")
        if not ok_meta:
            return False, msg_meta
    return True, "ok"


def _apply_archive(
    archive_path: Path,
    entries: list[dict[str, Any]],
    directories: list[dict[str, Any]] | None = None,
) -> tuple[bool, str]:
    try:
        ok_prune, msg_prune = _prune_restore_scope(entries)
        if not ok_prune:
            return False, msg_prune
        with tarfile.open(archive_path, "r:gz") as tf:
            for item in entries:
                rel = str(item["path"])
                size = int(item.get("size_bytes") or 0)
                member = tf.getmember(f"payload/{rel}")
                fp = tf.extractfile(member)
                if fp is None:
                    return False, f"Gagal membaca payload: {rel}"
                dst = Path("/") / rel
                ok_write, msg_write = _write_stream_atomic(
                    dst,
                    fp,
                    expected_size=size,
                    restore_uid=int(item["uid"]) if "uid" in item else None,
                    restore_gid=int(item["gid"]) if "gid" in item else None,
                    restore_mode=int(item["mode"]) if "mode" in item else None,
                )
                if not ok_write:
                    return False, msg_write
        if directories:
            ok_dirs, msg_dirs = _apply_directory_metadata(directories)
            if not ok_dirs:
                return False, msg_dirs
    except Exception as exc:
        return False, f"Gagal apply archive: {exc}"
    return True, "ok"


def _service_exists(name: str) -> bool:
    ok, _ = run_cmd(["systemctl", "status", name], timeout=10)
    if ok:
        return True
    ok_list, out_list = run_cmd(["systemctl", "list-unit-files", f"{name}.service"], timeout=10)
    if not ok_list:
        return False
    return f"{name}.service" in out_list


def _restart_service_checked(
    name: str,
    *,
    required: bool,
    active_only: bool = False,
    must_exist: bool = False,
) -> tuple[bool, str]:
    if not _service_exists(name):
        if required or must_exist:
            return False, f"Service wajib tidak ditemukan: {name}"
        return True, "skip"

    if active_only and not _service_is_active(name):
        return True, "skip"

    ok_restart, out_restart = run_cmd(["systemctl", "restart", name], timeout=40)
    if not ok_restart:
        return False, f"Gagal restart service {name}:\n{out_restart}"

    ok_active, out_active = run_cmd(["systemctl", "is-active", name], timeout=10)
    state = out_active.splitlines()[-1].strip() if out_active else "-"
    if (not ok_active) or state != "active":
        return False, f"Service {name} tidak aktif setelah restart (state={state})."
    return True, "ok"


def _run_post_restore_validation(
    required_active_services: set[str] | None = None,
    optional_active_services: set[str] | None = None,
) -> tuple[bool, str]:
    active_required = set(required_active_services or set())
    active_optional = set(optional_active_services or set())
    for cmd in VALIDATION_COMMANDS:
        ok, out = run_cmd(cmd, timeout=60)
        if not ok:
            return False, f"Validasi gagal: {' '.join(cmd)}\n{out}"

    for svc in REQUIRED_RESTART_SERVICES:
        if active_required and svc not in active_required:
            continue
        ok_service, msg_service = _restart_service_checked(svc, required=True, must_exist=True)
        if not ok_service:
            return False, msg_service

    for svc in OPTIONAL_RESTART_SERVICES:
        if svc not in active_optional:
            continue
        ok_service, msg_service = _restart_service_checked(
            svc,
            required=False,
            active_only=False,
            must_exist=True,
        )
        if not ok_service:
            return False, f"Validasi service optional aktif gagal: {msg_service}"
    return True, "ok"


def _restore_archive_with_safety(
    archive_path: Path,
    source_label: str,
    *,
    upload_limits: bool = False,
) -> tuple[bool, str]:
    manifest_kwargs: dict[str, int] = {}
    if upload_limits:
        manifest_kwargs = {
            "max_member_bytes": MAX_UPLOAD_RESTORE_MEMBER_BYTES,
            "max_total_bytes": MAX_UPLOAD_RESTORE_TOTAL_BYTES,
            "max_entries": MAX_UPLOAD_RESTORE_ENTRIES,
        }

    ok_manifest, msg_manifest, manifest, entries = _load_and_validate_manifest(archive_path, **manifest_kwargs)
    if not ok_manifest or entries is None or manifest is None:
        return False, msg_manifest

    ok_safety, msg_safety, safety_data = _create_backup_archive("safety")
    if not ok_safety or safety_data is None:
        return False, f"Gagal membuat snapshot pra-restore: {msg_safety}"
    safety_path = Path(str(safety_data.get("archive_path") or "")).resolve()
    required_active_services = {
        svc for svc in REQUIRED_RESTART_SERVICES if _service_exists(svc) and _service_is_active(svc)
    }
    optional_active_services = {
        svc for svc in OPTIONAL_RESTART_SERVICES if _service_exists(svc) and _service_is_active(svc)
    }

    ok_apply, msg_apply = _apply_archive(archive_path, entries, list(manifest.get("directories") or []))
    if ok_apply:
        ok_validate, msg_validate = _run_post_restore_validation(required_active_services, optional_active_services)
        if ok_validate:
            lines = [
                f"Restore berhasil dari {source_label}.",
                f"- File dipulihkan: {len(entries)}",
                f"- Snapshot safety: {safety_path.name}",
            ]
            if msg_validate != "ok":
                lines.extend(["", msg_validate])
            return (
                True,
                "\n".join(lines),
            )
        msg_apply = msg_validate

    rb_ok, rb_msg, rb_manifest, rb_entries = _load_and_validate_manifest(safety_path)
    if not rb_ok or rb_entries is None or rb_manifest is None:
        return False, f"Restore gagal: {msg_apply}\nRollback gagal: {rb_msg}"

    rb_apply_ok, rb_apply_msg = _apply_archive(safety_path, rb_entries, list(rb_manifest.get("directories") or []))
    if not rb_apply_ok:
        return False, f"Restore gagal: {msg_apply}\nRollback gagal apply: {rb_apply_msg}"

    rb_validate_ok, rb_validate_msg = _run_post_restore_validation(required_active_services, optional_active_services)
    if not rb_validate_ok:
        return False, f"Restore gagal: {msg_apply}\nRollback gagal validasi: {rb_validate_msg}"

    rollback_msg = (
        f"Restore gagal: {msg_apply}\n"
        f"Rollback otomatis berhasil menggunakan snapshot {safety_path.name}."
    )
    if rb_validate_msg != "ok":
        rollback_msg += f"\nCatatan pasca-rollback:\n{rb_validate_msg}"
    return (
        False,
        rollback_msg,
    )


def op_backup_create() -> tuple[bool, str, str, dict[str, Any] | None]:
    title = "Backup/Restore - Create Backup"
    with file_lock(BACKUP_LOCK_FILE):
        ok, msg, data = _create_backup_archive("manual")
    if not ok or data is None:
        return False, title, msg, None

    size_bytes = int(data.get("size_bytes") or 0)
    filename = str(data.get("archive_filename") or "-")
    archive_path = str(data.get("archive_path") or "")
    result_data = {
        "backup_id": str(data.get("backup_id") or ""),
        "download_local_path": archive_path,
        "download_filename": filename,
        "size_bytes": size_bytes,
        "kind": "manual",
    }
    msg_text = (
        "Backup berhasil dibuat.\n"
        f"- File: {filename}\n"
        f"- Size: {_fmt_size(size_bytes)}\n"
        "- Scope: full + cert + runtime env (tanpa env bot)"
    )
    retention_failed_files = [str(item).strip() for item in (data.get("retention_failed_files") or []) if str(item).strip()]
    if retention_failed_files:
        preview = ", ".join(retention_failed_files[:5])
        if len(retention_failed_files) > 5:
            preview += ", ..."
        msg_text += f"\n- Catatan: retensi belum sepenuhnya bersih ({preview})"
    return True, title, msg_text, result_data


def op_backup_list() -> tuple[bool, str, str]:
    title = "Backup/Restore - List Backups"
    _ensure_backup_dirs()
    files = [p for p in BACKUP_ARCHIVES_DIR.glob("*.tar.gz") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    if not files:
        return True, title, "Belum ada backup lokal."

    lines = [
        f"Total backup lokal: {len(files)}",
        f"Retensi aktif: {BACKUP_RETENTION_KEEP} terbaru",
        "",
        f"{'NO':<4} {'FILE':<44} {'SIZE':<12} {'UPDATED (UTC)':<20}",
        f"{'-'*4:<4} {'-'*44:<44} {'-'*12:<12} {'-'*20:<20}",
    ]
    for idx, fp in enumerate(files[:50], start=1):
        size = _fmt_size(int(fp.stat().st_size))
        updated = datetime.fromtimestamp(fp.stat().st_mtime, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        lines.append(f"{idx:<4} {fp.name[:44]:<44} {size:<12} {updated:<20}")
    return True, title, "\n".join(lines)


def op_restore_latest_local() -> tuple[bool, str, str]:
    title = "Backup/Restore - Restore Latest Local"
    _ensure_backup_dirs()
    files = [p for p in BACKUP_ARCHIVES_DIR.glob("*.tar.gz") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    if not files:
        return False, title, "Belum ada backup lokal untuk direstore."
    latest = files[0]

    with file_lock(BACKUP_LOCK_FILE):
        ok_restore, msg_restore = _restore_archive_with_safety(latest, source_label=f"local:{latest.name}")
    if ok_restore:
        return True, title, msg_restore
    return False, title, msg_restore


def op_restore_from_upload(upload_path: str) -> tuple[bool, str, str]:
    title = "Backup/Restore - Restore From Upload"
    ok_upload, msg_upload, archive_path = _validate_upload_archive_path(upload_path)
    if not ok_upload or archive_path is None:
        return False, title, msg_upload

    ok_restore = False
    msg_restore = "Restore upload tidak dijalankan."
    try:
        with file_lock(BACKUP_LOCK_FILE):
            ok_restore, msg_restore = _restore_archive_with_safety(
                archive_path,
                source_label=f"upload:{archive_path.name}",
                upload_limits=True,
            )
    except Exception as exc:
        ok_restore = False
        msg_restore = f"Restore upload gagal dijalankan: {exc}"

    if ok_restore:
        try:
            archive_path.unlink(missing_ok=True)
        except Exception:
            msg_restore += f"\nCatatan: arsip upload belum terhapus otomatis: {archive_path}"
        return True, title, msg_restore

    return False, title, f"{msg_restore}\nArsip upload dipertahankan di: {archive_path}"

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

CONFIG_ENV_FILE = Path(os.getenv("BACKUP_CLOUD_CONFIG_FILE", "/etc/autoscript/backup/config.env"))
DEFAULT_RCLONE_BIN = os.getenv("BACKUP_RCLONE_BIN", "rclone").strip() or "rclone"
DOWNLOAD_TMP_DIR = Path(os.getenv("BACKUP_DOWNLOAD_TMP_DIR", "/var/lib/autoscript-backup/tmp"))
BACKEND_PATH_CANDIDATES = (
    Path(os.getenv("BOT_BACKEND_ROOT", "/opt/bot-telegram/backend-py")),
    Path("/opt/autoscript/bot-telegram/backend-py"),
    Path("/root/project/autoscript/bot-telegram/backend-py"),
)


def _die(msg: str, code: int = 1) -> int:
    print(msg, file=sys.stderr)
    return code


def _fmt_size(num: int) -> str:
    n = max(0, int(num))
    if n >= 1024**3:
        return f"{n / (1024**3):.2f} GiB"
    if n >= 1024**2:
        return f"{n / (1024**2):.2f} MiB"
    if n >= 1024:
        return f"{n / 1024:.2f} KiB"
    return f"{n} B"


def _fmt_remote_time(raw: str) -> str:
    text = str(raw or "").strip()
    if not text:
        return "-"
    try:
        normalized = text.replace("Z", "+00:00")
        dt = datetime.fromisoformat(normalized)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M")
    except Exception:
        return text[:16].replace("T", " ")


def _load_env_file(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.is_file():
        return data
    try:
        raw = path.read_text(encoding="utf-8")
    except Exception:
        return data
    for line in raw.splitlines():
        text = line.strip()
        if not text or text.startswith("#") or "=" not in text:
            continue
        key, value = text.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        data[key] = value
    return data


def _load_backup_restore():
    for candidate in BACKEND_PATH_CANDIDATES:
        if not candidate.is_dir():
            continue
        path_text = str(candidate)
        if path_text not in sys.path:
            sys.path.insert(0, path_text)
        try:
            from app.adapters import backup_restore as mod  # type: ignore
        except Exception:
            continue
        return mod
    raise RuntimeError("Tidak menemukan backend backup_restore Python.")


backup_restore = _load_backup_restore()


def _rclone_bin(config: dict[str, str]) -> str:
    return (config.get("BACKUP_RCLONE_BIN") or DEFAULT_RCLONE_BIN).strip() or DEFAULT_RCLONE_BIN


def _provider_label(provider: str) -> str:
    return "Google Drive" if provider == "gdrive" else "Cloudflare R2"


def _provider_remote(config: dict[str, str], provider: str) -> str:
    key = "BACKUP_GDRIVE_REMOTE" if provider == "gdrive" else "BACKUP_R2_REMOTE"
    return (config.get(key) or "").strip()


def _provider_remote_name(config: dict[str, str], provider: str) -> str:
    remote = _provider_remote(config, provider)
    if ":" in remote:
        return remote.split(":", 1)[0].strip()
    return remote.strip()


def _rclone_require(config: dict[str, str]) -> str:
    rclone_bin = _rclone_bin(config)
    resolved = shutil.which(rclone_bin)
    if not resolved:
        raise RuntimeError(
            f"rclone tidak ditemukan ({rclone_bin}). Install dulu atau set BACKUP_RCLONE_BIN di {CONFIG_ENV_FILE}."
        )
    return resolved


def _rclone_json(config: dict[str, str], args: list[str]) -> list[dict]:
    rclone_bin = _rclone_require(config)
    proc = subprocess.run(
        [rclone_bin, *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(stderr or "rclone gagal dijalankan.")
    payload = (proc.stdout or "[]").strip() or "[]"
    data = json.loads(payload)
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    raise RuntimeError("Output rclone tidak valid.")


def _rclone_run(config: dict[str, str], args: list[str]) -> str:
    rclone_bin = _rclone_require(config)
    proc = subprocess.run(
        [rclone_bin, *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(stderr or "rclone gagal dijalankan.")
    return (proc.stdout or "").strip()


def _remote_entries(config: dict[str, str], provider: str) -> list[dict]:
    remote = _provider_remote(config, provider)
    if not remote:
        raise RuntimeError(
            f"Remote {_provider_label(provider)} belum dikonfigurasi. Set {'BACKUP_GDRIVE_REMOTE' if provider == 'gdrive' else 'BACKUP_R2_REMOTE'} di {CONFIG_ENV_FILE}."
        )
    entries = _rclone_json(config, ["lsjson", remote, "--files-only"])
    out: list[dict] = []
    for item in entries:
        name = str(item.get("Name") or "").strip()
        if not name.endswith(".tar.gz"):
            continue
        mod_time = str(item.get("ModTime") or "").strip()
        size = int(item.get("Size") or 0)
        out.append({"name": name, "size": size, "mod_time": mod_time})
    out.sort(key=lambda item: str(item.get("mod_time") or ""), reverse=True)
    return out


def _local_latest_archive() -> Path:
    backup_restore._ensure_backup_dirs()
    files = [p for p in backup_restore.BACKUP_ARCHIVES_DIR.glob("*.tar.gz") if p.is_file()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    if not files:
        raise RuntimeError("Belum ada backup lokal.")
    return files[0]


def _create_local_backup() -> tuple[Path, str]:
    ok, title, msg, data = backup_restore.op_backup_create()
    print(title)
    print(msg)
    if not ok or not isinstance(data, dict):
        raise RuntimeError("Gagal membuat backup lokal.")
    archive_path = Path(str(data.get("download_local_path") or "")).resolve()
    if not archive_path.is_file():
        raise RuntimeError("File backup lokal tidak ditemukan setelah create.")
    return archive_path, str(data.get("download_filename") or archive_path.name)


def _upload_archive(config: dict[str, str], provider: str, archive_path: Path) -> None:
    remote = _provider_remote(config, provider)
    if not remote:
        raise RuntimeError(
            f"Remote {_provider_label(provider)} belum dikonfigurasi di {CONFIG_ENV_FILE}."
        )
    _rclone_run(config, ["copyto", str(archive_path), f"{remote.rstrip('/')}/{archive_path.name}"])


def _preflight_cloud_remote(config: dict[str, str], provider: str) -> None:
    remote = _provider_remote(config, provider)
    if not remote:
        raise RuntimeError(
            f"Remote {_provider_label(provider)} belum dikonfigurasi di {CONFIG_ENV_FILE}."
        )
    if provider == "gdrive":
        remote_name = _provider_remote_name(config, provider)
        if not remote_name:
            raise RuntimeError(
                f"Remote {_provider_label(provider)} belum dikonfigurasi di {CONFIG_ENV_FILE}."
            )
        _rclone_run(config, ["about", f"{remote_name}:"])
        return
    _rclone_run(config, ["lsf", remote])


def _download_latest_remote(config: dict[str, str], provider: str) -> tuple[Path, dict]:
    remote = _provider_remote(config, provider)
    entries = _remote_entries(config, provider)
    if not entries:
        raise RuntimeError(f"Belum ada arsip remote di {_provider_label(provider)}.")
    latest = entries[0]
    DOWNLOAD_TMP_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=f"{provider}-backup-", suffix=".tar.gz", dir=str(DOWNLOAD_TMP_DIR))
    os.close(fd)
    target = Path(tmp_path)
    _rclone_run(
        config,
        ["copyto", f"{remote.rstrip('/')}/{latest['name']}", str(target)],
    )
    return target, latest


def _validate_archive_name(name: str) -> str:
    archive_name = str(name or "").strip()
    if not archive_name:
        raise RuntimeError("Nama arsip backup wajib diisi.")
    if "/" in archive_name or "\\" in archive_name or archive_name in {".", ".."}:
        raise RuntimeError("Nama arsip backup tidak valid.")
    if not archive_name.endswith(".tar.gz"):
        raise RuntimeError("Nama arsip harus berekstensi .tar.gz.")
    return archive_name


def _validate_archive_index(index_value: str | int) -> int:
    raw = str(index_value or "").strip()
    if not raw:
        raise RuntimeError("Nomor backup wajib diisi.")
    try:
        index = int(raw)
    except Exception:
        raise RuntimeError("Nomor backup harus berupa angka.")
    if index <= 0:
        raise RuntimeError("Nomor backup harus lebih dari 0.")
    return index


def _find_remote_entry(config: dict[str, str], provider: str, archive_name: str) -> dict:
    wanted = _validate_archive_name(archive_name)
    for item in _remote_entries(config, provider):
        if str(item.get("name") or "").strip() == wanted:
            return item
    raise RuntimeError(f"Arsip remote tidak ditemukan: {wanted}")


def _find_remote_entry_by_index(config: dict[str, str], provider: str, archive_index: str | int) -> dict:
    wanted = _validate_archive_index(archive_index)
    entries = _remote_entries(config, provider)
    if wanted > len(entries):
        raise RuntimeError(f"Nomor backup tidak ditemukan: {wanted}")
    return entries[wanted - 1]


def _download_selected_remote(
    config: dict[str, str],
    provider: str,
    *,
    archive_name: str | None = None,
    archive_index: str | int | None = None,
) -> tuple[Path, dict]:
    remote = _provider_remote(config, provider)
    entry = (
        _find_remote_entry_by_index(config, provider, archive_index)
        if archive_index not in (None, "")
        else _find_remote_entry(config, provider, str(archive_name or ""))
    )
    DOWNLOAD_TMP_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=f"{provider}-backup-", suffix=".tar.gz", dir=str(DOWNLOAD_TMP_DIR))
    os.close(fd)
    target = Path(tmp_path)
    _rclone_run(config, ["copyto", f"{remote.rstrip('/')}/{entry['name']}", str(target)])
    return target, entry


def _delete_selected_remote(
    config: dict[str, str],
    provider: str,
    *,
    archive_name: str | None = None,
    archive_index: str | int | None = None,
) -> dict:
    remote = _provider_remote(config, provider)
    entry = (
        _find_remote_entry_by_index(config, provider, archive_index)
        if archive_index not in (None, "")
        else _find_remote_entry(config, provider, str(archive_name or ""))
    )
    _rclone_run(config, ["deletefile", f"{remote.rstrip('/')}/{entry['name']}"])
    return entry


def cmd_local_list(_args: argparse.Namespace) -> int:
    ok, title, msg = backup_restore.op_backup_list()
    print(title)
    print(msg)
    return 0 if ok else 1


def cmd_local_create(_args: argparse.Namespace) -> int:
    try:
        _create_local_backup()
        return 0
    except Exception as exc:
        return _die(str(exc))


def cmd_local_restore_latest(_args: argparse.Namespace) -> int:
    ok, title, msg = backup_restore.op_restore_latest_local()
    print(title)
    print(msg)
    return 0 if ok else 1


def cmd_local_restore_domain_latest(_args: argparse.Namespace) -> int:
    ok, title, msg = backup_restore.op_restore_latest_local_domain_refresh()
    print(title)
    print(msg)
    return 0 if ok else 1


def cmd_local_restore_file(args: argparse.Namespace) -> int:
    archive = Path(args.path).expanduser().resolve()
    if not archive.is_file():
        return _die(f"Arsip restore tidak ditemukan: {archive}")
    with backup_restore.file_lock(backup_restore.BACKUP_LOCK_FILE):
        ok, msg = backup_restore._restore_archive_with_safety(archive, source_label=f"local:{archive.name}")
    print("Backup/Restore - Restore Local File")
    print(msg)
    return 0 if ok else 1


def cmd_local_restore_domain_file(args: argparse.Namespace) -> int:
    archive = Path(args.path).expanduser().resolve()
    if not archive.is_file():
        return _die(f"Arsip restore tidak ditemukan: {archive}")
    with backup_restore.file_lock(backup_restore.BACKUP_LOCK_FILE):
        ok, msg = backup_restore._restore_domain_refresh_from_archive(archive, source_label=f"local:{archive.name}")
    print("Backup/Restore - Restore Local Domain Only")
    print(msg)
    return 0 if ok else 1


def cmd_cloud_status(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    remote = _provider_remote(config, args.provider)
    rclone_bin = _rclone_bin(config)
    rclone_ok = shutil.which(rclone_bin) is not None
    print(f"Provider      : {_provider_label(args.provider)}")
    print(f"Config        : {CONFIG_ENV_FILE}")
    print(f"Rclone Bin    : {rclone_bin}")
    print(f"Rclone Ready  : {'yes' if rclone_ok else 'no'}")
    print(f"Remote Target : {remote or '(belum diisi)'}")
    print("")
    print("Contoh remote:")
    if args.provider == "gdrive":
        print("  BACKUP_GDRIVE_REMOTE=\"gdrive:autoscript-backups\"")
    else:
        print("  BACKUP_R2_REMOTE=\"r2:autoscript\"")
    return 0


def cmd_cloud_help(_args: argparse.Namespace) -> int:
    provider = str(getattr(_args, "provider", "") or "").strip().lower()
    print("Backup/Restore - Cloud Setup Help")
    print("")
    print(f"Config file: {CONFIG_ENV_FILE}")
    print("")
    if provider == "gdrive":
        print("Provider: Google Drive")
        print("")
        print("Prerequisites:")
        print("- rclone sudah terpasang")
        print("- akun Google Drive siap dipakai")
        print("- OAuth Google bisa diselesaikan")
        print("")
        print("Langkah Setup:")
        print("1. Jalankan: rclone config")
        print("2. Buat remote baru, misalnya: gdrive")
        print("3. Tipe backend: drive")
        print("4. Selesaikan OAuth Google sampai remote bisa diakses")
        print("5. Siapkan folder target di Drive bila perlu")
        print("6. Isi config env berikut")
        print("")
        print("Contoh Config:")
        print('BACKUP_GDRIVE_REMOTE="gdrive:autoscript-backups"')
        print("")
        print("Catatan Penting:")
        print("- Google Drive cocok untuk akun personal.")
        print("- Setup awal lebih ribet di VPS headless karena OAuth.")
        return 0
    if provider == "r2":
        print("Provider: Cloudflare R2")
        print("")
        print("Prerequisites:")
        print("- rclone sudah terpasang")
        print("- bucket R2 sudah ada atau siap dibuat")
        print("- Access Key ID dan Secret Access Key R2 tersedia")
        print("")
        print("Langkah Setup:")
        print("1. Jalankan: rclone config")
        print("2. Buat remote baru, misalnya: r2")
        print("3. Tipe backend: s3")
        print("4. Provider: Cloudflare")
        print("5. Isi Access Key ID dan Secret Access Key R2")
        print("6. Isi endpoint berikut")
        print("   https://<ACCOUNT_ID>.r2.cloudflarestorage.com")
        print("7. Isi config env berikut")
        print("")
        print("Contoh Config:")
        print('BACKUP_R2_REMOTE="r2:autoscript"')
        print("")
        print("Catatan Penting:")
        print("- R2 lebih cocok untuk backup server/object storage.")
        print("- Biasanya butuh billing/payment method Cloudflare.")
        return 0
    print("1. Siapkan rclone remote lebih dulu.")
    print("   - Google Drive: rclone config")
    print("   - Cloudflare R2: rclone config")
    print("")
    print("2. Isi config env:")
    print('   BACKUP_GDRIVE_REMOTE="gdrive:autoscript-backups"')
    print('   BACKUP_R2_REMOTE="r2:autoscript"')
    print("")
    print("3. Flow yang disarankan:")
    print("   - Google Drive: local backup + upload/sync")
    print("   - Cloudflare R2: create local backup + upload + restore dari remote bila perlu")
    return 0


def cmd_cloud_list(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    try:
        entries = _remote_entries(config, args.provider)
    except Exception as exc:
        return _die(str(exc))
    print(f"Backup/Restore - List Remote ({_provider_label(args.provider)})")
    if not entries:
        print("Belum ada arsip remote.")
        return 0
    print(f"Total arsip remote: {len(entries)}")
    print("")
    print(f"{'NO':<4} {'FILE':<44} {'SIZE':<12} {'UPDATED (UTC)':<24}")
    print(f"{'-'*4:<4} {'-'*44:<44} {'-'*12:<12} {'-'*24:<24}")
    for idx, item in enumerate(entries[:50], start=1):
        print(f"{idx:<4} {item['name'][:44]:<44} {_fmt_size(item['size']):<12} {_fmt_remote_time(item['mod_time']):<24}")
    return 0


def cmd_cloud_test(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    try:
        _preflight_cloud_remote(config, args.provider)
    except Exception as exc:
        return _die(str(exc))
    print(f"Backup/Restore - Test Remote ({_provider_label(args.provider)})")
    print("Remote cloud siap diakses.")
    print(f"- Target : {_provider_remote(config, args.provider)}")
    return 0


def cmd_cloud_upload_latest(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    try:
        archive = _local_latest_archive()
        _upload_archive(config, args.provider, archive)
    except Exception as exc:
        return _die(str(exc))
    print(f"Upload ke {_provider_label(args.provider)} berhasil.")
    print(f"- File   : {archive.name}")
    print(f"- Target : {_provider_remote(config, args.provider)}")
    return 0


def cmd_cloud_create_upload(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    try:
        _preflight_cloud_remote(config, args.provider)
        archive, _ = _create_local_backup()
        _upload_archive(config, args.provider, archive)
    except Exception as exc:
        return _die(str(exc))
    print("")
    print(f"Upload ke {_provider_label(args.provider)} berhasil.")
    print(f"- File   : {archive.name}")
    print(f"- Target : {_provider_remote(config, args.provider)}")
    return 0


def cmd_cloud_restore_latest(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    archive_path: Path | None = None
    try:
        archive_path, latest = _download_latest_remote(config, args.provider)
        with backup_restore.file_lock(backup_restore.BACKUP_LOCK_FILE):
            ok, msg = backup_restore._restore_archive_with_safety(
                archive_path,
                source_label=f"{args.provider}:{latest['name']}",
            )
        print(f"Backup/Restore - Restore Latest Remote ({_provider_label(args.provider)})")
        print(msg)
        return 0 if ok else 1
    except Exception as exc:
        return _die(str(exc))
    finally:
        if archive_path is not None:
            try:
                archive_path.unlink(missing_ok=True)
            except Exception:
                pass


def cmd_cloud_restore_domain_latest(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    archive_path: Path | None = None
    try:
        archive_path, latest = _download_latest_remote(config, args.provider)
        with backup_restore.file_lock(backup_restore.BACKUP_LOCK_FILE):
            ok, msg = backup_restore._restore_domain_refresh_from_archive(
                archive_path,
                source_label=f"{args.provider}:{latest['name']}",
            )
        print(f"Backup/Restore - Restore Latest Remote Domain Only ({_provider_label(args.provider)})")
        print(msg)
        return 0 if ok else 1
    except Exception as exc:
        return _die(str(exc))
    finally:
        if archive_path is not None:
            try:
                archive_path.unlink(missing_ok=True)
            except Exception:
                pass


def cmd_cloud_restore_file(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    archive_path: Path | None = None
    try:
        archive_path, entry = _download_selected_remote(
            config,
            args.provider,
            archive_name=getattr(args, "name", None),
            archive_index=getattr(args, "index", None),
        )
        with backup_restore.file_lock(backup_restore.BACKUP_LOCK_FILE):
            ok, msg = backup_restore._restore_archive_with_safety(
                archive_path,
                source_label=f"{args.provider}:{entry['name']}",
            )
        print(f"Backup/Restore - Restore Selected Remote ({_provider_label(args.provider)})")
        print(msg)
        return 0 if ok else 1
    except Exception as exc:
        return _die(str(exc))
    finally:
        if archive_path is not None:
            try:
                archive_path.unlink(missing_ok=True)
            except Exception:
                pass


def cmd_cloud_restore_domain_file(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    archive_path: Path | None = None
    try:
        archive_path, entry = _download_selected_remote(
            config,
            args.provider,
            archive_name=getattr(args, "name", None),
            archive_index=getattr(args, "index", None),
        )
        with backup_restore.file_lock(backup_restore.BACKUP_LOCK_FILE):
            ok, msg = backup_restore._restore_domain_refresh_from_archive(
                archive_path,
                source_label=f"{args.provider}:{entry['name']}",
            )
        print(f"Backup/Restore - Restore Selected Remote Domain Only ({_provider_label(args.provider)})")
        print(msg)
        return 0 if ok else 1
    except Exception as exc:
        return _die(str(exc))
    finally:
        if archive_path is not None:
            try:
                archive_path.unlink(missing_ok=True)
            except Exception:
                pass


def cmd_cloud_delete_file(args: argparse.Namespace) -> int:
    config = _load_env_file(CONFIG_ENV_FILE)
    try:
        entry = _delete_selected_remote(
            config,
            args.provider,
            archive_name=getattr(args, "name", None),
            archive_index=getattr(args, "index", None),
        )
    except Exception as exc:
        return _die(str(exc))
    print(f"Backup/Restore - Delete Remote ({_provider_label(args.provider)})")
    print("Arsip cloud berhasil dihapus.")
    print(f"- File   : {entry['name']}")
    print(f"- Target : {_provider_remote(config, args.provider)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage backup/restore local + cloud backends.")
    sub = parser.add_subparsers(dest="group", required=True)

    local = sub.add_parser("local")
    local_sub = local.add_subparsers(dest="action", required=True)
    local_sub.add_parser("list").set_defaults(func=cmd_local_list)
    local_sub.add_parser("create").set_defaults(func=cmd_local_create)
    local_sub.add_parser("restore-latest").set_defaults(func=cmd_local_restore_latest)
    local_sub.add_parser("restore-domain-latest").set_defaults(func=cmd_local_restore_domain_latest)
    local_restore_file = local_sub.add_parser("restore-file")
    local_restore_file.add_argument("path")
    local_restore_file.set_defaults(func=cmd_local_restore_file)
    local_restore_domain_file = local_sub.add_parser("restore-domain-file")
    local_restore_domain_file.add_argument("path")
    local_restore_domain_file.set_defaults(func=cmd_local_restore_domain_file)

    cloud = sub.add_parser("cloud")
    cloud_sub = cloud.add_subparsers(dest="action", required=True)

    for action_name, handler in (
        ("status", cmd_cloud_status),
        ("test", cmd_cloud_test),
        ("list", cmd_cloud_list),
        ("upload-latest", cmd_cloud_upload_latest),
        ("create-upload", cmd_cloud_create_upload),
        ("restore-latest", cmd_cloud_restore_latest),
        ("restore-domain-latest", cmd_cloud_restore_domain_latest),
    ):
        p = cloud_sub.add_parser(action_name)
        p.add_argument("--provider", choices=("gdrive", "r2"), required=True)
        p.set_defaults(func=handler)

    cloud_restore_file = cloud_sub.add_parser("restore-file")
    cloud_restore_file.add_argument("--provider", choices=("gdrive", "r2"), required=True)
    cloud_restore_file.add_argument("--name")
    cloud_restore_file.add_argument("--index", type=int)
    cloud_restore_file.set_defaults(func=cmd_cloud_restore_file)

    cloud_restore_domain_file = cloud_sub.add_parser("restore-domain-file")
    cloud_restore_domain_file.add_argument("--provider", choices=("gdrive", "r2"), required=True)
    cloud_restore_domain_file.add_argument("--name")
    cloud_restore_domain_file.add_argument("--index", type=int)
    cloud_restore_domain_file.set_defaults(func=cmd_cloud_restore_domain_file)

    cloud_delete_file = cloud_sub.add_parser("delete-file")
    cloud_delete_file.add_argument("--provider", choices=("gdrive", "r2"), required=True)
    cloud_delete_file.add_argument("--name")
    cloud_delete_file.add_argument("--index", type=int)
    cloud_delete_file.set_defaults(func=cmd_cloud_delete_file)

    cloud_help = cloud_sub.add_parser("help")
    cloud_help.add_argument("--provider", choices=("gdrive", "r2"))
    cloud_help.set_defaults(func=cmd_cloud_help)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())

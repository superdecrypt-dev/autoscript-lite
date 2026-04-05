import os
import stat
import shutil
import subprocess
from pathlib import Path

import base64
import json
from configparser import RawConfigParser

from ..adapters import backup_restore
from ..utils.response import error_response, ok_response
from ..utils.validators import require_param

BACKUP_MANAGE_BIN = os.getenv("BACKUP_MANAGE_BIN", "/usr/local/bin/backup-manage")
BACKUP_CLOUD_CONFIG_FILE = Path(os.getenv("BACKUP_CLOUD_CONFIG_FILE", "/etc/autoscript/backup/config.env"))
RCLONE_CONFIG_FILE = Path(os.getenv("RCLONE_CONFIG_FILE", "/root/.config/rclone/rclone.conf"))
DEFAULT_GDRIVE_REMOTE = "gdrive"
DEFAULT_GDRIVE_FOLDER = "autoscript-backups"
DEFAULT_R2_REMOTE = "r2"
DEFAULT_R2_BUCKET = "autoscript"
BACKUP_MANAGE_TIMEOUT_SECONDS = max(30, int(os.getenv("BACKUP_MANAGE_TIMEOUT_SECONDS", "480") or "480"))


def _backup_manage_path() -> str:
    if os.path.isabs(BACKUP_MANAGE_BIN):
        return BACKUP_MANAGE_BIN
    return shutil.which(BACKUP_MANAGE_BIN) or BACKUP_MANAGE_BIN


def _path_chain_trusted(path: Path) -> bool:
    try:
        resolved = path.resolve(strict=True)
    except Exception:
        return False
    if os.geteuid() != 0:
        return True

    current = resolved
    while True:
        try:
            st = os.lstat(current)
        except Exception:
            return False
        if stat.S_ISLNK(st.st_mode):
            return False
        if st.st_uid != 0:
            return False
        if st.st_mode & stat.S_IWGRP or st.st_mode & stat.S_IWOTH:
            return False
        if current == Path("/"):
            break
        parent = current.parent
        if parent == current:
            return False
        current = parent
    return True


def _trusted_backup_manage_path() -> tuple[str | None, str]:
    candidate = Path(_backup_manage_path())
    if not candidate.is_absolute():
        return None, f"Helper backup-manage tidak ditemukan: {candidate}"
    if not candidate.exists() or not candidate.is_file():
        return None, f"Helper backup-manage tidak ditemukan: {candidate}"
    if not os.access(candidate, os.X_OK):
        return None, f"Helper backup-manage tidak executable: {candidate}"
    if not _path_chain_trusted(candidate):
        return None, (
            "Helper backup-manage tidak trusted. "
            "Pastikan owner root, bukan symlink, dan tidak writable oleh group/other."
        )
    return str(candidate), ""


def _run_backup_manage(title: str, args: list[str], *, error_code: str) -> dict:
    helper, helper_err = _trusted_backup_manage_path()
    if not helper:
        return error_response(error_code, title, helper_err)
    try:
        proc = subprocess.run(
            [helper, *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=BACKUP_MANAGE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return error_response(
            error_code,
            title,
            (
                "Helper backup-manage timeout. "
                f"Batas saat ini: {BACKUP_MANAGE_TIMEOUT_SECONDS} detik."
            ),
        )
    stdout = (proc.stdout or "").strip()
    stderr = (proc.stderr or "").strip()
    message = stdout or stderr or "Tidak ada output."
    if proc.returncode == 0:
        return ok_response(title, message)
    return error_response(error_code, title, message)


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


def _save_env_value(key: str, value: str) -> None:
    current = _load_env_file(BACKUP_CLOUD_CONFIG_FILE)
    current.setdefault("BACKUP_RCLONE_BIN", "rclone")
    current.setdefault("BACKUP_GDRIVE_REMOTE", "")
    current.setdefault("BACKUP_R2_REMOTE", "")
    current[key] = value
    BACKUP_CLOUD_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f'BACKUP_RCLONE_BIN="{current.get("BACKUP_RCLONE_BIN", "rclone")}"',
        f'BACKUP_GDRIVE_REMOTE="{current.get("BACKUP_GDRIVE_REMOTE", "")}"',
        f'BACKUP_R2_REMOTE="{current.get("BACKUP_R2_REMOTE", "")}"',
    ]
    BACKUP_CLOUD_CONFIG_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _rclone_bin() -> str:
    config = _load_env_file(BACKUP_CLOUD_CONFIG_FILE)
    wanted = (config.get("BACKUP_RCLONE_BIN") or "rclone").strip() or "rclone"
    return shutil.which(wanted) or wanted


def _run_rclone(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [_rclone_bin(), *args],
        check=False,
        capture_output=True,
        text=True,
    )


def _rclone_has_remote(remote: str) -> bool:
    if not remote or not RCLONE_CONFIG_FILE.is_file():
        return False
    parser = RawConfigParser()
    try:
        parser.read(RCLONE_CONFIG_FILE, encoding="utf-8")
    except Exception:
        return False
    return parser.has_section(remote)


def _ensure_rclone_available(title: str) -> dict | None:
    if shutil.which(_rclone_bin()):
        return None
    return error_response(
        "rclone_not_found",
        title,
        f"rclone tidak ditemukan. Install dulu atau set BACKUP_RCLONE_BIN di {BACKUP_CLOUD_CONFIG_FILE}.",
    )


def _friendly_rclone_error(raw: str, *, provider: str, remote: str, action: str) -> str:
    text = (raw or "").strip()
    lower = text.lower()
    if not RCLONE_CONFIG_FILE.is_file():
        return f"Konfigurasi rclone belum ada. Setup {provider} dulu sebelum {action.lower()}."
    if remote and not _rclone_has_remote(remote):
        return f"Remote {provider} '{remote}' belum dibuat di rclone. Jalankan setup dulu."
    if "didn't find section in config file" in lower or "didnt find section in config file" in lower:
        return f"Remote {provider} '{remote}' belum dibuat di rclone. Jalankan setup dulu."
    if "config file" in lower and "not found" in lower:
        return f"Konfigurasi rclone belum ada. Setup {provider} dulu sebelum {action.lower()}."
    if "403" in lower or "access denied" in lower or "unauthorized" in lower:
        return f"Remote {provider} '{remote}' belum bisa diakses. Cek kredensial atau izin bucket/folder."
    if "empty token found" in lower or "config reconnect" in lower or "reconnect " in lower:
        return f"Remote {provider} '{remote}' belum punya JSON auth yang valid. Jalankan setup atau reconnect remote dulu."
    if "token" in lower and "invalid" in lower:
        return f"Token OAuth {provider} tidak valid. Paste token baru lalu coba lagi."
    if "directory not found" in lower or "object not found" in lower:
        return f"Target {provider} belum ditemukan. Cek nama bucket/folder atau selesaikan setup dulu."
    return text or f"Remote {provider} belum bisa diakses."


def _read_rclone_value(remote: str, key: str) -> str:
    if not RCLONE_CONFIG_FILE.is_file():
        return ""
    parser = RawConfigParser()
    try:
        parser.read(RCLONE_CONFIG_FILE, encoding="utf-8")
    except Exception:
        return ""
    if parser.has_section(remote) and parser.has_option(remote, key):
        return str(parser.get(remote, key) or "").strip()
    return ""


def _snapshot_rclone_config() -> str | None:
    if not RCLONE_CONFIG_FILE.is_file():
        return None
    try:
        return RCLONE_CONFIG_FILE.read_text(encoding="utf-8")
    except Exception:
        return None


def _restore_rclone_config(snapshot: str | None) -> None:
    RCLONE_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    if snapshot is None:
        try:
            RCLONE_CONFIG_FILE.unlink(missing_ok=True)
        except Exception:
            pass
        return
    RCLONE_CONFIG_FILE.write_text(snapshot, encoding="utf-8")


def _write_rclone_config(mutator) -> tuple[bool, str]:
    try:
        RCLONE_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        parser = RawConfigParser()
        if RCLONE_CONFIG_FILE.is_file():
            parser.read(RCLONE_CONFIG_FILE, encoding="utf-8")
        mutator(parser)
        with RCLONE_CONFIG_FILE.open("w", encoding="utf-8") as fh:
            parser.write(fh)
        RCLONE_CONFIG_FILE.chmod(0o600)
        return True, ""
    except Exception as exc:
        return False, str(exc)


def _normalize_drive_token_input(token_input: str) -> tuple[bool, str]:
    raw = str(token_input or "").strip()
    if not raw:
        return False, "JSON auth Google Drive kosong."
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            if "access_token" in parsed:
                return True, json.dumps(parsed, ensure_ascii=False, separators=(",", ":"))
            wrapped = parsed.get("token")
            if isinstance(wrapped, str) and wrapped.strip():
                inner = json.loads(wrapped)
                if isinstance(inner, dict) and "access_token" in inner:
                    return True, json.dumps(inner, ensure_ascii=False, separators=(",", ":"))
    except Exception:
        pass
    try:
        pad = "=" * ((4 - len(raw) % 4) % 4)
        decoded = base64.urlsafe_b64decode(raw + pad).decode("utf-8")
        parsed = json.loads(decoded)
        if isinstance(parsed, dict):
            wrapped = parsed.get("token")
            if isinstance(wrapped, str) and wrapped.strip():
                inner = json.loads(wrapped)
                if isinstance(inner, dict) and "access_token" in inner:
                    return True, json.dumps(inner, ensure_ascii=False, separators=(",", ":"))
    except Exception:
        pass
    return False, "Format auth Google Drive tidak dikenali. Tempel JSON auth mentah atau blob hasil rclone authorize."


def _save_rclone_drive_token(remote: str, token_json: str) -> tuple[bool, str]:
    ok_norm, token = _normalize_drive_token_input(token_json)
    if not ok_norm:
        return False, token
    snapshot = _snapshot_rclone_config()
    ok, err = _write_rclone_config(
        lambda parser: (
            parser.add_section(remote) if not parser.has_section(remote) else None,
            parser.set(remote, "type", "drive"),
            parser.set(remote, "scope", "drive"),
            parser.set(remote, "token", token),
        )
    )
    if not ok:
        _restore_rclone_config(snapshot)
        return False, err or "Gagal menyimpan JSON auth Google Drive."
    return True, ""


def _verify_gdrive_remote(remote: str, folder: str) -> tuple[bool, str]:
    about = _run_rclone(["about", f"{remote}:"])
    if about.returncode != 0:
        return False, _friendly_rclone_error(
            (about.stderr or about.stdout or ""),
            provider="Google Drive",
            remote=remote,
            action="verifikasi remote",
        )
    _run_rclone(["mkdir", f"{remote}:{folder}"])
    return True, ""


def _apply_gdrive_existing_remote(remote: str, folder: str) -> tuple[bool, str]:
    ok, msg = _verify_gdrive_remote(remote, folder)
    if not ok:
        return False, msg
    _save_env_value("BACKUP_GDRIVE_REMOTE", f"{remote}:{folder}")
    return True, ""


def _apply_r2_setup(remote: str, account_id: str, bucket: str, access_key: str, secret_key: str) -> tuple[bool, str]:
    snapshot = _snapshot_rclone_config()
    previous_target = _load_env_file(BACKUP_CLOUD_CONFIG_FILE).get("BACKUP_R2_REMOTE", "")
    ok, err = _write_rclone_config(
        lambda parser: (
            parser.add_section(remote) if not parser.has_section(remote) else None,
            parser.set(remote, "type", "s3"),
            parser.set(remote, "provider", "Cloudflare"),
            parser.set(remote, "access_key_id", access_key),
            parser.set(remote, "secret_access_key", secret_key),
            parser.set(remote, "endpoint", f"https://{account_id}.r2.cloudflarestorage.com"),
            parser.set(remote, "region", "auto"),
            parser.set(remote, "no_check_bucket", "true"),
        )
    )
    if not ok:
        return False, err or "Gagal membuat konfigurasi R2."
    _save_env_value("BACKUP_R2_REMOTE", f"{remote}:{bucket}")
    check = _run_rclone(["lsf", f"{remote}:{bucket}"])
    if check.returncode != 0:
        _restore_rclone_config(snapshot)
        _save_env_value("BACKUP_R2_REMOTE", previous_target)
        return False, _friendly_rclone_error(
            (check.stderr or check.stdout or ""),
            provider="Cloudflare R2",
            remote=remote,
            action="verifikasi remote",
        )
    return True, ""


def _gdrive_state() -> tuple[str, str]:
    remote_target = _load_env_file(BACKUP_CLOUD_CONFIG_FILE).get("BACKUP_GDRIVE_REMOTE", "").strip()
    if ":" in remote_target:
        remote, folder = remote_target.split(":", 1)
        return remote.strip() or DEFAULT_GDRIVE_REMOTE, folder.strip() or DEFAULT_GDRIVE_FOLDER
    return remote_target.strip() or DEFAULT_GDRIVE_REMOTE, DEFAULT_GDRIVE_FOLDER


def _r2_state() -> tuple[str, str, str]:
    remote_target = _load_env_file(BACKUP_CLOUD_CONFIG_FILE).get("BACKUP_R2_REMOTE", "").strip()
    remote = DEFAULT_R2_REMOTE
    bucket = DEFAULT_R2_BUCKET
    if ":" in remote_target:
        remote, bucket = remote_target.split(":", 1)
        remote = remote.strip() or DEFAULT_R2_REMOTE
        bucket = bucket.strip() or DEFAULT_R2_BUCKET
    elif remote_target:
        remote = remote_target
    endpoint = _read_rclone_value(remote, "endpoint")
    account_id = ""
    prefix = "https://"
    suffix = ".r2.cloudflarestorage.com"
    if endpoint.startswith(prefix) and endpoint.endswith(suffix):
        account_id = endpoint[len(prefix) : -len(suffix)]
    return remote, bucket, account_id


def _vps_host_hint() -> str:
    for key in ("PUBLIC_IPV4", "SERVER_IP", "PUBLIC_IP"):
        value = str(os.getenv(key, "")).strip()
        if value:
            return value
    try:
        proc = subprocess.run(
            ["bash", "-lc", "curl -4fsSL https://ipv4.icanhazip.com || hostname -I | awk '{print $1}'"],
            check=False,
            capture_output=True,
            text=True,
        )
        hint = (proc.stdout or "").strip()
        if hint:
            return hint.splitlines()[0].strip()
    except Exception:
        pass
    return "IP_VPS"


def handle(action: str, params: dict, settings) -> dict:
    if action == "list_backups":
        ok, title, msg = backup_restore.op_backup_list()
        if ok:
            return ok_response(title, msg)
        return error_response("backup_list_failed", title, msg)

    if action == "create_backup":
        ok, title, msg, data = backup_restore.op_backup_create()
        if ok:
            return ok_response(title, msg, data=data if isinstance(data, dict) else None)
        return error_response("backup_create_failed", title, msg)

    if action == "restore_latest":
        ok, title, msg = backup_restore.op_restore_latest_local()
        if ok:
            return ok_response(title, msg)
        return error_response("backup_restore_latest_failed", title, msg)

    if action == "restore_latest_domain_only":
        ok, title, msg = backup_restore.op_restore_latest_local_domain_refresh()
        if ok:
            return ok_response(title, msg)
        return error_response("backup_restore_latest_domain_only_failed", title, msg)

    if action == "restore_from_upload":
        ok_param, upload_or_err = require_param(params, "upload_path", "Backup/Restore - Restore Upload")
        if not ok_param:
            return upload_or_err
        ok, title, msg = backup_restore.op_restore_from_upload(str(upload_or_err))
        if ok:
            return ok_response(title, msg, data={"cleanup_upload_archive": True})
        return error_response("backup_restore_upload_failed", title, msg, data={"keep_upload_archive": True})

    if action == "restore_upload_domain_only":
        ok_param, upload_or_err = require_param(params, "upload_path", "Backup/Restore - Restore Upload Domain Only")
        if not ok_param:
            return upload_or_err
        ok, title, msg = backup_restore.op_restore_from_upload_domain_refresh(str(upload_or_err))
        if ok:
            return ok_response(title, msg, data={"cleanup_upload_archive": True})
        return error_response("backup_restore_upload_domain_only_failed", title, msg, data={"keep_upload_archive": True})

    if action == "gdrive_show_oauth_steps":
        remote, folder = _gdrive_state()
        title = "Backup/Restore - Google Drive - Setup"
        tunnel_host = _vps_host_hint()
        return ok_response(
            title,
            "\n".join(
                [
                    "Setup default:",
                    f"  Remote Name : {remote}",
                    f"  Folder Name : {folder}",
                    "",
                    "Opsi A. Termux langsung:",
                    "  1. Jalankan: apt update && apt upgrade",
                    "  2. Install rclone: apt install rclone -y",
                    "  3. Jalankan command ini:",
                    '    rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"',
                    "  4. Login Google lalu copy hasil auth yang muncul",
                    "     - bisa berupa JSON auth mentah",
                    "     - atau satu baris panjang setelah kembali ke rclone",
                    "  5. Kembali ke sini lalu pilih 'Paste JSON Auth Google'",
                    "",
                    "Opsi B. VPS + SSH tunnel:",
                    "  1. Di VPS jalankan command ini:",
                    '    rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"',
                    "  2. Copy URL lokal yang muncul",
                    "     contoh: http://127.0.0.1:53682/auth?state=**********",
                    "  3. Di Termux jalankan tunnel ini:",
                    f"    ssh -L 53682:127.0.0.1:53682 root@{tunnel_host}",
                    "  4. Buka URL tadi di browser HP",
                    "  5. Login Google lalu copy hasil auth yang muncul",
                    "     - bisa berupa JSON auth mentah",
                    "     - atau satu baris panjang setelah kembali ke rclone",
                    "  6. Kembali ke sini lalu pilih 'Paste JSON Auth Google'",
                    "",
                    "Setelah JSON auth didapat:",
                    "  1. Tempel ke menu 'Paste JSON Auth Google'",
                    "     - boleh JSON auth mentah atau blob panjang dari rclone",
                    "  2. Setelah berhasil, pilih 'Use Existing Remote'",
                    "  3. Cek kesiapan di menu 'Status Config'",
                    "",
                    "Catatan:",
                    "  - jika port 53682 sudah terpakai: pkill -f rclone",
                    "  - jika tunnel menampilkan zombie process, itu normal selama koneksi SSH tetap aktif",
                ]
            ),
            data={"render_mode": "account_info"},
        )

    if action == "gdrive_paste_oauth_token":
        title = "Backup/Restore - Google Drive - Paste JSON Auth"
        ok_param, token_or_err = require_param(params, "token_json", title)
        if not ok_param:
            return token_or_err
        remote = str(params.get("remote_name") or "").strip() or _gdrive_state()[0]
        folder = str(params.get("folder_name") or "").strip() or _gdrive_state()[1]
        ok, msg = _save_rclone_drive_token(remote, str(token_or_err))
        if not ok:
            return error_response("gdrive_token_save_failed", title, msg)
        ok, msg = _apply_gdrive_existing_remote(remote, folder)
        if not ok:
            return error_response("gdrive_remote_verify_failed", title, msg)
        return ok_response(title, f"Google Drive siap dipakai.\n- Remote : {remote}\n- Folder : {folder}")

    if action == "gdrive_quick_setup":
        title = "Backup/Restore - Google Drive - Quick Setup"
        ok_param, token_or_err = require_param(params, "token_json", title)
        if not ok_param:
            return token_or_err
        remote = str(params.get("remote_name") or "").strip() or _gdrive_state()[0]
        folder = str(params.get("folder_name") or "").strip() or _gdrive_state()[1]
        ok, msg = _save_rclone_drive_token(remote, str(token_or_err))
        if not ok:
            return error_response("gdrive_quick_setup_failed", title, msg)
        ok, msg = _apply_gdrive_existing_remote(remote, folder)
        if not ok:
            return error_response("gdrive_remote_verify_failed", title, msg)
        return ok_response(title, f"Google Drive siap dipakai.\n- Remote : {remote}\n- Folder : {folder}")

    if action == "gdrive_use_existing_remote":
        title = "Backup/Restore - Google Drive - Use Existing Remote"
        remote = str(params.get("remote_name") or "").strip() or _gdrive_state()[0]
        folder = str(params.get("folder_name") or "").strip() or _gdrive_state()[1]
        ok, msg = _apply_gdrive_existing_remote(remote, folder)
        if not ok:
            return error_response("gdrive_remote_verify_failed", title, msg)
        return ok_response(title, f"Google Drive siap dipakai.\n- Remote : {remote}\n- Folder : {folder}")

    if action == "gdrive_manual_rclone_config":
        return ok_response(
            "Backup/Restore - Google Drive - Manual rclone config",
            "\n".join(
                [
                    "Langkah manual:",
                    "1. Jalankan `rclone config` di server.",
                    "2. Buat remote tipe `drive`, misalnya `gdrive`.",
                    "3. Selesaikan OAuth sampai remote bisa diakses.",
                    f'4. Pastikan config env memakai target seperti `BACKUP_GDRIVE_REMOTE=\"{DEFAULT_GDRIVE_REMOTE}:{DEFAULT_GDRIVE_FOLDER}\"`.',
                    "5. Setelah remote siap, gunakan `Use Existing Remote` di bot.",
                ]
            ),
        )

    if action == "r2_quick_setup":
        title = "Backup/Restore - Cloudflare R2 - Quick Setup"
        required_keys = ("account_id", "bucket_name", "access_key_id", "secret_access_key")
        extracted: dict[str, str] = {}
        for key in required_keys:
            ok_param, value_or_err = require_param(params, key, title)
            if not ok_param:
                return value_or_err
            extracted[key] = str(value_or_err).strip()
        remote = str(params.get("remote_name") or "").strip() or _r2_state()[0]
        ok, msg = _apply_r2_setup(
            remote,
            extracted["account_id"],
            extracted["bucket_name"],
            extracted["access_key_id"],
            extracted["secret_access_key"],
        )
        if not ok:
            return error_response("r2_quick_setup_failed", title, msg)
        return ok_response(
            title,
            f"Cloudflare R2 siap dipakai.\n- Remote : {remote}\n- Bucket : {extracted['bucket_name']}\n- Account ID : {extracted['account_id']}",
        )

    if action == "r2_manual_rclone_config":
        remote, bucket, _account_id = _r2_state()
        return ok_response(
            "Backup/Restore - Cloudflare R2 - Manual rclone config",
            "\n".join(
                [
                    "Langkah manual:",
                    "1. Jalankan `rclone config` di server.",
                    "2. Buat remote tipe `s3` dengan provider `Cloudflare`.",
                    "3. Isi Access Key ID, Secret Access Key, dan endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.",
                    f'4. Pastikan config env memakai target seperti `BACKUP_R2_REMOTE=\"{remote}:{bucket}\"`.',
                    "5. Setelah remote siap, gunakan `Status Config` atau `Create & Upload Backup` di bot.",
                ]
            ),
        )

    if action == "r2_setup_help":
        remote, bucket, account_id = _r2_state()
        return ok_response(
            "Backup/Restore - Cloudflare R2 - Setup",
            "\n".join(
                [
                    "Tujuan setup ini:",
                    f"- Remote Name : {remote}",
                    f"- Bucket Name : {bucket}",
                    f"- Account ID  : {account_id or '<belum diisi>'}",
                    "",
                    "Tutorial setup Cloudflare R2:",
                    "1. Login ke dashboard Cloudflare lalu buka R2 Object Storage.",
                    "2. Siapkan 4 data ini:",
                    "   - Account ID",
                    "   - Bucket Name",
                    "   - Access Key ID",
                    "   - Secret Access Key",
                    "3. Di bot, buka Cloudflare R2 -> Setup -> Quick Setup R2.",
                    "4. Isi Remote Name bila ingin pakai nama selain default `r2`.",
                    "5. Isi Account ID sesuai akun Cloudflare yang dipakai.",
                    "6. Isi Bucket Name sesuai bucket target backup.",
                    "7. Isi Access Key ID dan Secret Access Key.",
                    "8. Submit modal itu sampai bot menyimpan konfigurasi.",
                    "",
                    "Yang dilakukan bot saat setup:",
                    "9. Bot membuat / memperbarui remote rclone tipe S3 untuk provider Cloudflare.",
                    "10. Bot mengarahkan endpoint ke https://<ACCOUNT_ID>.r2.cloudflarestorage.com",
                    "11. Bot memverifikasi akses ke target bucket sebelum menyimpan env aktif.",
                    "",
                    "Verifikasi setelah setup:",
                    f"12. Jalankan di SSH bila ingin cek manual: rclone lsf {remote}:{bucket}",
                    f"13. Buka Cloudflare R2 -> Status Config di bot dan pastikan target terbaca sebagai {remote}:{bucket}.",
                    "",
                    "Setelah itu kamu bisa pakai:",
                    "14. Create & Upload Backup",
                    "15. List Cloud Backups",
                    "16. Restore Latest Cloud Backup",
                    "",
                    "Catatan:",
                    "- R2 lebih cocok untuk backup server/object storage.",
                    "- Biasanya butuh billing/payment method Cloudflare.",
                    "- Jika token dibatasi ke bucket tertentu, cek root remote bisa gagal tetapi bucket target tetap normal.",
                ]
            ),
            data={"render_mode": "account_info"},
        )

    cloud_action_map = {
        "gdrive_setup_help": ("Backup/Restore - Google Drive - Setup", ["cloud", "help", "--provider", "gdrive"], "gdrive_setup_help_failed"),
        "gdrive_status": ("Backup/Restore - Google Drive - Status", ["cloud", "status", "--provider", "gdrive"], "gdrive_status_failed"),
        "gdrive_test_remote": ("Backup/Restore - Google Drive - Test Remote", ["cloud", "test", "--provider", "gdrive"], "gdrive_test_remote_failed"),
        "gdrive_create_upload": ("Backup/Restore - Google Drive - Create & Upload", ["cloud", "create-upload", "--provider", "gdrive"], "gdrive_create_upload_failed"),
        "gdrive_list_backups": ("Backup/Restore - Google Drive - List Cloud Backups", ["cloud", "list", "--provider", "gdrive"], "gdrive_list_failed"),
        "gdrive_restore_latest": ("Backup/Restore - Google Drive - Restore Latest Cloud Backup", ["cloud", "restore-latest", "--provider", "gdrive"], "gdrive_restore_latest_failed"),
        "gdrive_restore_domain_latest": (
            "Backup/Restore - Google Drive - Restore Latest Domain Only",
            ["cloud", "restore-domain-latest", "--provider", "gdrive"],
            "gdrive_restore_domain_latest_failed",
        ),
        "gdrive_restore_select": (
            "Backup/Restore - Google Drive - Restore Select Backup",
            ["cloud", "restore-file", "--provider", "gdrive", "--index", str(params.get("archive_no") or params.get("archive_name") or "")],
            "gdrive_restore_select_failed",
        ),
        "gdrive_restore_domain_select": (
            "Backup/Restore - Google Drive - Restore Select Domain Only",
            ["cloud", "restore-domain-file", "--provider", "gdrive", "--name", str(params.get("archive_name") or "")],
            "gdrive_restore_domain_select_failed",
        ),
        "gdrive_delete_backup": (
            "Backup/Restore - Google Drive - Delete Cloud Backup",
            ["cloud", "delete-file", "--provider", "gdrive", "--index", str(params.get("archive_no") or params.get("archive_name") or "")],
            "gdrive_delete_backup_failed",
        ),
        "r2_status": ("Backup/Restore - Cloudflare R2 - Status", ["cloud", "status", "--provider", "r2"], "r2_status_failed"),
        "r2_test_remote": ("Backup/Restore - Cloudflare R2 - Test Remote", ["cloud", "test", "--provider", "r2"], "r2_test_remote_failed"),
        "r2_create_upload": ("Backup/Restore - Cloudflare R2 - Create & Upload", ["cloud", "create-upload", "--provider", "r2"], "r2_create_upload_failed"),
        "r2_list_backups": ("Backup/Restore - Cloudflare R2 - List Cloud Backups", ["cloud", "list", "--provider", "r2"], "r2_list_failed"),
        "r2_restore_latest": ("Backup/Restore - Cloudflare R2 - Restore Latest Cloud Backup", ["cloud", "restore-latest", "--provider", "r2"], "r2_restore_latest_failed"),
        "r2_restore_domain_latest": (
            "Backup/Restore - Cloudflare R2 - Restore Latest Domain Only",
            ["cloud", "restore-domain-latest", "--provider", "r2"],
            "r2_restore_domain_latest_failed",
        ),
        "r2_restore_select": (
            "Backup/Restore - Cloudflare R2 - Restore Select Backup",
            ["cloud", "restore-file", "--provider", "r2", "--index", str(params.get("archive_no") or params.get("archive_name") or "")],
            "r2_restore_select_failed",
        ),
        "r2_restore_domain_select": (
            "Backup/Restore - Cloudflare R2 - Restore Select Domain Only",
            ["cloud", "restore-domain-file", "--provider", "r2", "--name", str(params.get("archive_name") or "")],
            "r2_restore_domain_select_failed",
        ),
        "r2_delete_backup": (
            "Backup/Restore - Cloudflare R2 - Delete Cloud Backup",
            ["cloud", "delete-file", "--provider", "r2", "--index", str(params.get("archive_no") or params.get("archive_name") or "")],
            "r2_delete_backup_failed",
        ),
    }
    if action in cloud_action_map:
        title, cmd_args, error_code = cloud_action_map[action]
        return _run_backup_manage(title, cmd_args, error_code=error_code)

    return error_response("unknown_action", "Backup/Restore", f"Action tidak dikenal: {action}")

#!/usr/bin/env bash
# shellcheck shell=bash

backup_cli_helper_bin() {
  printf '%s\n' "/usr/local/bin/backup-manage"
}

backup_cloud_config_file() {
  printf '%s\n' "/etc/autoscript/backup/config.env"
}

backup_config_get_value() {
  local key="$1"
  local cfg
  cfg="$(backup_cloud_config_file)"
  [[ -n "${key}" && -f "${cfg}" ]] || return 1
  awk -F= -v wanted="${key}" '
    $1 == wanted {
      v=$2
      sub(/^"/, "", v)
      sub(/"$/, "", v)
      print v
      exit
    }
  ' "${cfg}"
}

backup_cli_require_helper() {
  local helper
  helper="$(backup_cli_helper_bin)"
  if [[ ! -x "${helper}" ]]; then
    warn "Helper backup CLI tidak ditemukan / tidak executable:"
    echo "  ${helper}"
    echo
    echo "Hint: jalankan ulang setup.sh atau sync runtime agar backup-manage ikut terpasang."
    hr
    pause
    return 1
  fi
  if declare -F manage_bootstrap_path_trusted >/dev/null 2>&1 && ! manage_bootstrap_path_trusted "${helper}"; then
    warn "Helper backup CLI tidak trusted:"
    echo "  ${helper}"
    echo
    echo "Hint: pastikan owner root, bukan symlink, dan tidak writable oleh group/other."
    hr
    pause
    return 1
  fi
  return 0
}

backup_rclone_require() {
  if have_cmd rclone; then
    return 0
  fi
  warn "rclone belum terpasang."
  echo "Hint: jalankan setup.sh ulang atau install manual: apt-get install -y rclone"
  hr
  pause
  return 1
}

backup_cli_exec() {
  local menu_title="$1"
  shift || true
  local helper cmd rc
  helper="$(backup_cli_helper_bin)"
  ui_menu_screen_begin "${menu_title}"
  backup_cli_require_helper || return 0
  cmd=( "${helper}" "$@" )
  set +e
  "${cmd[@]}"
  rc=$?
  set -e
  hr
  if (( rc != 0 )); then
    warn "Command backup keluar dengan status error (${rc})."
  fi
  pause
  return "${rc}"
}

backup_cli_show_cloud_list() {
  local provider="$1"
  local helper rc output
  helper="$(backup_cli_helper_bin)"
  backup_cli_require_helper || return 1
  set +e
  output="$("${helper}" cloud list --provider "${provider}" 2>&1)"
  rc=$?
  set -e
  [[ -n "${output}" ]] && printf '%s\n' "${output}"
  if (( rc != 0 )); then
    hr
    warn "Gagal memuat daftar backup cloud."
    echo "Hint: periksa remote cloud dengan menu 'Status Config' atau 'Test Remote'."
    hr
    pause
    return 1
  fi
  if grep -Fq "Belum ada arsip remote." <<<"${output}"; then
    hr
    warn "Belum ada backup cloud yang bisa dipilih."
    echo "Hint: buat atau upload backup dulu sebelum memakai menu select/delete."
    hr
    pause
    return 1
  fi
  return 0
}

backup_config_set_value() {
  local key="$1"
  local value="$2"
  local cfg
  cfg="$(backup_cloud_config_file)"
  [[ -n "${key}" ]] || return 1
  mkdir -p "$(dirname "${cfg}")" 2>/dev/null || true
  if [[ ! -f "${cfg}" ]]; then
    cat > "${cfg}" <<'EOF'
BACKUP_RCLONE_BIN="rclone"
BACKUP_GDRIVE_REMOTE=""
BACKUP_R2_REMOTE=""
EOF
  fi
  python3 - <<'PY' "${cfg}" "${key}" "${value}"
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines()
out = []
found = False
for line in lines:
    if line.startswith(f"{key}="):
        out.append(f'{key}="{value}"')
        found = True
    else:
        out.append(line)
if not found:
    out.append(f'{key}="{value}"')
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

backup_rclone_remote_ok() {
  local remote="$1"
  [[ -n "${remote}" ]] || return 1
  rclone about "${remote}:" >/dev/null 2>&1
}

backup_rclone_target_ok() {
  local target="$1"
  [[ -n "${target}" ]] || return 1
  rclone lsf "${target}" >/dev/null 2>&1
}

backup_rclone_config_snapshot_make() {
  local cfg tmp
  cfg="$(backup_rclone_config_path)"
  tmp="$(mktemp)"
  if [[ -f "${cfg}" ]]; then
    cp -f "${cfg}" "${tmp}"
  else
    : > "${tmp}"
  fi
  printf '%s\n' "${tmp}"
}

backup_rclone_config_snapshot_restore() {
  local snapshot="$1"
  local cfg
  cfg="$(backup_rclone_config_path)"
  mkdir -p "$(dirname "${cfg}")" 2>/dev/null || true
  if [[ -s "${snapshot}" ]]; then
    cp -f "${snapshot}" "${cfg}"
  else
    rm -f "${cfg}" 2>/dev/null || true
  fi
}

backup_trim() {
  local raw="${1-}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s\n' "${raw}"
}

backup_vps_host_hint() {
  local ip=""
  ip="$(curl -4fsSL https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "${ip}" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${ip}" ]] || ip="IP_VPS"
  printf '%s\n' "${ip}"
}

backup_provider_remote_target() {
  local provider="$1"
  if [[ "${provider}" == "gdrive" ]]; then
    backup_config_get_value "BACKUP_GDRIVE_REMOTE" || true
  else
    backup_config_get_value "BACKUP_R2_REMOTE" || true
  fi
}

backup_provider_ready_status() {
  local provider="$1"
  local target remote
  target="$(backup_provider_remote_target "${provider}")"
  [[ -n "${target}" ]] || { printf '%s\n' "NOT READY"; return 0; }
  remote="${target%%:*}"
  [[ -n "${remote}" ]] || { printf '%s\n' "NOT READY"; return 0; }
  if ! have_cmd rclone; then
    printf '%s\n' "NOT READY"
    return 0
  fi
  if backup_rclone_target_ok "${target}"; then
    printf '%s\n' "READY"
  elif backup_rclone_remote_ok "${remote}"; then
    printf '%s\n' "READY"
  else
    printf '%s\n' "NOT READY"
  fi
}

backup_provider_status_summary() {
  local provider="$1"
  local target status
  target="$(backup_provider_remote_target "${provider}")"
  status="$(backup_provider_ready_status "${provider}")"
  printf '%s|%s\n' "${status}" "${target}"
}

backup_rclone_config_path() {
  printf '%s\n' "/root/.config/rclone/rclone.conf"
}

backup_rclone_upsert_drive_remote() {
  local remote="$1"
  local token_input="$2"
  local cfg
  cfg="$(backup_rclone_config_path)"
  [[ -n "${remote}" && -n "${token_input}" ]] || return 1
  mkdir -p "$(dirname "${cfg}")" 2>/dev/null || true
  printf '%s' "${token_input}" | python3 -c '
from pathlib import Path
import configparser
import base64
import json
import sys

cfg_path = Path(sys.argv[1])
remote = sys.argv[2]
token_input = sys.stdin.read().strip()


def normalize_token(raw: str) -> str:
    if not raw:
        raise ValueError("token OAuth kosong")
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            if "access_token" in parsed:
                return json.dumps(parsed, ensure_ascii=False, separators=(",", ":"))
            wrapped = parsed.get("token")
            if isinstance(wrapped, str) and wrapped.strip():
                inner = json.loads(wrapped)
                if isinstance(inner, dict) and "access_token" in inner:
                    return json.dumps(inner, ensure_ascii=False, separators=(",", ":"))
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
                    return json.dumps(inner, ensure_ascii=False, separators=(",", ":"))
    except Exception:
        pass
    raise ValueError("format token Google Drive tidak dikenali")


token_json = normalize_token(token_input)
parser = configparser.RawConfigParser()
if cfg_path.exists():
    parser.read(cfg_path, encoding="utf-8")
if not parser.has_section(remote):
    parser.add_section(remote)
parser.set(remote, "type", "drive")
parser.set(remote, "scope", "drive")
parser.set(remote, "token", token_json)
with cfg_path.open("w", encoding="utf-8") as fh:
    parser.write(fh)
cfg_path.chmod(0o600)
' "${cfg}" "${remote}"
}

backup_rclone_upsert_r2_remote() {
  local remote="$1"
  local account_id="$2"
  local access_key="$3"
  local secret_key="$4"
  local cfg
  cfg="$(backup_rclone_config_path)"
  [[ -n "${remote}" && -n "${account_id}" && -n "${access_key}" && -n "${secret_key}" ]] || return 1
  mkdir -p "$(dirname "${cfg}")" 2>/dev/null || true
  printf '%s\0%s\0%s' "${account_id}" "${access_key}" "${secret_key}" | python3 -c '
from pathlib import Path
import configparser
import sys

cfg_path = Path(sys.argv[1])
remote = sys.argv[2]
parts = sys.stdin.buffer.read().split(b"\0")
if len(parts) < 3:
    raise SystemExit(1)
account_id, access_key, secret_key = [item.decode("utf-8").strip() for item in parts[:3]]
parser = configparser.RawConfigParser()
if cfg_path.exists():
    parser.read(cfg_path, encoding="utf-8")
if not parser.has_section(remote):
    parser.add_section(remote)
parser.set(remote, "type", "s3")
parser.set(remote, "provider", "Cloudflare")
parser.set(remote, "access_key_id", access_key)
parser.set(remote, "secret_access_key", secret_key)
parser.set(remote, "endpoint", f"https://{account_id}.r2.cloudflarestorage.com")
parser.set(remote, "region", "auto")
parser.set(remote, "no_check_bucket", "true")
with cfg_path.open("w", encoding="utf-8") as fh:
    parser.write(fh)
cfg_path.chmod(0o600)
' "${cfg}" "${remote}"
}

backup_rclone_section_value() {
  local remote="$1"
  local key="$2"
  local cfg
  cfg="$(backup_rclone_config_path)"
  [[ -n "${remote}" && -n "${key}" && -f "${cfg}" ]] || return 1
  python3 - <<'PY' "${cfg}" "${remote}" "${key}"
from pathlib import Path
import configparser
import sys

cfg = Path(sys.argv[1])
section = sys.argv[2]
key = sys.argv[3]
parser = configparser.RawConfigParser()
parser.read(cfg, encoding="utf-8")
if parser.has_section(section) and parser.has_option(section, key):
    print(parser.get(section, key))
PY
}

backup_split_remote_target() {
  local target="$1"
  BACKUP_SPLIT_REMOTE=""
  BACKUP_SPLIT_PATH=""
  [[ -n "${target}" ]] || return 0
  BACKUP_SPLIT_REMOTE="${target%%:*}"
  if [[ "${target}" == *:* ]]; then
    BACKUP_SPLIT_PATH="${target#*:}"
  fi
}

backup_gdrive_load_existing_state() {
  local target
  target="$(backup_provider_remote_target "gdrive")"
  backup_split_remote_target "${target}"
  BACKUP_GDRIVE_REMOTE_NAME="${BACKUP_SPLIT_REMOTE:-gdrive}"
  BACKUP_GDRIVE_FOLDER_NAME="${BACKUP_SPLIT_PATH:-autoscript-backups}"
}

backup_r2_load_existing_state() {
  local target endpoint
  target="$(backup_provider_remote_target "r2")"
  backup_split_remote_target "${target}"
  BACKUP_R2_REMOTE_NAME="${BACKUP_SPLIT_REMOTE:-r2}"
  BACKUP_R2_BUCKET_NAME="${BACKUP_SPLIT_PATH:-autoscript}"
  BACKUP_R2_ACCOUNT_ID=""
  endpoint="$(backup_rclone_section_value "${BACKUP_R2_REMOTE_NAME}" endpoint 2>/dev/null || true)"
  if [[ "${endpoint}" =~ ^https://([a-zA-Z0-9]+)\.r2\.cloudflarestorage\.com/?$ ]]; then
    BACKUP_R2_ACCOUNT_ID="${BASH_REMATCH[1]}"
  fi
}

backup_gdrive_setup_apply_existing_remote() {
  local remote="$1"
  local folder="$2"
  if ! backup_rclone_remote_ok "${remote}"; then
    warn "Remote Google Drive ${remote}: belum bisa diakses."
    echo "Pastikan remote sudah selesai OAuth dan bisa dipakai."
    return 1
  fi
  rclone mkdir "${remote}:${folder}" >/dev/null 2>&1 || true
  backup_config_set_value "BACKUP_GDRIVE_REMOTE" "${remote}:${folder}"
  return 0
}

backup_cli_rclone_config_menu() {
  ui_menu_screen_begin "10) Tools > Backup/Restore > rclone config"
  echo "Command ini akan membuka konfigurasi rclone interaktif."
  echo "Remote yang dipakai autoscript saat ini:"
  echo "  - Google Drive  -> gdrive"
  echo "  - Cloudflare R2 -> r2"
  hr
  if ! confirm_menu_apply_now "Jalankan rclone config sekarang?"; then
    pause
    return 0
  fi
  if ! have_cmd rclone; then
    warn "rclone belum terpasang."
    pause
    return 0
  fi
  rclone config || warn "rclone config keluar dengan status error."
  hr
  pause
  return 0
}

backup_gdrive_setup_menu() {
  local remote folder
  local token_json="" c tunnel_host
  while true; do
    backup_gdrive_load_existing_state
    remote="${BACKUP_GDRIVE_REMOTE_NAME}"
    folder="${BACKUP_GDRIVE_FOLDER_NAME}"
    tunnel_host="$(backup_vps_host_hint)"
    # shellcheck disable=SC2034
    local -a items=(
      "1|Paste OAuth Token JSON"
      "2|Use Existing Remote"
      "3|Manual rclone config"
      "0|Back"
    )
    ui_menu_screen_begin "10) Tools > Backup/Restore > Google Drive > Setup"
    echo "Setup default:"
    echo "  Remote Name : ${remote}"
    echo "  Folder Name : ${folder}"
    hr
    echo "Tutorial setup Google Drive:"
    echo "  Opsi A. Termux langsung:"
    echo "    1. Jalankan: apt update && apt upgrade"
    echo "    2. Install rclone: apt install rclone -y"
    echo '    3. Jalankan: rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"'
    echo "    4. Login Google lalu copy hasil auth yang muncul"
    echo "       - bisa berupa JSON auth mentah"
    echo "       - atau satu baris panjang setelah kembali ke rclone"
    echo "    5. Kembali ke sini lalu pilih 'Paste OAuth Token JSON'"
    echo
    echo "  Opsi B. VPS + port forwarding:"
    echo '    1. Di VPS jalankan: rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"'
    echo "    2. Copy URL lokal yang muncul"
    echo "       contoh: http://127.0.0.1:53682/auth?state=**********"
    echo "    3. Jalankan port forwarding ke VPS dengan tool pilihan Anda"
    echo "       lalu arahkan 127.0.0.1:53682 ke ${tunnel_host}:53682"
    echo "    4. Buka URL tadi di browser HP"
    echo "    5. Login Google lalu copy hasil auth yang muncul"
    echo "       - bisa berupa JSON auth mentah"
    echo "       - atau satu baris panjang setelah kembali ke rclone"
    echo "    6. Kembali ke sini lalu pilih 'Paste OAuth Token JSON'"
    echo
    echo "  Setelah token didapat:"
    echo "    1. Tempel ke menu 'Paste OAuth Token JSON'"
    echo "       - boleh JSON auth mentah atau blob panjang dari rclone"
    echo "    2. Setelah berhasil, pilih 'Use Existing Remote'"
    echo "    3. Cek kesiapan di menu 'Status Config'"
    echo
    echo "  Catatan:"
    echo "    - jika port 53682 sudah terpakai: pkill -f rclone"
    echo "    - jika sesi port forwarding menampilkan zombie process, itu normal selama koneksi tetap aktif"
    hr
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1)
        backup_rclone_require || continue
        ui_menu_screen_begin "10) Tools > Backup/Restore > Google Drive > Setup > Paste Token"
        echo "Tempel hasil auth Google Drive satu baris, lalu Enter."
        echo "Bisa berupa JSON auth mentah atau blob panjang yang muncul setelah kembali ke rclone."
        echo "Ketik 'kembali' lalu Enter untuk batal dan kembali ke menu setup."
        hr
        token_json=""
        local cancel_input="0"
        if ! read -r -s token_json; then
          echo
        fi
        echo
        token_json="${token_json%$'\r'}"
        token_json="$(backup_trim "${token_json}")"
        if is_back_choice "${token_json}" || [[ "${token_json}" == "CANCEL" ]]; then
          cancel_input="1"
          token_json=""
        fi
        if [[ -z "${token_json}" ]]; then
          if [[ "${cancel_input}" == "1" ]]; then
            warn "Input token dibatalkan. Kembali ke menu setup."
          else
            warn "Tidak ada token yang disimpan. Kembali ke menu setup."
          fi
          pause
          continue
        fi
        local snapshot=""
        snapshot="$(backup_rclone_config_snapshot_make)" || {
          warn "Gagal membuat snapshot konfigurasi rclone."
          pause
          continue
        }
        if ! backup_rclone_upsert_drive_remote "${remote}" "${token_json}"; then
          backup_rclone_config_snapshot_restore "${snapshot}"
          rm -f "${snapshot}" 2>/dev/null || true
          warn "Gagal menyimpan JSON auth Google Drive."
          pause
          continue
        fi
        if backup_gdrive_setup_apply_existing_remote "${remote}" "${folder}"; then
          log "Google Drive siap dipakai: ${remote}:${folder}"
        else
          backup_rclone_config_snapshot_restore "${snapshot}"
          warn "JSON auth tersimpan, tetapi remote belum bisa diverifikasi. Konfigurasi dipulihkan."
        fi
        rm -f "${snapshot}" 2>/dev/null || true
        pause
        ;;
      2)
        backup_rclone_require || continue
        if backup_gdrive_setup_apply_existing_remote "${remote}" "${folder}"; then
          log "Google Drive siap dipakai: ${remote}:${folder}"
        else
          warn "Remote ${remote}: belum siap dipakai."
        fi
        pause
        ;;
      3)
        backup_cli_rclone_config_menu
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

backup_r2_apply_setup() {
  local remote="$1"
  local account_id="$2"
  local bucket="$3"
  local access_key="$4"
  local secret_key="$5"
  local snapshot=""
  local previous_target=""
  [[ -n "${account_id}" && -n "${bucket}" && -n "${access_key}" && -n "${secret_key}" ]] || return 1
  previous_target="$(backup_config_get_value "BACKUP_R2_REMOTE" || true)"
  snapshot="$(backup_rclone_config_snapshot_make)" || return 1
  if ! backup_rclone_upsert_r2_remote "${remote}" "${account_id}" "${access_key}" "${secret_key}"; then
    rm -f "${snapshot}" 2>/dev/null || true
    return 1
  fi
  backup_config_set_value "BACKUP_R2_REMOTE" "${remote}:${bucket}"
  if ! backup_rclone_target_ok "${remote}:${bucket}"; then
    backup_rclone_config_snapshot_restore "${snapshot}"
    backup_config_set_value "BACKUP_R2_REMOTE" "${previous_target}"
    rm -f "${snapshot}" 2>/dev/null || true
    return 1
  fi
  rm -f "${snapshot}" 2>/dev/null || true
  return 0
}

backup_r2_review_menu() {
  local remote="$1"
  local account_id="$2"
  local bucket="$3"
  local access_key="$4"
  local secret_key="$5"
  local c=""
  BACKUP_R2_REVIEW_ACTION="back"
  while true; do
    # shellcheck disable=SC2034
    local -a items=(
      "1|Apply"
      "2|Edit Again"
      "0|Back"
    )
    ui_menu_screen_begin "10) Tools > Backup/Restore > Cloudflare R2 > Setup > Review"
    echo "Review setup Cloudflare R2:"
    echo "  Remote Name       : ${remote}"
    echo "  Account ID        : ${account_id:-<belum diisi>}"
    echo "  Bucket Name       : ${bucket:-<belum diisi>}"
    echo "  Access Key ID     : $( [[ -n "${access_key}" ]] && echo "<sudah diisi>" || echo "<belum diisi>" )"
    echo "  Secret Access Key : $( [[ -n "${secret_key}" ]] && echo "<sudah diisi>" || echo "<belum diisi>" )"
    hr
    echo "Yang akan dilakukan jika lanjut:"
    echo "  1. Membuat / memperbarui remote rclone '${remote}'"
    echo "  2. Mengarahkannya ke endpoint Account ID yang kamu isi"
    echo "  3. Menyiapkan target backup ${remote}:${bucket}"
    echo "  4. Menulis config backup agar CLI langsung memakai target itu"
    hr
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      BACKUP_R2_REVIEW_ACTION="back"
      return 0
    fi
    case "${c}" in
      1|apply|a)
        BACKUP_R2_REVIEW_ACTION="apply"
        return 0
        ;;
      2|edit|e)
        BACKUP_R2_REVIEW_ACTION="edit"
        return 0
        ;;
      0|kembali|k|back|b)
        BACKUP_R2_REVIEW_ACTION="back"
        return 0
        ;;
      *)
        warn "Pilihan tidak valid"
        sleep 1
        ;;
    esac
  done
}

backup_r2_setup_menu() {
  local remote account_id bucket
  local access_key=""
  local secret_key=""
  local input="" c review_action=""
  while true; do
    backup_r2_load_existing_state
    remote="${BACKUP_R2_REMOTE_NAME}"
    account_id="${BACKUP_R2_ACCOUNT_ID:-${account_id:-}}"
    bucket="${BACKUP_R2_BUCKET_NAME}"
    # shellcheck disable=SC2034
    local -a items=(
      "1|Quick Setup R2"
      "2|Apply Setup Now"
      "3|Manual rclone config"
      "0|Back"
    )
    ui_menu_screen_begin "10) Tools > Backup/Restore > Cloudflare R2 > Setup"
    echo "Setup aktif:"
    echo "  Remote Name       : ${remote}"
    echo "  Account ID        : ${account_id:-<belum diisi>}"
    echo "  Bucket Name       : ${bucket}"
    echo "  Access Key ID     : $( [[ -n "${access_key}" ]] && echo "<sudah diisi>" || echo "<belum diisi>" )"
    echo "  Secret Access Key : $( [[ -n "${secret_key}" ]] && echo "<sudah diisi>" || echo "<belum diisi>" )"
    hr
    echo "Tutorial setup Cloudflare R2:"
    echo "  1. Siapkan dulu 4 data dari dashboard Cloudflare R2:"
    echo "     Account ID, Bucket Name, Access Key ID, Secret Access Key."
    echo "  2. Pilih 'Quick Setup R2' lalu isi data satu per satu."
    echo "  3. Setelah semua data terisi, review lalu pilih 'Apply'."
    echo "  4. Menu ini akan membuat remote rclone ${remote}"
    echo "     dan mengaktifkan backup ke ${remote}:${bucket}."
    echo "  5. Jika remote R2 sudah pernah dibuat manual,"
    echo "     kamu bisa pilih 'Manual rclone config' lalu pakai remote yang sesuai."
    hr
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1)
        read -r -p "Masukkan Account ID R2: " input || { echo; break; }
        input="$(backup_trim "${input}")"
        if is_back_choice "${input}"; then
          continue
        fi
        [[ -n "${input}" ]] && account_id="${input}"
        read -r -p "Masukkan nama bucket [${bucket}]: " input || { echo; break; }
        input="$(backup_trim "${input}")"
        if is_back_choice "${input}"; then
          continue
        fi
        [[ -n "${input}" ]] && bucket="${input}"
        read -r -p "Masukkan Access Key ID: " input || { echo; break; }
        input="$(backup_trim "${input}")"
        if is_back_choice "${input}"; then
          continue
        fi
        [[ -n "${input}" ]] && access_key="${input}"
        read -r -s -p "Masukkan Secret Access Key: " input || { echo; break; }
        echo
        input="$(backup_trim "${input}")"
        if is_back_choice "${input}"; then
          continue
        fi
        [[ -n "${input}" ]] && secret_key="${input}"
        if [[ -z "${account_id}" || -z "${access_key}" || -z "${secret_key}" || -z "${bucket}" ]]; then
          warn "Masih ada data yang belum diisi. Lengkapi lalu coba lagi."
          pause
          continue
        fi
        backup_r2_review_menu "${remote}" "${account_id}" "${bucket}" "${access_key}" "${secret_key}"
        review_action="${BACKUP_R2_REVIEW_ACTION:-back}"
        case "${review_action}" in
          apply)
            backup_rclone_require || continue
            if backup_r2_apply_setup "${remote}" "${account_id}" "${bucket}" "${access_key}" "${secret_key}"; then
              log "Cloudflare R2 siap dipakai: ${remote}:${bucket}"
            else
              warn "Gagal membuat/memperbarui remote R2."
            fi
            pause
            ;;
          edit)
            continue
            ;;
          *)
            ;;
        esac
        ;;
      2)
        backup_rclone_require || continue
        if [[ -z "${account_id}" || -z "${access_key}" || -z "${secret_key}" || -z "${bucket}" ]]; then
          warn "Account ID, Access Key ID, Secret Access Key, dan Bucket Name wajib diisi."
          pause
          continue
        fi
        backup_r2_review_menu "${remote}" "${account_id}" "${bucket}" "${access_key}" "${secret_key}"
        review_action="${BACKUP_R2_REVIEW_ACTION:-back}"
        case "${review_action}" in
          apply)
            if ! backup_r2_apply_setup "${remote}" "${account_id}" "${bucket}" "${access_key}" "${secret_key}"; then
              warn "Gagal membuat/memperbarui remote R2."
              pause
              continue
            fi
            log "Cloudflare R2 siap dipakai: ${remote}:${bucket}"
            pause
            ;;
          *)
            ;;
        esac
        ;;
      3)
        backup_cli_rclone_config_menu
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

backup_restore_local_menu() {
  local c path=""
  while true; do
    # shellcheck disable=SC2034
    local -a items=(
      "1|List Local Backups"
      "2|Create Local Backup"
      "3|Restore Latest Backup"
      "4|Apply Domain Only"
      "5|Restore From File"
      "0|Back"
    )
    ui_menu_screen_begin "10) Tools > Backup/Restore > Local"
    echo "Backup lokal:"
    echo "  - dipakai untuk arsip lokal dan restore dari server ini"
    echo "  - restore bersifat live dan akan menimpa runtime yang aktif"
    echo "  - jangan dipakai untuk uji coba tanpa backup yang valid"
    hr
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1) backup_cli_exec "10) Tools > Backup/Restore > Local > List" local list ;;
      2)
        if confirm_menu_apply_now "Buat backup lokal sekarang?"; then
          backup_cli_exec "10) Tools > Backup/Restore > Local > Create" local create
        else
          pause
        fi
        ;;
      3)
        if confirm_menu_apply_now "Restore backup lokal terbaru sekarang?"; then
          backup_cli_exec "10) Tools > Backup/Restore > Local > Restore Latest" local restore-latest
        else
          pause
        fi
        ;;
      4)
        if confirm_menu_apply_now "Terapkan domain dari backup lokal terbaru lalu refresh account info sekarang?"; then
          backup_cli_exec "10) Tools > Backup/Restore > Local > Apply Domain Only" local restore-domain-latest
        else
          pause
        fi
        ;;
      5)
        ui_menu_screen_begin "10) Tools > Backup/Restore > Local > Restore From File"
        backup_cli_require_helper || return 0
        read -r -p "Masukkan path arsip .tar.gz (atau kembali): " path || { echo; break; }
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"
        if is_back_choice "${path}"; then
          continue
        fi
        [[ -n "${path}" ]] || { warn "Path tidak boleh kosong."; pause; continue; }
        if confirm_menu_apply_now "Restore dari file ${path} sekarang?"; then
          backup_cli_exec "10) Tools > Backup/Restore > Local > Restore From File" local restore-file "${path}"
        else
          pause
        fi
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

backup_restore_cloud_menu() {
  local provider="$1"
  local label="$2"
  local c status_line provider_status provider_target archive_name=""
  while true; do
    # shellcheck disable=SC2034
    local -a items=(
      "1|Setup"
      "2|Status Config"
      "3|Test Remote"
      "4|Create & Upload Backup"
      "5|List Cloud Backups"
      "6|Restore Latest Cloud Backup"
      "7|Restore Select Backup"
      "8|Delete Cloud Backup"
      "0|Back"
    )
    ui_menu_screen_begin "10) Tools > Backup/Restore > ${label}"
    status_line="$(backup_provider_status_summary "${provider}")"
    provider_status="${status_line%%|*}"
    provider_target="${status_line#*|}"
    if [[ "${provider}" == "gdrive" ]]; then
      echo "Google Drive:"
      echo "  - cocok untuk backup pribadi"
      echo "  - setup awal via OAuth"
    else
      echo "Cloudflare R2:"
      echo "  - cocok untuk backup server"
      echo "  - setup awal via key API"
    fi
    echo "  - status: ${provider_status}"
    echo "  - remote: ${provider_target:-<belum diisi>}"
    echo "  - restore bersifat live dan akan menimpa runtime aktif"
    hr
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1)
        if [[ "${provider}" == "gdrive" ]]; then
          backup_gdrive_setup_menu
        else
          backup_r2_setup_menu
        fi
        ;;
      2) backup_cli_exec "10) Tools > Backup/Restore > ${label} > Status" cloud status --provider "${provider}" ;;
      3)
        backup_cli_exec "10) Tools > Backup/Restore > ${label} > Test Remote" cloud test --provider "${provider}"
        ;;
      4)
        if confirm_menu_apply_now "Buat backup baru lalu upload ke ${label} sekarang?"; then
          backup_cli_exec "10) Tools > Backup/Restore > ${label} > Create Upload" cloud create-upload --provider "${provider}"
        else
          pause
        fi
        ;;
      5) backup_cli_exec "10) Tools > Backup/Restore > ${label} > List" cloud list --provider "${provider}" ;;
      6)
        if confirm_menu_apply_now "Restore backup remote terbaru dari ${label} sekarang?"; then
          backup_cli_exec "10) Tools > Backup/Restore > ${label} > Restore Latest" cloud restore-latest --provider "${provider}"
        else
          pause
        fi
        ;;
      7)
        ui_menu_screen_begin "10) Tools > Backup/Restore > ${label} > Restore Select Backup"
        backup_cli_show_cloud_list "${provider}" || continue
        hr
        read -r -p "Masukkan NO backup dari hasil List Cloud Backups (atau kembali): " archive_name || { echo; break; }
        archive_name="$(backup_trim "${archive_name}")"
        if is_back_choice "${archive_name}"; then
          continue
        fi
        [[ -n "${archive_name}" ]] || { warn "Nomor backup tidak boleh kosong."; pause; continue; }
        if confirm_menu_apply_now "Restore backup nomor ${archive_name} dari ${label} sekarang?"; then
          backup_cli_exec "10) Tools > Backup/Restore > ${label} > Restore Select Backup" cloud restore-file --provider "${provider}" --index "${archive_name}"
        else
          pause
        fi
        ;;
      8)
        ui_menu_screen_begin "10) Tools > Backup/Restore > ${label} > Delete Cloud Backup"
        backup_cli_show_cloud_list "${provider}" || continue
        hr
        read -r -p "Masukkan NO backup dari hasil List Cloud Backups yang akan dihapus (atau kembali): " archive_name || { echo; break; }
        archive_name="$(backup_trim "${archive_name}")"
        if is_back_choice "${archive_name}"; then
          continue
        fi
        [[ -n "${archive_name}" ]] || { warn "Nomor backup tidak boleh kosong."; pause; continue; }
        if confirm_menu_apply_now "Hapus backup nomor ${archive_name} dari ${label} sekarang?"; then
          backup_cli_exec "10) Tools > Backup/Restore > ${label} > Delete Cloud Backup" cloud delete-file --provider "${provider}" --index "${archive_name}"
        else
          pause
        fi
        ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

backup_restore_provider_header() {
  echo "Provider yang tersedia:"
  echo "  - Google Drive  : mudah dipakai, cocok untuk akun personal."
  echo "  - Cloudflare R2 : lebih cocok untuk backup server/object storage."
  hr
  echo "Rekomendasi:"
  echo "  - Google Drive bila ingin simpan backup di Drive pribadi."
  echo "  - Cloudflare R2 bila ingin backend cloud yang lebih native."
  hr
  echo "Catatan:"
  echo "  - restore bersifat live dan akan menimpa runtime aktif."
  echo "  - gunakan restore hanya saat benar-benar ingin rollback / recovery."
  hr
}

backup_restore_menu() {
  local c
  while true; do
    # shellcheck disable=SC2034
    local -a items=(
      "1|Google Drive"
      "2|Cloudflare R2"
      "0|Back"
    )
    ui_menu_screen_begin "10) Tools > Backup/Restore"
    backup_restore_provider_header
    ui_menu_render_options items 76
    hr
    if ! read -r -p "Pilih: " c; then
      echo
      break
    fi
    case "${c}" in
      1|gdrive|google-drive) backup_restore_cloud_menu "gdrive" "Google Drive" ;;
      2|r2|cloudflare-r2) backup_restore_cloud_menu "r2" "Cloudflare R2" ;;
      0|kembali|k|back|b) break ;;
      *) warn "Pilihan tidak valid" ; sleep 1 ;;
    esac
  done
}

manage_feature_backup_ready() {
  return 0
}

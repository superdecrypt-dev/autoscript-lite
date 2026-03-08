# Audit Playbook

Dokumen ini adalah SOP audit untuk proyek `autoscript` (baseline konteks: gunakan repo `superdecrypt-dev/autoscript` sebagai source of truth).

`TESTING_PLAYBOOK.md` dipakai untuk pengujian.
`AUDIT_PLAYBOOK.md` dipakai untuk review bug, risk, regression, drift, dan gap desain.

## 1. Tujuan Audit
- mencari bug runtime
- mencari regresi perilaku
- mencari drift antar source, template, dan runtime
- mencari mismatch antara CLI, installer, dan bot
- memisahkan accepted tradeoff vs bug yang perlu dipatch

## 2. Prinsip Dasar
- audit tidak berhenti di lint
- temuan utama harus berupa:
  - bug
  - risk
  - missing validation
  - behavioural regression
- jika tidak ada finding material, tulis itu secara eksplisit
- accepted risk/by design tetap dicatat, tapi tidak dihitung finding

## 3. Severity
- `High`: security issue, destructive bug, auth bypass, data corruption, install failure, runtime broken
- `Medium`: fitur tidak konsisten, drift source/runtime, race condition, recovery lemah, UX yang menyesatkan
- `Low`: naming, output, docs drift, fallback yang kurang rapi, hardening kecil

## 4. Urutan Audit Prioritas

### Prioritas 1: Entrypoint
- `run.sh`
- `setup.sh`
- `manage.sh`

Fokus:
- alur install
- sync source lokal vs deployed file
- fallback/recovery
- trusted loading
- destructive path handling

### Prioritas 2: Modular Installer
- `opt/setup/core/*.sh`
- `opt/setup/install/*.sh`

Fokus:
- duplikasi fungsi
- variabel global lintas modul
- helper yang hilang setelah refactor
- idempotency langkah install
- staging/swap file yang aman

### Prioritas 3: SSH WS dan QAC
- `opt/setup/install/sshws.sh`
- `opt/setup/bin/sshws-proxy.py`
- `opt/setup/bin/sshws-qac-enforcer.py`
- `opt/manage/features/analytics.sh`

Fokus:
- token path
- `401/403/502/101`
- quota
- speed limit
- IP/Login limit
- active session
- stale session cleanup

### Prioritas 4: Runtime Template
- `opt/setup/templates/nginx/*.conf`
- `opt/setup/templates/systemd/*.service`
- `opt/setup/templates/systemd/*.timer`
- `opt/setup/templates/config/*`

Fokus:
- drift source vs runtime
- placeholder render
- restart/stop behavior
- listener/path mismatch

### Prioritas 5: CLI Modular
- `opt/manage/app/*.sh`
- `opt/manage/core/*.sh`
- `opt/manage/features/*.sh`
- `opt/manage/menus/*.sh`

Fokus:
- parity menu
- refresh account info
- domain sync
- trusted module source
- menu/back flow

### Prioritas 6: Bot
- `install-telegram-bot.sh`
- `bot-telegram/*`
- `install-discord-bot.sh`
- `bot-discord/*`

Fokus:
- parity bot vs CLI
- dangerous actions
- token/log safety
- archive/checksum drift

## 5. Preflight Audit

```bash
cd /root/project/autoscript
git status --short
bash -n run.sh setup.sh manage.sh install-discord-bot.sh install-telegram-bot.sh
shellcheck -x -S warning run.sh setup.sh manage.sh
bash -n opt/setup/core/*.sh opt/setup/install/*.sh
shellcheck -x -S warning setup.sh opt/setup/core/*.sh opt/setup/install/*.sh
bash -n opt/manage/app/*.sh opt/manage/core/*.sh opt/manage/features/*.sh opt/manage/menus/*.sh
shellcheck -x -S warning opt/manage/app/*.sh opt/manage/core/*.sh opt/manage/features/*.sh opt/manage/menus/*.sh
shellcheck -x -S warning opt/setup/bin/xray-observe opt/setup/bin/xray-domain-guard
python3 -m py_compile opt/setup/bin/sshws-proxy.py opt/setup/bin/sshws-qac-enforcer.py opt/setup/bin/xray-speed.py
```

Jika fokus bot:

```bash
python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')
python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py')
```

## 6. Command Audit Cepat

### 6.1 Cari fungsi duplikat modular setup
```bash
python3 - <<'PY'
from pathlib import Path
import re
paths = [Path('setup.sh')] + sorted(Path('opt/setup/core').glob('*.sh')) + sorted(Path('opt/setup/install').glob('*.sh'))
pat = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) \{$')
seen = {}
for path in paths:
    for i, line in enumerate(path.read_text().splitlines(), 1):
        m = pat.match(line)
        if m:
            seen.setdefault(m.group(1), []).append(f'{path}:{i}')
for name, refs in sorted(seen.items()):
    if len(refs) > 1:
        print(name)
        for ref in refs:
            print('  ', ref)
PY
```

### 6.2 Cek source/load yang sensitif
```bash
rg -n "source |trusted|resolve_manage_modules_dir|RUN_USE_LOCAL_SOURCE|KEEP_REPO_AFTER_INSTALL" run.sh setup.sh manage.sh opt/setup opt/manage
```

### 6.3 Cek jalur runtime SSH WS
```bash
rg -n "401|403|502|101|sshws_token|client_ip|ip_limit|speed_limit|quota_used|updated_at" setup.sh opt/setup/install/sshws.sh opt/setup/bin/sshws-proxy.py opt/setup/bin/sshws-qac-enforcer.py opt/manage/features/analytics.sh
```

### 6.4 Cek drift account info/domain sync
```bash
rg -n "detect_domain|sync_xray_domain_file|account_refresh_all_info_files|ssh_account_info" manage.sh opt/manage
```

### 6.5 Cek bot Telegram/Discord
```bash
rg -n "ENABLE_DANGEROUS_ACTIONS|dangerous|unknown_action|api\\.telegram\\.org/bot|commands\\.json|checksum|bot_telegram\\.zip|bot_discord\\.zip" \
  install-telegram-bot.sh install-discord-bot.sh bot-telegram bot-discord
python3 -m py_compile $(find bot-telegram/backend-py/app -name '*.py') $(find bot-telegram/gateway-py/app -name '*.py')
python3 -m py_compile $(find bot-discord/backend-py/app -name '*.py')
```

## 7. Audit Runtime (Opsional, Host Live)

```bash
systemctl is-active xray nginx sshws-dropbear sshws-stunnel sshws-proxy sshws-qac-enforcer.timer
nginx -t
/usr/local/bin/xray run -test -confdir /usr/local/etc/xray/conf.d
ss -ltnp | rg '(:80\\b|:443\\b|127\\.0\\.0\\.1:10015\\b|127\\.0\\.0\\.1:22022\\b|127\\.0\\.0\\.1:22443\\b)'
```

Khusus SSH WS:

```bash
curl -i -N --http1.1 --max-time 5 -H 'Upgrade: websocket' -H 'Connection: Upgrade' http://<domain>/<token>
curl -k -i -N --http1.1 --max-time 5 -H 'Upgrade: websocket' -H 'Connection: Upgrade' https://<domain>/<bebas>/<token>
```

Ekspektasi:
- token valid -> `101`
- token invalid -> `403`
- path tanpa token -> `401`
- backend down -> `502`

## 8. Format Hasil Audit

Gunakan format ini:

```text
Findings
1. High ...
2. Medium ...

Open Questions / Assumptions
1. ...

Residual Risks / Testing Gaps
1. ...

Audit Notes
1. bash -n ...
2. shellcheck ...
```

Aturan:
- findings dulu
- urutkan dari severity tertinggi
- sertakan file dan line reference
- jika tidak ada finding material, tulis itu eksplisit

## 9. Accepted Risk Proyek Ini
- hardcoded Cloudflare token historis diperlakukan sebagai by design kecuali ada instruksi eksplisit untuk mengubah
- SSH WS mengikuti konsep autoscript-stream:
  - non-hybrid
  - tanpa `Sec-WebSocket-*` wajib
- enforcement SSH QAC saat ini diperlakukan sebagai satu sistem SSH untuk seluruh surface yang melewati edge aktif:
  - `SSH WS`
  - `SSH SSL/TLS`
  - `SSH Direct`
- `sshd:22` native bukan target traffic enforcement

## 10. Kapan Harus Patch
- patch jika finding memengaruhi:
  - install
  - auth
  - routing
  - quota
  - speed limit
  - IP/Login limit
  - account info
  - domain/cert sync
- boleh ditunda jika:
  - cosmetic only
  - naming only
  - accepted tradeoff yang sudah disepakati

## 11. Hubungan Dengan Dokumen Lain
- `TESTING_PLAYBOOK.md`: verifikasi perilaku dan gate test
- `HANDOFF.md`: status operasional dan konteks terbaru
- `AGENTS.md`: aturan repo dan baseline audit yang harus dipertahankan

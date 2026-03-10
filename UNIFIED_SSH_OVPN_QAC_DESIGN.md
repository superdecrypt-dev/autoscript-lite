# Unified SSH & OVPN QAC Design

## Tujuan

Menyatukan policy `SSH` dan `OpenVPN` ke satu sistem `QAC` tanpa membuat counter runtime saling menimpa.

Target akhirnya:

- `1 user = 1 policy`
- `quota`, `expiry`, `IP/Login limit`, dan `access` dikelola dari satu source of truth
- `SSH` dan `OpenVPN` tetap boleh punya runtime/accounting sendiri
- panel hanya menampilkan total yang konsisten
- update counter aman dari race

## Prinsip Utama

Yang digabung:

- `quota_limit`
- `expired_at`
- `ip/login limit`
- `access`
- summary total yang dibaca panel

Yang tidak boleh ditulis bareng sebagai satu angka mentah:

- `quota_used`
- `active_session`

Alasannya:

- `SSH` dan `OVPN` punya jalur runtime berbeda
- kalau dua runtime menulis field total yang sama, rawan lost update
- total yang aman harus berasal dari komponen per-protocol, lalu dijumlahkan

## Model Data

Source of truth baru:

- `/opt/quota/ssh-ovpn/<username>.json`

Contoh bentuk file:

```json
{
  "version": 1,
  "username": "demo",
  "policy": {
    "quota_limit_bytes": 5368709120,
    "quota_unit": "binary",
    "expired_at": "2026-03-20",
    "access_enabled": true,
    "ip_limit_enabled": true,
    "ip_limit": 2,
    "speed_limit_enabled": false,
    "speed_down_mbit": 0,
    "speed_up_mbit": 0
  },
  "runtime": {
    "quota_used_ssh_bytes": 1048576,
    "quota_used_ovpn_bytes": 2097152,
    "active_session_ssh": 1,
    "active_session_ovpn": 2,
    "last_seen_ssh_unix": 1773111111,
    "last_seen_ovpn_unix": 1773112222
  },
  "derived": {
    "quota_used_total_bytes": 3145728,
    "active_session_total": 3,
    "quota_exhausted": false,
    "ip_limit_locked": false,
    "last_reason": "-"
  },
  "meta": {
    "created_at": "2026-03-10",
    "updated_at_unix": 1773113333,
    "migrated_from_legacy": true
  }
}
```

## Aturan Counter

`quota_used_total_bytes` dan `active_session_total` bukan primary field yang boleh ditulis bebas oleh runtime.

Aturan aman:

- runtime SSH hanya boleh menulis:
  - `runtime.quota_used_ssh_bytes`
  - `runtime.active_session_ssh`
  - `runtime.last_seen_ssh_unix`
- runtime OVPN hanya boleh menulis:
  - `runtime.quota_used_ovpn_bytes`
  - `runtime.active_session_ovpn`
  - `runtime.last_seen_ovpn_unix`
- setiap write harus menghitung ulang:
  - `derived.quota_used_total_bytes = quota_used_ssh_bytes + quota_used_ovpn_bytes`
  - `derived.active_session_total = active_session_ssh + active_session_ovpn`

Dengan model ini, panel tetap bisa menampilkan total, tetapi race antar runtime tidak membuat angka saling overwrite.

## Locking Strategy

Gunakan lock per-user, bukan satu lock global untuk semua user.

Path lock:

- `/run/autoscript/locks/ssh-ovpn-qac/<username>.lock`

Keuntungan:

- update user `a` tidak memblokir user `b`
- cocok untuk timer/enforcer dan runtime hook yang berjalan paralel

Aturan locking:

1. Semua write ke file unified wajib memakai `flock`
2. Read-only path boleh tanpa lock jika toleran terhadap update pendek
3. Read-modify-write wajib selalu di bawah lock yang sama
4. Recompute `derived.*` dilakukan di critical section yang sama

## API Helper yang Disarankan

Modul baru:

- `opt/manage/features/ssh_ovpn_qac.sh`

Helper inti:

- `ssh_ovpn_qac_state_path`
- `ssh_ovpn_qac_lock_path`
- `ssh_ovpn_qac_with_lock`
- `ssh_ovpn_qac_state_read`
- `ssh_ovpn_qac_state_upsert_policy`
- `ssh_ovpn_qac_state_update_ssh_runtime`
- `ssh_ovpn_qac_state_update_ovpn_runtime`
- `ssh_ovpn_qac_state_recompute_derived`
- `ssh_ovpn_qac_state_set_reason`

Adapter enforcement:

- `ssh_ovpn_qac_apply_ssh_policy`
- `ssh_ovpn_qac_apply_ovpn_policy`
- `ssh_ovpn_qac_apply_shared_policy`

## Integrasi dengan Runtime yang Ada

### SSH

Sumber existing:

- metadata SSH QAC saat ini masih di `/opt/quota/ssh/*.json`
- session runtime SSH sudah ada
- enforcer SSH sudah ada di `sshws-qac-enforcer.py`

Integrasi yang disarankan:

- `sshws-qac-enforcer.py` tetap jadi enforcer SSH
- tetapi source of truth policy dibaca dari file unified
- metadata lama `/opt/quota/ssh/*.json` diubah menjadi:
  - compatibility mirror
  - atau dihapus bertahap setelah semua call-site pindah

### OpenVPN

Sumber existing:

- state OpenVPN saat ini tersebar di clients dir
- expiry enforcement sudah ada via `openvpn-expired`
- akses OVPN dikontrol lewat `ccd-exclusive`

Integrasi yang disarankan:

- `openvpn-expired` diganti/ditambah agar baca `policy.expired_at` dan `policy.access_enabled` dari state unified
- `openvpn_client_access_sync_manage` tetap dipakai sebagai adapter kecil
- counter OpenVPN nanti masuk ke `runtime.active_session_ovpn` dan `runtime.quota_used_ovpn_bytes`

## Quota Used untuk OpenVPN

Implementasi quota OVPN tidak perlu langsung sempurna di fase pertama.

Fase aman:

1. `active_session_ovpn` dulu
2. `quota_used_ovpn_bytes` menyusul setelah sumber usage dipilih

Sumber usage OVPN yang mungkin:

- parsing `status` OpenVPN
- management socket OpenVPN
- log-based accounting
- byte accounting dari edge/proxy jika nanti masuk jalur yang cocok

Rekomendasi:

- fase 1: `quota_limit` unified sudah ada, tapi `quota_used_total_bytes` masih dominan dari SSH jika OVPN usage belum siap
- fase 2: tambahkan usage OVPN begitu sumber datanya cukup stabil

## Active Session yang Aman

`active_session_total` boleh ditampilkan ke panel, tetapi nilainya harus hasil hitung:

- `active_session_total = active_session_ssh + active_session_ovpn`

Sumber:

- `active_session_ssh`: dari session root SSH existing
- `active_session_ovpn`: dari status/client list OpenVPN

Jangan biarkan dua runtime menulis `active_session_total` langsung.

## Policy Semantik

### Quota

Satu quota bersama:

- `SSH` + `OVPN` makan dari limit yang sama
- total yang dibandingkan ke limit adalah `quota_used_total_bytes`

### IP/Login Limit

Definisi yang paling aman:

- limit berlaku pada total sesi aktif `SSH + OVPN`

Contoh:

- `ip_limit = 2`
- `SSH active = 1`
- `OVPN active = 1`
- total `2`
- sesi baru di SSH atau OVPN harus ditolak

### Speed Limit

Karena enforcement SSH dan OVPN beda jalur, speed limit tetap satu policy tetapi adapter apply-nya dipisah:

- `apply_ssh_policy()`
- `apply_ovpn_policy()`

Kalau OVPN speed limit belum siap, policy boleh sudah ada di state unified tetapi apply OVPN tetap `metadata only` sampai adapter siap.

### Expiry dan Access

Expiry bersama:

- satu tanggal berlaku untuk SSH dan OVPN

Access bersama:

- `policy.access_enabled=false` mematikan keduanya

## CLI yang Disarankan

Main menu:

- ganti `5) SSH QAC` menjadi `5) SSH & OVPN QAC`

Submenu:

1. `List Users`
2. `Detail`
3. `Set Quota`
4. `Reset Quota Used`
5. `Toggle Access`
6. `Set Expiry`
7. `Toggle IP/Login Limit`
8. `Set IP/Login Limit`
9. `Clear IP/Login Lock`
10. `Set Speed Download`
11. `Set Speed Upload`
12. `Toggle Speed Limit`

Detail layar menampilkan:

- `Quota Limit`
- `Quota Used SSH`
- `Quota Used OVPN`
- `Quota Used Total`
- `Active Session SSH`
- `Active Session OVPN`
- `Active Session Total`
- `Expired`
- `Access`
- `IP/Login Limit`
- `Speed Limit`
- `Last Reason`

## Migrasi dari State Lama

### SSH legacy

Sumber lama:

- `/opt/quota/ssh/<username>@ssh.json`

Yang dipindahkan:

- quota limit
- expiry
- IP limit
- speed limit
- quota used SSH
- flag lock reason yang masih relevan

### OpenVPN legacy

Sumber lama:

- state OpenVPN per client
- account info OVPN

Yang dipindahkan:

- created_at
- expired_at
- access derived dari allowlist/CCD
- token/path tetap di state OpenVPN lama dulu, tidak wajib dipindah ke unified QAC

### Strategi migrasi

1. baca legacy SSH
2. baca legacy OVPN
3. bentuk unified state baru
4. tandai `meta.migrated_from_legacy=true`
5. selama fase transisi, mirror write masih boleh dilakukan ke file lama jika call-site lama belum dipindah

## Strategi Rollout

### Fase 1

- tambahkan dokumen desain
- tambah helper unified state
- read-only summary dari state unified
- belum pindahkan enforcement

### Fase 2

- pindahkan policy write dari menu `SSH QAC` ke unified state
- SSH masih apply dari adapter compatibility
- OVPN masih expiry/access only

### Fase 3

- ganti menu menjadi `SSH & OVPN QAC`
- detail panel tampilkan counter SSH/OVPN dan total
- integrasikan OVPN active session

### Fase 4

- tambahkan quota usage OVPN
- enforce shared total limit
- hapus metadata lama bertahap

## Non-Goal

Desain ini tidak mewajibkan:

- migrasi instan semua file lama dalam satu patch
- speed shaping OVPN penuh pada fase awal
- storage database seperti SQLite sejak awal

## Kapan Perlu SQLite

JSON + `flock` masih cukup jika:

- write rate rendah-menengah
- update dilakukan per-user
- enforcer berjalan periodik, bukan ratusan event per detik

SQLite layak dipertimbangkan jika nanti:

- usage OVPN dan SSH sama-sama update sangat sering
- butuh query lintas banyak user
- butuh histori/session log lebih kaya

Untuk fase repo saat ini, JSON per-user + `flock` sudah cukup dan lebih ringan dipasang.

## Rekomendasi Akhir

Untuk repo `autoscript`, bentuk paling aman adalah:

- `policy unified`
- `runtime counter split`
- `total derived`
- `lock per-user`
- `adapter enforcement per protokol`

Jadi operator merasa `SSH` dan `OVPN` benar-benar satu sistem, tetapi runtime tetap aman dari race dan tidak saling merusak angka.

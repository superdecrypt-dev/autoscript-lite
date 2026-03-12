# BadVPN UDPGW Design

## Ringkasan

Dokumen ini menjelaskan desain integrasi `badvpn-udpgw` ke proyek `autoscript`.

Tujuan utamanya:
- menyediakan helper UDP untuk akun SSH
- tetap mengikuti pola installer modular proyek
- memakai **binary prebuilt**, bukan build source di VPS saat setup normal
- tidak membuat sistem akun baru; `badvpn-udpgw` diposisikan sebagai fitur tambahan SSH

Status saat ini:
- desain: **siap**
- scaffold repo: **siap**
- binary prebuilt: **sudah ada di repo**
- runtime live: **aktif via setup dan sudah tervalidasi**

## Posisi Fitur

`badvpn-udpgw` diperlakukan sebagai:
- helper tambahan untuk surface SSH
- bukan provider edge
- bukan protokol akun baru
- bukan sistem quota/QAC terpisah

User-facing yang diharapkan:
- `SSH ACCOUNT INFO` menampilkan port `BadVPN UDPGW`
- menu maintenance dapat menampilkan status/restart service

## Model Distribusi

Distribusi yang dipilih adalah **binary prebuilt**.

Alasan:
- setup lebih cepat
- tidak menambah dependency build di VPS
- konsisten dengan arah distribusi `edge-mux`
- lebih mudah distabilkan lintas host

Model yang tidak dijadikan default:
- build from source saat setup
- ketergantungan pada paket distro

Catatan hasil cek host:
- Ubuntu 24.04 dengan repo lengkap (`main/universe/restricted/multiverse`) tidak menyediakan paket `badvpn` atau `udpgw`
- artinya jalur paket distro tidak cukup andal untuk dijadikan baseline proyek

## Struktur Repo

```text
opt/badvpn/
  README.md
  dist/
    README.md
    badvpn-udpgw-linux-amd64
    badvpn-udpgw-linux-arm64
```

Integrasi setup:

```text
opt/setup/install/
  badvpn.sh

opt/setup/templates/config/
  badvpn-runtime.env

opt/setup/templates/systemd/
  badvpn-udpgw.service
```

## Runtime yang Diinginkan

Binary target:
- `/usr/local/bin/badvpn-udpgw`

Runtime env:
- `/etc/default/badvpn-udpgw`

Systemd:
- `badvpn-udpgw.service`

## Port dan Default

Default awal yang disarankan:
- `BADVPN_UDPGW_PORTS="7300 7400 7500 7600 7700 7800 7900"`
- `BADVPN_UDPGW_MAX_CLIENTS=512`
- `BADVPN_UDPGW_MAX_CONNECTIONS_FOR_CLIENT=8`
- `BADVPN_UDPGW_BUFFER_SIZE=1048576`

## Installer Flow yang Diinginkan

1. deteksi arsitektur host (`amd64` / `arm64`)
2. pilih binary prebuilt yang cocok dari `opt/badvpn/dist/`
3. install ke `/usr/local/bin/badvpn-udpgw`
4. render env runtime
5. render unit `systemd`
6. enable/start service
7. expose status di CLI

## Surface CLI yang Diinginkan

Minimal v1:
- `Maintenance > BadVPN UDPGW Status`
- `Maintenance > Restart BadVPN UDPGW`
- `SSH ACCOUNT INFO > BadVPN UDPGW : <port>`

## Keterkaitan dengan SSH

`badvpn-udpgw` harus dianggap bagian dari fitur SSH.

Implikasinya:
- tidak ada menu akun terpisah
- tidak ada metadata user `badvpn` sendiri
- account info cukup menampilkan port service

## Batasan v1

v1 **tidak** mencakup:
- quota khusus UDPGW
- speed limit khusus UDPGW
- multi-instance UDPGW
- multi-port UDPGW
- bot integration khusus

## Rencana Implementasi

### Tahap 1
- desain dokumen
- scaffold repo

### Tahap 2
- Status: selesai.
- isi `opt/badvpn/dist/` dengan binary prebuilt
- implement `opt/setup/install/badvpn.sh`
- implement service `systemd`

### Tahap 3
- Status: selesai.
- integrasi ke `setup.sh`
- integrasi ke `manage`
- status/restart di maintenance
- info port di `SSH ACCOUNT INFO`

### Tahap 4
- Status: selesai untuk baseline saat ini.
- testing live
- update docs/playbook

## Keputusan Saat Ini

- `Edge Gateway (go)` tetap provider utama untuk edge
- `badvpn-udpgw` tidak mengubah arsitektur edge
- `badvpn-udpgw` hanya fitur tambahan untuk ekosistem SSH

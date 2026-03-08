# Edge Gateway Rollback

Rollback singkat untuk memindahkan host dari mode `Edge Gateway` kembali ke mode lama:
- `nginx` kembali pegang publik `80/443`
- `edge-mux` dimatikan
- backend internal `127.0.0.1:18080` tidak lagi dipakai sebagai listener publik

## Kapan dipakai
- `edge-mux` gagal start / crash loop
- routing publik `80/443` bermasalah
- perlu kembali cepat ke mode `nginx` publik

## Prasyarat
- salah satu source setup tersedia:
  - `/usr/local/lib/autoscript-setup/setup.sh`
  - `/root/project/autoscript/setup.sh`

## Langkah rollback
Jalankan sebagai `root`:

```bash
if [[ -f /usr/local/lib/autoscript-setup/setup.sh ]]; then
  SETUP_SCRIPT=/usr/local/lib/autoscript-setup/setup.sh
elif [[ -f /root/project/autoscript/setup.sh ]]; then
  SETUP_SCRIPT=/root/project/autoscript/setup.sh
else
  echo "setup.sh tidak ditemukan untuk rollback" >&2
  exit 1
fi

export EDGE_PROVIDER=none
export EDGE_ACTIVATE_RUNTIME=false

# shellcheck source=/dev/null
source "${SETUP_SCRIPT}"

write_edge_runtime_env

systemctl daemon-reload
systemctl disable --now edge-mux.service || true
systemctl stop edge-mux.service 2>/dev/null || true

write_nginx_config
nginx -t
systemctl restart nginx
```

## Verifikasi
```bash
systemctl is-active nginx
systemctl is-active edge-mux.service
ss -ltn | rg ':(80|443|18080)\\b'
```

Hasil yang diharapkan:
- `nginx` = `active`
- `edge-mux.service` = `inactive`
- listener publik kembali di `:80` dan `:443`
- listener `127.0.0.1:18080` sudah tidak dipakai lagi sebagai frontend publik

## Catatan
- Rollback ini tidak mengubah backend SSH klasik `127.0.0.1:22022`.
- Untuk mengaktifkan lagi edge provider, set kembali `EDGE_PROVIDER=go`, `EDGE_ACTIVATE_RUNTIME=true`, lalu jalankan flow aktivasi edge yang sama seperti saat cutover.

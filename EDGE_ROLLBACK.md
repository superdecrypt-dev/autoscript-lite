# Edge Rollback

Rollback singkat untuk memindahkan host dari mode `edge-mux` kembali ke mode lama:
- `nginx` kembali pegang publik `80/443`
- `edge-mux` dimatikan
- backend internal `127.0.0.1:18080` tidak lagi dipakai sebagai listener publik

## Kapan dipakai
- `edge-mux` gagal start / crash loop
- routing publik `80/443` bermasalah
- perlu kembali cepat ke mode `nginx` publik

## Prasyarat
- repo lokal tersedia di:
  - `/root/project/autoscript`

## Langkah rollback
Jalankan sebagai `root`:

```bash
cd /root/project/autoscript

export EDGE_PROVIDER=go
export EDGE_ACTIVATE_RUNTIME=false

source ./setup.sh

write_edge_runtime_env
write_nginx_config

systemctl disable --now edge-mux.service
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
- Untuk mengaktifkan lagi edge provider, balikkan `EDGE_ACTIVATE_RUNTIME=true` lalu jalankan flow aktivasi edge yang sama seperti saat cutover.

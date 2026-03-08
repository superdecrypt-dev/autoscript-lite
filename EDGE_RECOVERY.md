# Edge Gateway Recovery

Panduan recovery operasional untuk host yang memakai `Edge Gateway`.

Dokumen ini dipakai saat:
- `edge-mux` gagal start / crash loop
- routing publik `80/443` bermasalah
- perlu mengembalikan layanan HTTP publik secepat mungkin

Dokumen ini **bukan** dokumen desain aktif. Baseline arsitektur tetap ada di:
- [EDGE_PROVIDER_DESIGN.md](/root/project/autoscript/EDGE_PROVIDER_DESIGN.md)

## Tujuan Recovery

Recovery darurat ini memindahkan host sementara ke mode aman:
- `nginx` kembali pegang publik `80/443`
- `edge-mux` dimatikan
- backend internal `127.0.0.1:18080` tidak lagi dipakai sebagai listener publik

## Prasyarat

Salah satu source setup tersedia:
- `/usr/local/lib/autoscript-setup/setup.sh`
- `/root/project/autoscript/setup.sh`

## Langkah Recovery Darurat

Jalankan sebagai `root`:

```bash
if [[ -f /usr/local/lib/autoscript-setup/setup.sh ]]; then
  SETUP_SCRIPT=/usr/local/lib/autoscript-setup/setup.sh
elif [[ -f /root/project/autoscript/setup.sh ]]; then
  SETUP_SCRIPT=/root/project/autoscript/setup.sh
else
  echo "setup.sh tidak ditemukan untuk recovery" >&2
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
- `127.0.0.1:18080` tidak lagi menjadi frontend publik

## Recovery Kembali Ke Topologi Utama

Setelah masalah selesai, aktifkan kembali topologi utama:

```bash
edge-provider-switch go
```

## Catatan

- Recovery ini tidak mengubah backend SSH klasik `127.0.0.1:22022`.
- Recovery ini dimaksudkan sebagai SOP darurat, bukan mode operasi normal jangka panjang.

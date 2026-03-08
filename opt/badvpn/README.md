# BadVPN UDPGW

Direktori ini disediakan untuk asset prebuilt `badvpn-udpgw`.

Status saat ini:
- desain: siap
- scaffold: siap
- binary prebuilt: belum dimasukkan
- runtime live: belum diaktifkan

Target struktur:

```text
opt/badvpn/
  README.md
  dist/
    README.md
    badvpn-udpgw-linux-amd64
    badvpn-udpgw-linux-arm64
    SHA256SUMS
```

Distribusi yang dipilih:
- **binary prebuilt**
- bukan build source di VPS saat setup normal

Integrasi installer:
- [badvpn.sh](/root/project/autoscript/opt/setup/install/badvpn.sh)

Template runtime:
- [badvpn-runtime.env](/root/project/autoscript/opt/setup/templates/config/badvpn-runtime.env)
- [badvpn-udpgw.service](/root/project/autoscript/opt/setup/templates/systemd/badvpn-udpgw.service)

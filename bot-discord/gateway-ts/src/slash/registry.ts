import { ChannelType, SlashCommandBuilder } from "discord.js";

const NOTIF_MINUTES_MIN = 1;
const NOTIF_MINUTES_MAX = 1_440;

export function buildSlashCommands() {
  return [
    new SlashCommandBuilder()
      .setName("status")
      .setDescription("Status host, layanan, TLS, dan validasi Xray")
      .addSubcommand((sub) => sub.setName("overview").setDescription("Ringkasan status host dan backend"))
      .addSubcommand((sub) => sub.setName("services").setDescription("Lihat status service utama"))
      .addSubcommand((sub) => sub.setName("tls").setDescription("Lihat informasi sertifikat TLS"))
      .addSubcommand((sub) => sub.setName("xray-test").setDescription("Jalankan xray configuration test"))
      .toJSON(),
    new SlashCommandBuilder()
      .setName("user")
      .setDescription("Kelola user Xray dan SSH")
      .addSubcommand((sub) =>
        sub
          .setName("add")
          .setDescription("Buat user baru")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) => opt.setName("username").setDescription("Username").setRequired(true))
          .addIntegerOption((opt) => opt.setName("days").setDescription("Masa aktif dalam hari").setRequired(true).setMinValue(1))
          .addNumberOption((opt) => opt.setName("quota_gb").setDescription("Quota dalam GB").setRequired(true).setMinValue(0.0001))
          .addStringOption((opt) => opt.setName("password").setDescription("Password SSH (wajib untuk ssh)").setRequired(false))
          .addIntegerOption((opt) => opt.setName("ip_limit").setDescription("IP/Login limit (0 = OFF)").setRequired(false).setMinValue(0))
          .addStringOption((opt) =>
            opt.setName("speed_limit").setDescription("off, 20, atau 20/10").setRequired(false)
          )
      )
      .addSubcommand((sub) =>
        sub
          .setName("info")
          .setDescription("Lihat account info user")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
      )
      .addSubcommand((sub) =>
        sub
          .setName("delete")
          .setDescription("Hapus user")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
      )
      .addSubcommand((sub) =>
        sub
          .setName("extend")
          .setDescription("Perpanjang masa aktif user")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
          .addIntegerOption((opt) => opt.setName("days").setDescription("Tambahan masa aktif dalam hari").setRequired(true).setMinValue(1))
      )
      .addSubcommand((sub) =>
        sub
          .setName("reset-password")
          .setDescription("Reset password SSH user")
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username SSH").setRequired(true).setAutocomplete(true)
          )
          .addStringOption((opt) => opt.setName("password").setDescription("Password baru SSH").setRequired(true))
      )
      .toJSON(),
    new SlashCommandBuilder()
      .setName("qac")
      .setDescription("Quota dan access control")
      .addSubcommand((sub) =>
        sub
          .setName("summary")
          .setDescription("Ringkasan QAC")
          .addStringOption((opt) =>
            opt
              .setName("scope")
              .setDescription("Scope ringkasan")
              .setRequired(true)
              .addChoices(
                { name: "xray", value: "xray" },
                { name: "ssh", value: "ssh" }
              )
          )
      )
      .addSubcommand((sub) =>
        sub
          .setName("detail")
          .setDescription("Detail QAC user")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
      )
      .addSubcommand((sub) =>
        sub
          .setName("set-quota")
          .setDescription("Set quota limit")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
          .addNumberOption((opt) => opt.setName("quota_gb").setDescription("Quota baru dalam GB").setRequired(true).setMinValue(0.0001))
      )
      .addSubcommand((sub) =>
        sub
          .setName("reset-used")
          .setDescription("Reset quota used")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
      )
      .addSubcommand((sub) =>
        sub
          .setName("toggle-block")
          .setDescription("Toggle manual block")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
          .addBooleanOption((opt) => opt.setName("enabled").setDescription("Status block").setRequired(true))
      )
      .addSubcommand((sub) =>
        sub
          .setName("toggle-ip-limit")
          .setDescription("Aktif/nonaktifkan IP/Login limit")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
          .addBooleanOption((opt) => opt.setName("enabled").setDescription("Status IP/Login limit").setRequired(true))
      )
      .addSubcommand((sub) =>
        sub
          .setName("set-ip-limit")
          .setDescription("Set maksimum IP/Login limit")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
          .addIntegerOption((opt) => opt.setName("ip_limit").setDescription("Nilai limit").setRequired(true).setMinValue(1))
      )
      .addSubcommand((sub) =>
        sub
          .setName("unlock-ip")
          .setDescription("Unlock IP/Login lock")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
      )
      .addSubcommand((sub) =>
        sub
          .setName("set-speed-down")
          .setDescription("Set speed download")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
          .addNumberOption((opt) => opt.setName("mbit").setDescription("Speed download Mbps").setRequired(true).setMinValue(0.0001))
      )
      .addSubcommand((sub) =>
        sub
          .setName("set-speed-up")
          .setDescription("Set speed upload")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
          .addNumberOption((opt) => opt.setName("mbit").setDescription("Speed upload Mbps").setRequired(true).setMinValue(0.0001))
      )
      .addSubcommand((sub) =>
        sub
          .setName("toggle-speed")
          .setDescription("Aktif/nonaktifkan speed limit")
          .addStringOption((opt) =>
            opt
              .setName("type")
              .setDescription("Type user")
              .setRequired(true)
              .addChoices(
                { name: "vless", value: "vless" },
                { name: "vmess", value: "vmess" },
                { name: "trojan", value: "trojan" },
                { name: "ssh", value: "ssh" }
              )
          )
          .addStringOption((opt) =>
            opt.setName("username").setDescription("Username").setRequired(true).setAutocomplete(true)
          )
          .addBooleanOption((opt) => opt.setName("enabled").setDescription("Status speed limit").setRequired(true))
      )
      .toJSON(),
    new SlashCommandBuilder()
      .setName("domain")
      .setDescription("Kontrol domain aktif")
      .addSubcommand((sub) => sub.setName("info").setDescription("Lihat domain aktif dan info terkait"))
      .addSubcommand((sub) => sub.setName("server-name").setDescription("Lihat nginx server_name aktif"))
      .addSubcommand((sub) =>
        sub
          .setName("set-manual")
          .setDescription("Set domain manual")
          .addStringOption((opt) => opt.setName("domain").setDescription("Domain yang sudah mengarah ke VPS").setRequired(true))
      )
      .addSubcommand((sub) =>
        sub
          .setName("set-auto")
          .setDescription("Set domain otomatis via Cloudflare")
          .addStringOption((opt) =>
            opt
              .setName("root_domain")
              .setDescription("Root domain")
              .setRequired(true)
              .setAutocomplete(true)
          )
          .addStringOption((opt) =>
            opt
              .setName("subdomain_mode")
              .setDescription("Mode subdomain")
              .setRequired(true)
              .addChoices(
                { name: "auto", value: "auto" },
                { name: "manual", value: "manual" }
              )
          )
          .addStringOption((opt) => opt.setName("subdomain").setDescription("Isi jika mode manual").setRequired(false))
          .addBooleanOption((opt) => opt.setName("proxied").setDescription("Aktifkan proxy Cloudflare").setRequired(false))
          .addBooleanOption((opt) =>
            opt
              .setName("allow_existing_same_ip")
              .setDescription("Izinkan pakai record existing dengan IP sama")
              .setRequired(false)
          )
      )
      .addSubcommand((sub) => sub.setName("refresh-accounts").setDescription("Refresh semua account info"))
      .toJSON(),
    new SlashCommandBuilder()
      .setName("network")
      .setDescription("DNS dan domain guard")
      .addSubcommand((sub) => sub.setName("dns-summary").setDescription("Lihat ringkasan DNS runtime"))
      .addSubcommand((sub) =>
        sub
          .setName("set-dns-primary")
          .setDescription("Set DNS primary")
          .addStringOption((opt) =>
            opt.setName("dns").setDescription("Alamat DNS primary").setRequired(true).setAutocomplete(true)
          )
      )
      .addSubcommand((sub) =>
        sub
          .setName("set-dns-secondary")
          .setDescription("Set DNS secondary")
          .addStringOption((opt) =>
            opt.setName("dns").setDescription("Alamat DNS secondary").setRequired(true).setAutocomplete(true)
          )
      )
      .addSubcommand((sub) =>
        sub
          .setName("set-dns-strategy")
          .setDescription("Set DNS query strategy")
          .addStringOption((opt) =>
            opt
              .setName("strategy")
              .setDescription("Query strategy")
              .setRequired(true)
              .addChoices(
                { name: "UseIP", value: "UseIP" },
                { name: "UseIPv4", value: "UseIPv4" },
                { name: "UseIPv6", value: "UseIPv6" },
                { name: "PreferIPv4", value: "PreferIPv4" },
                { name: "PreferIPv6", value: "PreferIPv6" }
              )
          )
      )
      .addSubcommand((sub) => sub.setName("toggle-dns-cache").setDescription("Toggle DNS cache"))
      .addSubcommand((sub) => sub.setName("state-file").setDescription("Lihat raw state file network"))
      .addSubcommand((sub) => sub.setName("domain-guard-status").setDescription("Lihat status domain guard"))
      .addSubcommand((sub) => sub.setName("domain-guard-check").setDescription("Jalankan pengecekan domain guard"))
      .addSubcommand((sub) =>
        sub
          .setName("domain-guard-renew")
          .setDescription("Renew domain guard jika perlu")
          .addBooleanOption((opt) => opt.setName("force").setDescription("Paksa renew").setRequired(false))
      )
      .toJSON(),
    new SlashCommandBuilder()
      .setName("ops")
      .setDescription("Operasi admin cepat")
      .addSubcommand((sub) =>
        sub
          .setName("purge")
          .setDescription("Hapus pesan bot atau semua pesan terbaru di channel")
          .addStringOption((opt) =>
            opt
              .setName("mode")
              .setDescription("Mode penghapusan pesan")
              .setRequired(true)
              .addChoices(
                { name: "bot_only", value: "bot_only" },
                { name: "all_messages", value: "all_messages" }
              )
          )
          .addIntegerOption((opt) =>
            opt
              .setName("jumlah")
              .setDescription("Jumlah target pesan (1-1000)")
              .setRequired(false)
              .setMinValue(1)
              .setMaxValue(1000)
          )
          .addChannelOption((opt) =>
            opt
              .setName("channel")
              .setDescription("Channel target (default: channel sekarang)")
              .setRequired(false)
              .addChannelTypes(ChannelType.GuildText)
          )
      )
      .addSubcommand((sub) => sub.setName("speedtest").setDescription("Jalankan speedtest server"))
      .addSubcommand((sub) => sub.setName("service-status").setDescription("Lihat status service utama"))
      .addSubcommand((sub) =>
        sub
          .setName("restart")
          .setDescription("Restart service terpilih")
          .addStringOption((opt) =>
            opt
              .setName("service")
              .setDescription("Service target")
              .setRequired(true)
              .setAutocomplete(true)
          )
      )
      .addSubcommand((sub) => sub.setName("traffic-overview").setDescription("Ringkasan traffic analytics"))
      .addSubcommand((sub) =>
        sub
          .setName("traffic-top")
          .setDescription("Top users by traffic")
          .addIntegerOption((opt) => opt.setName("limit").setDescription("Jumlah user").setRequired(true).setMinValue(1))
      )
      .addSubcommand((sub) =>
        sub
          .setName("traffic-search")
          .setDescription("Cari user pada traffic analytics")
          .addStringOption((opt) =>
            opt.setName("query").setDescription("Query username").setRequired(true).setAutocomplete(true)
          )
      )
      .addSubcommand((sub) => sub.setName("traffic-export").setDescription("Export traffic analytics ke JSON"))
      .toJSON(),
    new SlashCommandBuilder()
      .setName("notify")
      .setDescription("Kelola notifikasi status service Discord")
      .addSubcommand((sub) => sub.setName("status").setDescription("Lihat konfigurasi notifikasi saat ini"))
      .addSubcommand((sub) =>
        sub
          .setName("bind")
          .setDescription("Set channel dan interval notifikasi service")
          .addChannelOption((opt) =>
            opt
              .setName("channel")
              .setDescription("Channel notifikasi service")
              .setRequired(true)
              .addChannelTypes(ChannelType.GuildText)
          )
          .addIntegerOption((opt) =>
            opt
              .setName("durasi_menit")
              .setDescription(`Interval notifikasi ${NOTIF_MINUTES_MIN}-${NOTIF_MINUTES_MAX} menit`)
              .setRequired(true)
              .setMinValue(NOTIF_MINUTES_MIN)
              .setMaxValue(NOTIF_MINUTES_MAX)
          )
      )
      .addSubcommand((sub) => sub.setName("enable").setDescription("Aktifkan notifikasi otomatis"))
      .addSubcommand((sub) => sub.setName("disable").setDescription("Matikan notifikasi otomatis"))
      .addSubcommand((sub) => sub.setName("unbind").setDescription("Lepas channel notifikasi dan matikan auto status"))
      .addSubcommand((sub) => sub.setName("test").setDescription("Kirim test notifikasi ke channel terikat"))
      .toJSON(),
  ];
}

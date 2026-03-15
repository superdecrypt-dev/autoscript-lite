import { ChannelType, SlashCommandBuilder } from "discord.js";

const NOTIF_MINUTES_MIN = 1;
const NOTIF_MINUTES_MAX = 1_440;

export function buildSlashCommands() {
  return [
    new SlashCommandBuilder()
      .setName("menu")
      .setDescription("Buka dashboard interaktif bot Discord")
      .toJSON(),
    new SlashCommandBuilder()
      .setName("status")
      .setDescription("Status host, layanan, TLS, dan validasi Xray")
      .addSubcommand((sub) => sub.setName("overview").setDescription("Ringkasan status host dan backend"))
      .addSubcommand((sub) => sub.setName("services").setDescription("Lihat status service utama"))
      .addSubcommand((sub) => sub.setName("tls").setDescription("Lihat informasi sertifikat TLS"))
      .addSubcommand((sub) => sub.setName("xray-test").setDescription("Jalankan xray configuration test"))
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
              .addChannelTypes(ChannelType.GuildText),
          )
          .addIntegerOption((opt) =>
            opt
              .setName("durasi_menit")
              .setDescription(`Interval notifikasi ${NOTIF_MINUTES_MIN}-${NOTIF_MINUTES_MAX} menit`)
              .setRequired(true)
              .setMinValue(NOTIF_MINUTES_MIN)
              .setMaxValue(NOTIF_MINUTES_MAX),
          ),
      )
      .addSubcommand((sub) => sub.setName("enable").setDescription("Aktifkan notifikasi otomatis"))
      .addSubcommand((sub) => sub.setName("disable").setDescription("Matikan notifikasi otomatis"))
      .addSubcommand((sub) => sub.setName("unbind").setDescription("Lepas channel notifikasi dan matikan auto status"))
      .addSubcommand((sub) => sub.setName("test").setDescription("Kirim test notifikasi ke channel terikat"))
      .toJSON(),
  ];
}

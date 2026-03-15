import { execFile } from "node:child_process";
import { promisify } from "node:util";

import {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonInteraction,
  ButtonStyle,
  ChatInputCommandInteraction,
  Client,
  EmbedBuilder,
  MessageFlags,
  PermissionFlagsBits,
  type GuildBasedChannel,
} from "discord.js";

import { ChannelPolicyStore } from "../../channel_policy";

const SERVICE_NAMES = [
  "xray",
  "nginx",
  "wireproxy",
  "xray-expired",
  "xray-quota",
  "xray-limit-ip",
  "xray-speed",
] as const;

const NOTIF_BUTTON_ON = "notifsvc:on";
const NOTIF_BUTTON_OFF = "notifsvc:off";
const NOTIF_BUTTON_TEST = "notifsvc:test";

const execFileAsync = promisify(execFile);

type ServiceState = "active" | "inactive" | "failed" | "activating" | "deactivating" | "unknown";
type ServiceStatus = { service: string; state: ServiceState; raw: string };
type SendCapableChannel = {
  id: string;
  send: (options: Record<string, unknown>) => Promise<unknown>;
};

function getDiscordErrorCode(err: unknown): number | null {
  if (!err || typeof err !== "object") return null;
  const maybe = (err as { code?: unknown }).code;
  return typeof maybe === "number" ? maybe : null;
}

function formatError(err: unknown): string {
  if (err instanceof Error) {
    return `${err.name}: ${err.message}`;
  }
  return String(err);
}

function normalizeServiceState(raw: string): ServiceState {
  const value = raw.trim().toLowerCase();
  if (value === "active") return "active";
  if (value === "inactive") return "inactive";
  if (value === "failed") return "failed";
  if (value === "activating") return "activating";
  if (value === "deactivating") return "deactivating";
  return "unknown";
}

function toStateLabel(state: ServiceState, raw: string): string {
  if (state === "unknown" && raw.trim()) {
    return `UNKNOWN (${raw.trim()})`;
  }
  return state.toUpperCase();
}

function isSendCapableChannel(channel: unknown): channel is SendCapableChannel {
  if (!channel || typeof channel !== "object") return false;
  const maybe = channel as { id?: unknown; send?: unknown };
  return typeof maybe.id === "string" && typeof maybe.send === "function";
}

function buildNotifButtons(enabled: boolean): ActionRowBuilder<ButtonBuilder> {
  return new ActionRowBuilder<ButtonBuilder>().addComponents(
    new ButtonBuilder()
      .setCustomId(NOTIF_BUTTON_ON)
      .setLabel("ON")
      .setStyle(enabled ? ButtonStyle.Success : ButtonStyle.Secondary)
      .setDisabled(enabled),
    new ButtonBuilder()
      .setCustomId(NOTIF_BUTTON_OFF)
      .setLabel("OFF")
      .setStyle(!enabled ? ButtonStyle.Danger : ButtonStyle.Secondary)
      .setDisabled(!enabled),
    new ButtonBuilder().setCustomId(NOTIF_BUTTON_TEST).setLabel("Test Notifikasi").setStyle(ButtonStyle.Primary)
  );
}

function buildNotifControlEmbed(channelPolicyStore: ChannelPolicyStore, title = "Notify Status"): EmbedBuilder {
  const channelId = channelPolicyStore.getControlChannelId();
  const enabled = channelPolicyStore.getAutoStatusEnabled();
  const interval = channelPolicyStore.getAutoStatusIntervalMinutes();
  const lastSent = channelPolicyStore.getLastAutoStatusAt() ?? "-";

  return new EmbedBuilder()
    .setTitle(title)
    .setDescription("Konfigurasi notifikasi service untuk channel Discord.")
    .setColor(enabled ? 0x2ecc71 : 0xf39c12)
    .addFields(
      { name: "Channel", value: channelId ? `<#${channelId}>` : "Belum diset", inline: true },
      { name: "Interval", value: `${interval} menit`, inline: true },
      { name: "Status", value: enabled ? "ON" : "OFF", inline: true },
      { name: "Last Sent", value: lastSent, inline: false },
      { name: "Services", value: SERVICE_NAMES.join(", "), inline: false }
    )
    .setTimestamp();
}

export function buildNotifControlMessage(channelPolicyStore: ChannelPolicyStore, title?: string) {
  return {
    embeds: [buildNotifControlEmbed(channelPolicyStore, title)],
    components: [buildNotifButtons(channelPolicyStore.getAutoStatusEnabled())],
  };
}

function describeMissingSendPermissions(channel: GuildBasedChannel, interaction: ChatInputCommandInteraction): string | null {
  if (!("permissionsFor" in channel) || typeof channel.permissionsFor !== "function") return null;
  const me = interaction.guild?.members.me;
  if (!me) return null;
  const perms = channel.permissionsFor(me);
  if (!perms) return "Gagal membaca izin bot untuk channel tersebut.";
  const required = [
    { flag: PermissionFlagsBits.ViewChannel, label: "View Channel" },
    { flag: PermissionFlagsBits.SendMessages, label: "Send Messages" },
    { flag: PermissionFlagsBits.EmbedLinks, label: "Embed Links" },
  ];
  const missing = required.filter((item) => !perms.has(item.flag)).map((item) => item.label);
  if (missing.length === 0) return null;
  return `Bot belum punya izin di channel target: ${missing.join(", ")}`;
}

async function readServiceStatus(service: string): Promise<ServiceStatus> {
  try {
    const { stdout } = await execFileAsync("systemctl", ["is-active", service], { timeout: 12_000 });
    const raw = String(stdout ?? "")
      .trim()
      .split(/\s+/)[0] || "unknown";
    return { service, state: normalizeServiceState(raw), raw };
  } catch (err) {
    const maybe = err as { stdout?: unknown; stderr?: unknown };
    const stdout = String(maybe?.stdout ?? "").trim();
    const stderr = String(maybe?.stderr ?? "").trim();
    const raw = (stdout || stderr || "unknown").split(/\s+/)[0];
    return { service, state: normalizeServiceState(raw), raw };
  }
}

async function collectServiceStatuses(): Promise<ServiceStatus[]> {
  return Promise.all(SERVICE_NAMES.map((service) => readServiceStatus(service)));
}

function buildServiceStatusEmbed(statuses: ServiceStatus[], source: "auto" | "test"): EmbedBuilder {
  const healthyCount = statuses.filter((item) => item.state === "active").length;
  const unhealthyCount = statuses.length - healthyCount;
  const allHealthy = unhealthyCount === 0;
  const sourceText = source === "test" ? "manual test" : "scheduler";

  const embed = new EmbedBuilder()
    .setTitle("Service Status Notification")
    .setDescription(`Sumber: ${sourceText}\nHealthy: ${healthyCount}/${statuses.length}`)
    .setColor(allHealthy ? 0x2ecc71 : 0xe67e22)
    .setTimestamp();

  for (const item of statuses) {
    embed.addFields({
      name: item.service,
      value: toStateLabel(item.state, item.raw),
      inline: true,
    });
  }

  return embed;
}

export async function sendServiceNotification(
  client: Client,
  channelPolicyStore: ChannelPolicyStore,
  source: "auto" | "test"
): Promise<{ ok: boolean; message: string }> {
  const channelId = channelPolicyStore.getControlChannelId();
  if (!channelId) {
    return { ok: false, message: "Channel notifikasi belum diset." };
  }

  let channel: Awaited<ReturnType<typeof client.channels.fetch>>;
  try {
    channel = await client.channels.fetch(channelId);
  } catch (err) {
    return { ok: false, message: `Gagal mengakses channel <#${channelId}>: ${formatError(err)}` };
  }

  if (!isSendCapableChannel(channel)) {
    return { ok: false, message: `Channel <#${channelId}> tidak bisa dipakai untuk kirim notifikasi.` };
  }

  let statuses: ServiceStatus[];
  try {
    statuses = await collectServiceStatuses();
  } catch (err) {
    return { ok: false, message: `Gagal membaca status service: ${formatError(err)}` };
  }

  try {
    await channel.send({ embeds: [buildServiceStatusEmbed(statuses, source)] });
    if (source === "auto") {
      channelPolicyStore.markAutoStatusSent(new Date().toISOString());
    }
    return { ok: true, message: `Notifikasi terkirim ke <#${channelId}>.` };
  } catch (err) {
    const code = getDiscordErrorCode(err);
    if (code === 50013) {
      return {
        ok: false,
        message: "Gagal kirim notifikasi: bot tidak punya izin `View Channel`, `Send Messages`, atau `Embed Links`.",
      };
    }
    return { ok: false, message: `Gagal kirim notifikasi: ${formatError(err)}` };
  }
}

export async function handleNotifyControlButton(
  interaction: ButtonInteraction,
  deps: { client: Client; channelPolicyStore: ChannelPolicyStore }
): Promise<boolean> {
  const id = interaction.customId;
  if (!id.startsWith("notifsvc:")) return false;

  if (id === NOTIF_BUTTON_ON) {
    if (!deps.channelPolicyStore.getControlChannelId()) {
      await interaction.reply({
        content: "Channel notifikasi belum diset. Gunakan `/notify bind` dulu.",
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }
    deps.channelPolicyStore.update({ enabled: true });
    await interaction.update({
      content: "Notifikasi service diaktifkan.",
      ...buildNotifControlMessage(deps.channelPolicyStore, "Notify Status"),
    });
    return true;
  }

  if (id === NOTIF_BUTTON_OFF) {
    deps.channelPolicyStore.update({ enabled: false });
    await interaction.update({
      content: "Notifikasi service dimatikan.",
      ...buildNotifControlMessage(deps.channelPolicyStore, "Notify Status"),
    });
    return true;
  }

  if (id === NOTIF_BUTTON_TEST) {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const sent = await sendServiceNotification(deps.client, deps.channelPolicyStore, "test");
    await interaction.editReply(sent.message);
    return true;
  }

  return false;
}

export async function handleNotifySlashCommand(
  interaction: ChatInputCommandInteraction,
  deps: { client: Client; channelPolicyStore: ChannelPolicyStore }
): Promise<void> {
  const subcommand = interaction.options.getSubcommand(true);

  if (subcommand === "status") {
    await interaction.reply({
      ...buildNotifControlMessage(deps.channelPolicyStore),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "bind") {
    const channel = interaction.options.getChannel("channel", true) as GuildBasedChannel;
    const intervalMinutes = interaction.options.getInteger("durasi_menit", true);
    const permissionError = describeMissingSendPermissions(channel, interaction);
    if (permissionError) {
      await interaction.reply({ content: permissionError, flags: MessageFlags.Ephemeral });
      return;
    }

    deps.channelPolicyStore.update({
      channelId: channel.id,
      intervalMinutes,
    });

    await interaction.reply({
      content: `Konfigurasi disimpan untuk <#${channel.id}> (${intervalMinutes} menit).`,
      ...buildNotifControlMessage(deps.channelPolicyStore),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "enable") {
    if (!deps.channelPolicyStore.getControlChannelId()) {
      await interaction.reply({
        content: "Channel notifikasi belum diset. Gunakan `/notify bind` dulu.",
        flags: MessageFlags.Ephemeral,
      });
      return;
    }
    deps.channelPolicyStore.update({ enabled: true });
    await interaction.reply({
      content: "Notifikasi service diaktifkan.",
      ...buildNotifControlMessage(deps.channelPolicyStore),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "disable") {
    deps.channelPolicyStore.update({ enabled: false });
    await interaction.reply({
      content: "Notifikasi service dimatikan.",
      ...buildNotifControlMessage(deps.channelPolicyStore),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "unbind") {
    deps.channelPolicyStore.update({ channelId: null, enabled: false });
    await interaction.reply({
      content: "Channel notifikasi dilepas dan auto status dimatikan.",
      ...buildNotifControlMessage(deps.channelPolicyStore),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "test") {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const sent = await sendServiceNotification(deps.client, deps.channelPolicyStore, "test");
    await interaction.editReply(sent.message);
    return;
  }

  await interaction.reply({ content: "Subcommand notify tidak dikenali.", flags: MessageFlags.Ephemeral });
}

import { ChannelType, ChatInputCommandInteraction, MessageFlags } from "discord.js";

import type { BackendClient } from "../../api_client";
import { sendActionResult } from "../../interactions/result";
import { buildSlashConfirmView } from "../confirm";

type PurgeCapableChannel = {
  id: string;
  messages: { fetch: (options: Record<string, unknown>) => Promise<Map<string, { id: string; author?: { id?: string; bot?: boolean }; createdTimestamp?: number }>> };
  bulkDelete: (messages: string[] | number, filterOld?: boolean) => Promise<{ size?: number }>;
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

function isPurgeCapableChannel(channel: unknown): channel is PurgeCapableChannel {
  if (!channel || typeof channel !== "object") return false;
  const maybe = channel as { messages?: unknown; bulkDelete?: unknown; id?: unknown };
  return typeof maybe.id === "string" && typeof maybe.bulkDelete === "function" && typeof maybe.messages === "object";
}

async function handlePurgeSubcommand(interaction: ChatInputCommandInteraction): Promise<void> {
  const modeRaw = interaction.options.getString("mode", true);
  const mode = modeRaw === "all_messages" ? "all_messages" : "bot_only";
  const amount = interaction.options.getInteger("jumlah", false) ?? 100;
  const selectedChannel = interaction.options.getChannel("channel", false, [ChannelType.GuildText]);
  const target = selectedChannel ?? interaction.channel;

  if (!target || !isPurgeCapableChannel(target)) {
    await interaction.reply({
      content: "Channel target tidak mendukung bulk delete.",
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  await interaction.deferReply({ flags: MessageFlags.Ephemeral });

  const maxDelete = Math.min(Math.max(amount, 1), 1000);
  const fourteenDaysMs = 14 * 24 * 60 * 60 * 1000;
  const nowMs = Date.now();

  let deleted = 0;
  let scanned = 0;
  let beforeId: string | undefined;
  let loops = 0;

  while (deleted < maxDelete && loops < 40) {
    loops += 1;
    let batch: Map<string, { id: string; author?: { id?: string; bot?: boolean }; createdTimestamp?: number }>;
    try {
      batch = await target.messages.fetch({
        limit: 100,
        ...(beforeId ? { before: beforeId } : {}),
      });
    } catch (err) {
      await interaction.editReply(`Gagal membaca pesan channel: ${formatError(err)}`);
      return;
    }

    if (!batch || batch.size === 0) break;
    scanned += batch.size;

    const candidateIds: string[] = [];
    for (const msg of batch.values()) {
      if (!msg || typeof msg.id !== "string") continue;
      if (typeof msg.createdTimestamp !== "number" || nowMs - msg.createdTimestamp >= fourteenDaysMs) continue;
      const isBotMessage = msg.author?.bot === true;
      if (mode === "bot_only" && !isBotMessage) continue;
      candidateIds.push(msg.id);
      if (deleted + candidateIds.length >= maxDelete) break;
    }

    if (candidateIds.length > 0) {
      try {
        const res = await target.bulkDelete(candidateIds, true);
        const count = typeof res?.size === "number" ? res.size : candidateIds.length;
        deleted += count;
      } catch (err) {
        const code = getDiscordErrorCode(err);
        if (code === 50013) {
          await interaction.editReply("Gagal bulk delete: bot tidak punya izin `Manage Messages` di channel target.");
          return;
        }
        await interaction.editReply(`Gagal bulk delete: ${formatError(err)}`);
        return;
      }
    }

    const keys = Array.from(batch.keys());
    beforeId = keys[keys.length - 1];
    if (!beforeId) break;
  }

  const modeText = mode === "bot_only" ? "pesan bot saja" : "semua pesan (user+bot)";
  await interaction.editReply(
    `Purge selesai.\n- Mode: ${modeText}\n- Channel: <#${target.id}>\n- Dihapus: ${deleted}\n- Scan: ${scanned} pesan`
  );
}

export async function handleOpsSlashCommand(
  interaction: ChatInputCommandInteraction,
  deps: { backend: BackendClient }
): Promise<void> {
  const subcommand = interaction.options.getSubcommand(true);

  if (subcommand === "purge") {
    await handlePurgeSubcommand(interaction);
    return;
  }

  if (subcommand === "speedtest") {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const res = await deps.backend.runDomainAction("ops", "speedtest");
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  if (subcommand === "service-status") {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const res = await deps.backend.runDomainAction("ops", "service_status");
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  if (subcommand === "restart") {
    const service = String(interaction.options.getString("service", true) || "").trim().toLowerCase();
    await interaction.reply({
      ...buildSlashConfirmView("ops", "restart_service", { service }, "Restart service", [`Service: **${service}**`]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "traffic-overview") {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const res = await deps.backend.runDomainAction("ops", "traffic_overview");
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  if (subcommand === "traffic-top") {
    const limit = String(interaction.options.getInteger("limit", true));
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const res = await deps.backend.runDomainAction("ops", "traffic_top", { limit });
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  if (subcommand === "traffic-search") {
    const query = String(interaction.options.getString("query", true) || "").trim();
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const res = await deps.backend.runDomainAction("ops", "traffic_search", { query });
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  if (subcommand === "traffic-export") {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const res = await deps.backend.runDomainAction("ops", "traffic_export");
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  await interaction.reply({ content: "Subcommand ops tidak dikenali.", flags: MessageFlags.Ephemeral });
}

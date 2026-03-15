import {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonInteraction,
  ButtonStyle,
  MessageFlags,
  ModalSubmitInteraction,
} from "discord.js";

type PurgeCapableChannel = {
  id: string;
  messages: {
    fetch: (options: Record<string, unknown>) => Promise<Map<string, { id: string; author?: { bot?: boolean }; createdTimestamp?: number }>>;
  };
  bulkDelete: (messages: string[] | number, filterOld?: boolean) => Promise<{ size?: number }>;
};

type PurgeInteraction = ButtonInteraction | ModalSubmitInteraction;

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
  const maybe = channel as { id?: unknown; messages?: unknown; bulkDelete?: unknown };
  return typeof maybe.id === "string" && typeof maybe.messages === "object" && typeof maybe.bulkDelete === "function";
}

export function buildPurgeConfirmView(token: string, mode: string, amount: number) {
  const modeText = mode === "all_messages" ? "semua pesan (user+bot)" : "pesan bot saja";
  return {
    content: `Konfirmasi purge?\n- Mode: ${modeText}\n- Jumlah target: ${amount}\n- Channel: channel saat ini`,
    components: [
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`menu:ops:purge-confirm:${token}`).setLabel("Confirm").setStyle(ButtonStyle.Danger),
        new ButtonBuilder().setCustomId(`menu:ops:purge-cancel:${token}`).setLabel("Cancel").setStyle(ButtonStyle.Secondary),
      ),
    ],
  };
}

export async function runPurgeAction(interaction: PurgeInteraction, mode: string, amount: number): Promise<void> {
  const target = interaction.channel;
  if (!target || !isPurgeCapableChannel(target)) {
    await interaction.reply({
      content: "Channel target tidak mendukung bulk delete.",
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  const normalizedMode = mode === "all_messages" ? "all_messages" : "bot_only";
  const maxDelete = Math.min(Math.max(amount, 1), 1000);
  const fourteenDaysMs = 14 * 24 * 60 * 60 * 1000;
  const nowMs = Date.now();

  await interaction.deferReply({ flags: MessageFlags.Ephemeral });

  let deleted = 0;
  let scanned = 0;
  let beforeId: string | undefined;
  let loops = 0;

  while (deleted < maxDelete && loops < 40) {
    loops += 1;
    let batch: Map<string, { id: string; author?: { bot?: boolean }; createdTimestamp?: number }>;
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
      if (normalizedMode === "bot_only" && !isBotMessage) continue;
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

  const modeText = normalizedMode === "bot_only" ? "pesan bot saja" : "semua pesan (user+bot)";
  await interaction.editReply(
    `Purge selesai.\n- Mode: ${modeText}\n- Channel: <#${target.id}>\n- Dihapus: ${deleted}\n- Scan: ${scanned} pesan`,
  );
}

import { ButtonInteraction, MessageFlags } from "discord.js";

import type { BackendClient } from "../api_client";
import { consumePendingConfirm } from "./confirm_state";
import { sendActionResult } from "./result";
const INVALID_INTERACTION_MSG = "Pilihan tidak valid atau kadaluarsa. Silakan ulangi dari slash command.";

export async function handleButton(interaction: ButtonInteraction, backend: BackendClient): Promise<boolean> {
  const id = interaction.customId;

  if (id.startsWith("slashconfirm:")) {
    const token = id.split(":")[1] || "";
    const pending = consumePendingConfirm(token);
    if (!pending) {
      await interaction.reply({ content: INVALID_INTERACTION_MSG, flags: MessageFlags.Ephemeral });
      return true;
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    try {
      const res = await backend.runDomainAction(pending.domain, pending.action, pending.params);
      await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    } catch (err) {
      await sendActionResult(interaction, "Backend Error", String(err), false);
    }

    return true;
  }

  if (id.startsWith("slashcancel:")) {
    const token = id.split(":")[1] || "";
    if (token) {
      consumePendingConfirm(token);
    }
    await interaction.update({
      content: "Aksi dibatalkan.",
      embeds: [],
      components: [],
    });
    return true;
  }

  return false;
}

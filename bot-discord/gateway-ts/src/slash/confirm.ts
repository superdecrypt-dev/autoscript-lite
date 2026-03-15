import { ActionRowBuilder, ButtonBuilder, ButtonStyle, EmbedBuilder } from "discord.js";

import { createPendingConfirm } from "../interactions/confirm_state";

export function buildSlashConfirmView(
  domain: string,
  action: string,
  params: Record<string, string>,
  title: string,
  details: string[]
) {
  const token = createPendingConfirm({ domain, action, params });
  const body = details.length > 0 ? details.join("\n") : "Aksi ini akan dijalankan.";

  return {
    embeds: [
      new EmbedBuilder()
        .setTitle("Konfirmasi Aksi")
        .setDescription(`${title}\n\n${body}\n\nLanjutkan?`)
        .setColor(0xd29922),
    ],
    components: [
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`slashconfirm:${token}`).setLabel("Ya, Lanjutkan").setStyle(ButtonStyle.Danger),
        new ButtonBuilder().setCustomId(`slashcancel:${token}`).setLabel("Tidak, Batal").setStyle(ButtonStyle.Secondary)
      ),
    ],
  };
}

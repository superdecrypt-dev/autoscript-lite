import { ChatInputCommandInteraction, Client, MessageFlags } from "discord.js";

import type { BackendClient } from "../api_client";
import { ChannelPolicyStore } from "../channel_policy";
import { handleMenuSlashCommand } from "../interactions/menu";
import { handleNotifySlashCommand } from "./handlers/notify";
import { handleStatusSlashCommand } from "./handlers/status";

export async function handleSlashCommand(
  interaction: ChatInputCommandInteraction,
  deps: { client: Client; backend: BackendClient; channelPolicyStore: ChannelPolicyStore }
): Promise<void> {
  if (interaction.commandName === "menu") {
    await handleMenuSlashCommand(interaction, { client: deps.client, backend: deps.backend });
    return;
  }

  if (interaction.commandName === "status") {
    await handleStatusSlashCommand(interaction, { client: deps.client, backend: deps.backend });
    return;
  }

  if (interaction.commandName === "notify") {
    await handleNotifySlashCommand(interaction, { client: deps.client, channelPolicyStore: deps.channelPolicyStore });
    return;
  }

  await interaction.reply({ content: "Command tidak dikenali.", flags: MessageFlags.Ephemeral });
}

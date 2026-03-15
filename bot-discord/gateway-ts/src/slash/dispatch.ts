import { ChatInputCommandInteraction, Client, MessageFlags } from "discord.js";

import type { BackendClient } from "../api_client";
import { ChannelPolicyStore } from "../channel_policy";
import { handleDomainSlashCommand } from "./handlers/domain";
import { handleNotifySlashCommand } from "./handlers/notify";
import { handleNetworkSlashCommand } from "./handlers/network";
import { handleOpsSlashCommand } from "./handlers/ops";
import { handleQacSlashCommand } from "./handlers/qac";
import { handleStatusSlashCommand } from "./handlers/status";
import { handleUserSlashCommand } from "./handlers/user";

export async function handleSlashCommand(
  interaction: ChatInputCommandInteraction,
  deps: { client: Client; backend: BackendClient; channelPolicyStore: ChannelPolicyStore }
): Promise<void> {
  if (interaction.commandName === "status") {
    await handleStatusSlashCommand(interaction, { client: deps.client, backend: deps.backend });
    return;
  }

  if (interaction.commandName === "ops") {
    await handleOpsSlashCommand(interaction, { backend: deps.backend });
    return;
  }

  if (interaction.commandName === "user") {
    await handleUserSlashCommand(interaction, { backend: deps.backend });
    return;
  }

  if (interaction.commandName === "qac") {
    await handleQacSlashCommand(interaction, { backend: deps.backend });
    return;
  }

  if (interaction.commandName === "domain") {
    await handleDomainSlashCommand(interaction, { backend: deps.backend });
    return;
  }

  if (interaction.commandName === "network") {
    await handleNetworkSlashCommand(interaction, { backend: deps.backend });
    return;
  }

  if (interaction.commandName === "notify") {
    await handleNotifySlashCommand(interaction, { client: deps.client, channelPolicyStore: deps.channelPolicyStore });
    return;
  }

  await interaction.reply({ content: "Command tidak dikenali.", flags: MessageFlags.Ephemeral });
}

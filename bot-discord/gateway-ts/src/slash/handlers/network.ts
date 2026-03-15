import { ChatInputCommandInteraction, MessageFlags } from "discord.js";

import type { BackendClient } from "../../api_client";
import { sendActionResult } from "../../interactions/result";
import { buildSlashConfirmView } from "../confirm";

async function runNetworkAction(
  interaction: ChatInputCommandInteraction,
  backend: BackendClient,
  actionId: string,
  params: Record<string, string>
): Promise<void> {
  await interaction.deferReply({ flags: MessageFlags.Ephemeral });
  const res = await backend.runDomainAction("network", actionId, params);
  await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
}

export async function handleNetworkSlashCommand(
  interaction: ChatInputCommandInteraction,
  deps: { backend: BackendClient }
): Promise<void> {
  const subcommand = interaction.options.getSubcommand(true);

  if (subcommand === "dns-summary") {
    await runNetworkAction(interaction, deps.backend, "dns_summary", {});
    return;
  }

  if (subcommand === "state-file") {
    await runNetworkAction(interaction, deps.backend, "state_file", {});
    return;
  }

  if (subcommand === "set-dns-primary") {
    const dns = String(interaction.options.getString("dns", true) || "").trim();
    await interaction.reply({
      ...buildSlashConfirmView("network", "set_dns_primary", { dns }, "Set DNS primary", [`DNS: **${dns}**`]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "set-dns-secondary") {
    const dns = String(interaction.options.getString("dns", true) || "").trim();
    await interaction.reply({
      ...buildSlashConfirmView("network", "set_dns_secondary", { dns }, "Set DNS secondary", [`DNS: **${dns}**`]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "set-dns-strategy") {
    const strategy = String(interaction.options.getString("strategy", true) || "").trim();
    await interaction.reply({
      ...buildSlashConfirmView("network", "set_dns_strategy", { strategy }, "Set DNS query strategy", [
        `Strategy: **${strategy}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "toggle-dns-cache") {
    await interaction.reply({
      ...buildSlashConfirmView("network", "toggle_dns_cache", {}, "Toggle DNS cache", [
        "DNS cache akan ditoggle sesuai state saat ini.",
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "domain-guard-status") {
    await runNetworkAction(interaction, deps.backend, "domain_guard_status", {});
    return;
  }

  if (subcommand === "domain-guard-check") {
    await runNetworkAction(interaction, deps.backend, "domain_guard_check", {});
    return;
  }

  if (subcommand === "domain-guard-renew") {
    const force = interaction.options.getBoolean("force", false);
    const params: Record<string, string> = {};
    if (force !== null) params.force = force ? "true" : "false";
    await interaction.reply({
      ...buildSlashConfirmView("network", "domain_guard_renew", params, "Renew domain guard", [
        `Force: **${force ? "ON" : "OFF"}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  await interaction.reply({ content: "Subcommand network tidak dikenali.", flags: MessageFlags.Ephemeral });
}

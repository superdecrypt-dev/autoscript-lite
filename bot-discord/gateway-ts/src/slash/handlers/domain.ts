import { ChatInputCommandInteraction, MessageFlags } from "discord.js";

import type { BackendClient } from "../../api_client";
import { sendActionResult } from "../../interactions/result";
import { buildSlashConfirmView } from "../confirm";

async function runDomainAction(
  interaction: ChatInputCommandInteraction,
  backend: BackendClient,
  actionId: string,
  params: Record<string, string>
): Promise<void> {
  await interaction.deferReply({ flags: MessageFlags.Ephemeral });
  const res = await backend.runDomainAction("domain", actionId, params);
  await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
}

export async function handleDomainSlashCommand(
  interaction: ChatInputCommandInteraction,
  deps: { backend: BackendClient }
): Promise<void> {
  const subcommand = interaction.options.getSubcommand(true);

  if (subcommand === "info") {
    await runDomainAction(interaction, deps.backend, "info", {});
    return;
  }

  if (subcommand === "server-name") {
    await runDomainAction(interaction, deps.backend, "server_name", {});
    return;
  }

  if (subcommand === "set-manual") {
    const domain = String(interaction.options.getString("domain", true) || "").trim();
    const params = { domain };
    await interaction.reply({
      ...buildSlashConfirmView("domain", "set_manual", params, "Set domain manual", [
        `Domain: **${domain}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "set-auto") {
    const rootDomain = String(interaction.options.getString("root_domain", true) || "").trim();
    const subdomainMode = String(interaction.options.getString("subdomain_mode", true) || "").trim();
    const subdomain = String(interaction.options.getString("subdomain", false) || "").trim();
    const proxied = interaction.options.getBoolean("proxied", false);
    const allowExisting = interaction.options.getBoolean("allow_existing_same_ip", false);
    const params: Record<string, string> = {
      root_domain: rootDomain,
      subdomain_mode: subdomainMode,
    };
    if (subdomain) params.subdomain = subdomain;
    if (proxied !== null) params.proxied = proxied ? "true" : "false";
    if (allowExisting !== null) params.allow_existing_same_ip = allowExisting ? "true" : "false";

    const details = [
      `Root domain: **${rootDomain}**`,
      `Subdomain mode: **${subdomainMode}**`,
    ];
    if (subdomain) details.push(`Subdomain: **${subdomain}**`);
    if (proxied !== null) details.push(`Proxied: **${proxied ? "ON" : "OFF"}**`);
    if (allowExisting !== null) details.push(`Allow existing same IP: **${allowExisting ? "ON" : "OFF"}**`);

    await interaction.reply({
      ...buildSlashConfirmView("domain", "set_auto", params, "Set domain auto (Cloudflare)", details),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "refresh-accounts") {
    await interaction.reply({
      ...buildSlashConfirmView("domain", "refresh_accounts", {}, "Refresh account info", [
        "Semua file account info akan direfresh sesuai domain aktif.",
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  await interaction.reply({ content: "Subcommand domain tidak dikenali.", flags: MessageFlags.Ephemeral });
}

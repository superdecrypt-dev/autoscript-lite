import { ChatInputCommandInteraction, EmbedBuilder, MessageFlags } from "discord.js";

import type { BackendClient, BackendQacSummary } from "../../api_client";
import { sendActionResult } from "../../interactions/result";
import { buildSlashConfirmView } from "../confirm";

type UserType = "vless" | "vmess" | "trojan" | "ssh";

function isUserType(value: string): value is UserType {
  return value === "vless" || value === "vmess" || value === "trojan" || value === "ssh";
}

function requireUserType(interaction: ChatInputCommandInteraction): UserType | null {
  const raw = String(interaction.options.getString("type", true) || "").trim().toLowerCase();
  return isUserType(raw) ? raw : null;
}

function buildQacSummaryEmbed(type: UserType, summary: BackendQacSummary): EmbedBuilder {
  const isSsh = type === "ssh";
  const fields = [
    { name: "Username", value: summary.username, inline: false },
    { name: "Quota Limit", value: summary.quota_limit, inline: true },
    { name: isSsh ? "Quota Used (SSH)" : "Quota Used", value: summary.quota_used, inline: true },
    { name: "Expired At", value: summary.expired_at, inline: true },
    { name: isSsh ? "IP/Login Limit" : "IP Limit", value: summary.ip_limit, inline: true },
    { name: "Block Reason", value: summary.block_reason, inline: true },
    { name: isSsh ? "IP/Login Limit Max" : "IP Limit Max", value: summary.ip_limit_max, inline: true },
  ];

  if (isSsh) {
    fields.push(
      { name: "IP Unik Aktif", value: summary.distinct_ip_count || "0", inline: true },
      { name: "Daftar IP Aktif", value: summary.distinct_ips || "-", inline: true },
      { name: "IP/Login Metric", value: summary.ip_limit_metric || "0", inline: true },
      { name: "Account Locked", value: summary.account_locked || "OFF", inline: true },
      { name: "Sesi Aktif", value: summary.active_sessions_total || "0", inline: true },
    );
  }

  fields.push(
    { name: "Speed Download", value: summary.speed_download, inline: true },
    { name: "Speed Upload", value: summary.speed_upload, inline: true },
    { name: "Speed Limit", value: summary.speed_limit, inline: true },
  );

  return new EmbedBuilder()
    .setTitle(isSsh ? "SSH QAC Summary" : "Xray QAC Summary")
    .setColor(0x2f81f7)
    .addFields(fields)
    .setTimestamp();
}

async function runQacAction(
  interaction: ChatInputCommandInteraction,
  backend: BackendClient,
  actionId: string,
  params: Record<string, string>
): Promise<void> {
  await interaction.deferReply({ flags: MessageFlags.Ephemeral });
  const res = await backend.runDomainAction("qac", actionId, params);
  await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
}

export async function handleQacSlashCommand(
  interaction: ChatInputCommandInteraction,
  deps: { backend: BackendClient }
): Promise<void> {
  const subcommand = interaction.options.getSubcommand(true);

  if (subcommand === "summary") {
    const scope = String(interaction.options.getString("scope", true) || "").trim().toLowerCase();
    await runQacAction(interaction, deps.backend, "summary", { scope });
    return;
  }

  const type = requireUserType(interaction);
  if (!type) {
    await interaction.reply({ content: "Type user tidak valid.", flags: MessageFlags.Ephemeral });
    return;
  }
  const username = String(interaction.options.getString("username", true) || "").trim();
  const params: Record<string, string> = { type, username };

  if (subcommand === "detail") {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    try {
      const summary = await deps.backend.getQacUserSummary(type, username);
      if (summary) {
        await interaction.editReply({ embeds: [buildQacSummaryEmbed(type, summary)] });
      }
    } catch {
      // Summary is optional; keep the main detail action usable even if the
      // auxiliary summary endpoint is temporarily unavailable.
    }
    const res = await deps.backend.runDomainAction("qac", "detail", params);
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  if (subcommand === "set-quota") {
    params.quota_gb = String(interaction.options.getNumber("quota_gb", true));
    await interaction.reply({
      ...buildSlashConfirmView("qac", "set_quota", params, "Set quota limit", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
        `Quota baru: **${params.quota_gb} GB**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "reset-used") {
    await interaction.reply({
      ...buildSlashConfirmView("qac", "reset_used", params, "Reset quota used", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "toggle-block") {
    params.enabled = interaction.options.getBoolean("enabled", true) ? "true" : "false";
    await interaction.reply({
      ...buildSlashConfirmView("qac", "toggle_block", params, "Toggle manual block", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
        `Enabled: **${params.enabled.toUpperCase()}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "toggle-ip-limit") {
    params.enabled = interaction.options.getBoolean("enabled", true) ? "true" : "false";
    await interaction.reply({
      ...buildSlashConfirmView("qac", "toggle_ip_limit", params, "Toggle IP/Login limit", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
        `Enabled: **${params.enabled.toUpperCase()}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "set-ip-limit") {
    params.ip_limit = String(interaction.options.getInteger("ip_limit", true));
    await interaction.reply({
      ...buildSlashConfirmView("qac", "set_ip_limit", params, "Set IP/Login limit", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
        `Limit: **${params.ip_limit}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "unlock-ip") {
    await interaction.reply({
      ...buildSlashConfirmView("qac", "unlock_ip", params, "Unlock IP/Login lock", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "set-speed-down") {
    params.speed_down_mbit = String(interaction.options.getNumber("mbit", true));
    await interaction.reply({
      ...buildSlashConfirmView("qac", "set_speed_down", params, "Set speed download", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
        `Speed download: **${params.speed_down_mbit} Mbps**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "set-speed-up") {
    params.speed_up_mbit = String(interaction.options.getNumber("mbit", true));
    await interaction.reply({
      ...buildSlashConfirmView("qac", "set_speed_up", params, "Set speed upload", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
        `Speed upload: **${params.speed_up_mbit} Mbps**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "toggle-speed") {
    params.enabled = interaction.options.getBoolean("enabled", true) ? "true" : "false";
    await interaction.reply({
      ...buildSlashConfirmView("qac", "toggle_speed", params, "Toggle speed limit", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
        `Enabled: **${params.enabled.toUpperCase()}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  await interaction.reply({ content: "Subcommand qac tidak dikenali.", flags: MessageFlags.Ephemeral });
}

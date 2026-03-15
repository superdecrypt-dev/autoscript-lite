import { ChatInputCommandInteraction, MessageFlags } from "discord.js";

import type { BackendClient } from "../../api_client";
import { sendActionResult } from "../../interactions/result";
import { buildSlashConfirmView } from "../confirm";

type UserType = "vless" | "vmess" | "trojan" | "ssh";
type SpeedParseResult =
  | { ok: true; enabled: false }
  | { ok: true; enabled: true; down: string; up: string }
  | { ok: false; error: string };

function isUserType(value: string): value is UserType {
  return value === "vless" || value === "vmess" || value === "trojan" || value === "ssh";
}

function parseSpeedLimitInput(raw: string): SpeedParseResult {
  const value = String(raw || "").trim().toLowerCase();
  if (!value || value === "0" || value === "-" || value === "off" || value === "disable" || value === "disabled" || value === "none") {
    return { ok: true, enabled: false };
  }

  const cleaned = value.replace(/\s+/g, "");
  const parts = cleaned.split("/");
  if (parts.length > 2) {
    return { ok: false, error: "Format speed limit tidak valid. Gunakan off, 20, atau 20/10." };
  }

  const parsePositive = (input: string): number | null => {
    const n = Number(input);
    if (!Number.isFinite(n) || n <= 0) return null;
    return n;
  };

  if (parts.length === 1) {
    const symmetric = parsePositive(parts[0]);
    if (symmetric === null) {
      return { ok: false, error: "Speed limit harus angka > 0. Contoh: 20 atau 20/10." };
    }
    return { ok: true, enabled: true, down: `${symmetric}`, up: `${symmetric}` };
  }

  const down = parsePositive(parts[0]);
  const up = parsePositive(parts[1]);
  if (down === null || up === null) {
    return { ok: false, error: "Speed limit down/up harus angka > 0. Contoh: 20/10." };
  }

  return { ok: true, enabled: true, down: `${down}`, up: `${up}` };
}

function requireUserType(interaction: ChatInputCommandInteraction): UserType | null {
  const raw = String(interaction.options.getString("type", true) || "").trim().toLowerCase();
  return isUserType(raw) ? raw : null;
}

async function runBackendAction(
  interaction: ChatInputCommandInteraction,
  backend: BackendClient,
  actionId: string,
  params: Record<string, string>
): Promise<void> {
  await interaction.deferReply({ flags: MessageFlags.Ephemeral });
  const res = await backend.runDomainAction("users", actionId, params);
  await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
}

export async function handleUserSlashCommand(
  interaction: ChatInputCommandInteraction,
  deps: { backend: BackendClient }
): Promise<void> {
  const subcommand = interaction.options.getSubcommand(true);

  if (subcommand === "reset-password") {
    const username = String(interaction.options.getString("username", true) || "").trim();
    const password = String(interaction.options.getString("password", true) || "").trim();
    const params = { type: "ssh", username, password };
    await interaction.reply({
      ...buildSlashConfirmView("users", "reset_password", params, "Reset password SSH", [`Username: **${username}**`]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  const type = requireUserType(interaction);
  if (!type) {
    await interaction.reply({ content: "Type user tidak valid.", flags: MessageFlags.Ephemeral });
    return;
  }

  if (subcommand === "add") {
    const username = String(interaction.options.getString("username", true) || "").trim();
    const days = interaction.options.getInteger("days", true);
    const quotaGb = interaction.options.getNumber("quota_gb", true);
    const ipLimit = interaction.options.getInteger("ip_limit", false) ?? 0;
    const speedLimitRaw = String(interaction.options.getString("speed_limit", false) || "").trim();
    const password = String(interaction.options.getString("password", false) || "").trim();

    const params: Record<string, string> = {
      type,
      username,
      days: String(days),
      quota_gb: String(quotaGb),
    };
    if (type === "ssh") {
      if (!password) {
        await interaction.reply({ content: "Password wajib diisi untuk user SSH.", flags: MessageFlags.Ephemeral });
        return;
      }
      params.password = password;
    }
    if (ipLimit > 0) {
      params.ip_limit_enabled = "true";
      params.ip_limit = String(ipLimit);
    }

    const parsedSpeed = parseSpeedLimitInput(speedLimitRaw);
    if (!parsedSpeed.ok) {
      await interaction.reply({ content: parsedSpeed.error, flags: MessageFlags.Ephemeral });
      return;
    }
    if (parsedSpeed.enabled) {
      params.speed_limit_enabled = "true";
      params.speed_down_mbit = parsedSpeed.down;
      params.speed_up_mbit = parsedSpeed.up;
    }

    const details = [
      `Type: **${type.toUpperCase()}**`,
      `Username: **${username}**`,
      `Masa aktif: **${days} hari**`,
      `Quota: **${quotaGb} GB**`,
    ];
    if (ipLimit > 0) details.push(`IP/Login Limit: **${ipLimit}**`);
    if (parsedSpeed.ok && parsedSpeed.enabled) {
      details.push(`Speed Limit: **DOWN ${parsedSpeed.down} Mbps | UP ${parsedSpeed.up} Mbps**`);
    }

    await interaction.reply({
      ...buildSlashConfirmView("users", "add", params, "Buat user baru", details),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "info") {
    const username = String(interaction.options.getString("username", true) || "").trim();
    const params: Record<string, string> = { type, username };
    await runBackendAction(interaction, deps.backend, "info", params);
    return;
  }

  if (subcommand === "delete") {
    const username = String(interaction.options.getString("username", true) || "").trim();
    const params: Record<string, string> = { type, username };
    await interaction.reply({
      ...buildSlashConfirmView("users", "delete", params, "Hapus user", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  if (subcommand === "extend") {
    const username = String(interaction.options.getString("username", true) || "").trim();
    const days = interaction.options.getInteger("days", true);
    const params: Record<string, string> = {
      type,
      username,
      days: String(days),
    };
    await interaction.reply({
      ...buildSlashConfirmView("users", "extend", params, "Perpanjang masa aktif user", [
        `Type: **${type.toUpperCase()}**`,
        `Username: **${username}**`,
        `Tambah masa aktif: **${days} hari**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return;
  }

  await interaction.reply({ content: "Subcommand user tidak dikenali.", flags: MessageFlags.Ephemeral });
}

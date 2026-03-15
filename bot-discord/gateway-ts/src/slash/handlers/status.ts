import * as os from "node:os";

import { ChatInputCommandInteraction, Client, EmbedBuilder, MessageFlags } from "discord.js";

import type { BackendClient } from "../../api_client";
import { sendActionResult } from "../../interactions/result";

function formatDuration(secondsRaw: number): string {
  const total = Math.max(0, Math.floor(secondsRaw));
  const days = Math.floor(total / 86_400);
  const hours = Math.floor((total % 86_400) / 3_600);
  const minutes = Math.floor((total % 3_600) / 60);
  return `${days}d ${hours}h ${minutes}m`;
}

function formatGiB(bytes: number): string {
  const gib = bytes / (1024 ** 3);
  return `${gib.toFixed(2)} GiB`;
}

function formatError(err: unknown): string {
  if (err instanceof Error) {
    return `${err.name}: ${err.message}`;
  }
  return String(err);
}

export async function buildOverviewStatusEmbed(client: Client, backend: BackendClient): Promise<EmbedBuilder> {
  const wsPingRaw = client.ws.ping;
  const wsPingText = Number.isFinite(wsPingRaw) && wsPingRaw >= 0 ? `${Math.round(wsPingRaw)} ms` : "n/a";
  const hostUptime = formatDuration(os.uptime());
  const load = os.loadavg().map((n) => n.toFixed(2)).join(" ");
  const totalMem = os.totalmem();
  const freeMem = os.freemem();
  const usedMem = Math.max(0, totalMem - freeMem);

  let healthPass = false;
  const healthStarted = Date.now();
  let healthLine = "Backend /health: FAIL";
  try {
    const health = await backend.getHealth();
    const elapsed = Date.now() - healthStarted;
    const status = String(health.status ?? "-");
    healthPass = status === "ok";
    healthLine = `Backend /health: ${healthPass ? "PASS" : "FAIL"} (status=${status}, ${elapsed} ms)`;
  } catch (err) {
    const elapsed = Date.now() - healthStarted;
    healthLine = `Backend /health: FAIL (${formatError(err)}, ${elapsed} ms)`;
  }

  return new EmbedBuilder()
    .setTitle("Status Overview")
    .setDescription(healthPass ? "STATUS: PASS" : "STATUS: FAIL")
    .setColor(healthPass ? 0x2ecc71 : 0xe74c3c)
    .addFields(
      {
        name: "Connectivity",
        value: `Discord WS: ${wsPingText}`,
        inline: false,
      },
      {
        name: "Host Runtime",
        value: `Uptime: ${hostUptime}\nLoad avg (1/5/15): ${load}\nMemory: ${formatGiB(usedMem)} / ${formatGiB(totalMem)}`,
        inline: false,
      },
      {
        name: "Backend",
        value: healthLine,
        inline: false,
      },
    )
    .setTimestamp();
}

export async function handleStatusSlashCommand(
  interaction: ChatInputCommandInteraction,
  deps: { client: Client; backend: BackendClient }
): Promise<void> {
  const subcommand = interaction.options.getSubcommand(true);

  if (subcommand === "overview") {
    const embed = await buildOverviewStatusEmbed(deps.client, deps.backend);
    await interaction.reply({ embeds: [embed], flags: MessageFlags.Ephemeral });
    return;
  }

  await interaction.deferReply({ flags: MessageFlags.Ephemeral });

  if (subcommand === "services") {
    const res = await deps.backend.runDomainAction("status", "services");
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  if (subcommand === "tls") {
    const res = await deps.backend.runDomainAction("status", "tls");
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  if (subcommand === "xray-test") {
    const res = await deps.backend.runDomainAction("status", "xray_test");
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    return;
  }

  await interaction.editReply("Subcommand status tidak dikenali.");
}

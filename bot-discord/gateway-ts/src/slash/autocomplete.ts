import { AutocompleteInteraction } from "discord.js";

import type { BackendClient, BackendRootDomainOption, BackendUserOption } from "../api_client";

const MAX_CHOICES = 25;
const OPS_SERVICE_OPTIONS = [
  { name: "xray", value: "xray" },
  { name: "nginx", value: "nginx" },
] as const;
const DNS_OPTIONS = [
  { name: "Cloudflare 1.1.1.1", value: "1.1.1.1" },
  { name: "Cloudflare 1.0.0.1", value: "1.0.0.1" },
  { name: "Google 8.8.8.8", value: "8.8.8.8" },
  { name: "Google 8.8.4.4", value: "8.8.4.4" },
  { name: "Quad9 9.9.9.9", value: "9.9.9.9" },
  { name: "Quad9 149.112.112.112", value: "149.112.112.112" },
  { name: "OpenDNS 208.67.222.222", value: "208.67.222.222" },
  { name: "OpenDNS 208.67.220.220", value: "208.67.220.220" },
] as const;

function normalizeQuery(value: string): string {
  return value.trim().toLowerCase();
}

function filterChoices(
  focusedRaw: string,
  values: Array<{ name: string; value: string }>
): Array<{ name: string; value: string }> {
  const focused = normalizeQuery(focusedRaw);
  const starts: Array<{ name: string; value: string }> = [];
  const includes: Array<{ name: string; value: string }> = [];
  const seen = new Set<string>();

  for (const item of values) {
    if (seen.has(item.value)) continue;
    const hay = normalizeQuery(item.name);
    if (!focused || hay.startsWith(focused)) {
      seen.add(item.value);
      starts.push(item);
      continue;
    }
    if (hay.includes(focused)) {
      seen.add(item.value);
      includes.push(item);
    }
  }

  return [...starts, ...includes].slice(0, MAX_CHOICES);
}

function mapUserChoices(users: BackendUserOption[]): Array<{ name: string; value: string }> {
  return users
    .filter((item) => item && typeof item.username === "string" && item.username.trim())
    .map((item) => ({
      name: item.username.trim(),
      value: item.username.trim(),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

function mapRootDomainChoices(roots: BackendRootDomainOption[]): Array<{ name: string; value: string }> {
  return roots
    .filter((item) => item && typeof item.root_domain === "string" && item.root_domain.trim())
    .map((item) => ({
      name: item.root_domain.trim(),
      value: item.root_domain.trim(),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function autocompleteUsernames(
  interaction: AutocompleteInteraction,
  backend: BackendClient,
  forcedProto?: string
): Promise<void> {
  const focused = interaction.options.getFocused(true);
  const proto = forcedProto || String(interaction.options.getString("type", false) || "").trim().toLowerCase();
  const users = await backend.listUserOptions(proto || undefined);
  await interaction.respond(filterChoices(String(focused.value || ""), mapUserChoices(users)));
}

export async function handleSlashAutocomplete(
  interaction: AutocompleteInteraction,
  deps: { backend: BackendClient }
): Promise<void> {
  const focused = interaction.options.getFocused(true);

  if (focused.name === "username") {
    if (interaction.commandName === "user") {
      const subcommand = interaction.options.getSubcommand(true);
      const forcedProto = subcommand === "reset-password" ? "ssh" : undefined;
      await autocompleteUsernames(interaction, deps.backend, forcedProto);
      return;
    }
    if (interaction.commandName === "qac") {
      await autocompleteUsernames(interaction, deps.backend);
      return;
    }
  }

  if (interaction.commandName === "domain" && focused.name === "root_domain") {
    const roots = await deps.backend.listDomainRootOptions();
    await interaction.respond(filterChoices(String(focused.value || ""), mapRootDomainChoices(roots)));
    return;
  }

  if (interaction.commandName === "ops" && focused.name === "service") {
    await interaction.respond(filterChoices(String(focused.value || ""), [...OPS_SERVICE_OPTIONS]));
    return;
  }

  if (interaction.commandName === "ops" && focused.name === "query") {
    const users = await deps.backend.listUserOptions();
    await interaction.respond(filterChoices(String(focused.value || ""), mapUserChoices(users)));
    return;
  }

  if (interaction.commandName === "network" && focused.name === "dns") {
    await interaction.respond(filterChoices(String(focused.value || ""), [...DNS_OPTIONS]));
    return;
  }

  await interaction.respond([]);
}

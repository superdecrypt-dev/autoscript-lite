import {
  Client,
  Events,
  GatewayIntentBits,
  Interaction,
  MessageFlags,
  REST,
  Routes,
  type AutocompleteInteraction,
  type ChatInputCommandInteraction,
} from "discord.js";

import { BackendClient } from "./api_client";
import { isAuthorized } from "./authz";
import { ChannelPolicyStore } from "./channel_policy";
import { loadConfig } from "./config";
import { handleButton } from "./interactions/buttons";
import { handleSlashAutocomplete } from "./slash/autocomplete";
import { handleSlashCommand } from "./slash/dispatch";
import { handleNotifyControlButton, sendServiceNotification } from "./slash/handlers/notify";
import { buildSlashCommands } from "./slash/registry";

const cfg = loadConfig();
const backend = new BackendClient(cfg.backendBaseUrl, cfg.sharedSecret);
const channelPolicyStore = new ChannelPolicyStore(cfg.channelPolicyFile);

let notifSchedulerBusy = false;
let notifLastWarnAtMs = 0;

const client = new Client({ intents: [GatewayIntentBits.Guilds] });

async function registerSlashCommands(): Promise<void> {
  const commands = buildSlashCommands();
  const rest = new REST({ version: "10" }).setToken(cfg.token);
  await rest.put(Routes.applicationGuildCommands(cfg.applicationId, cfg.guildId), { body: commands });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getDiscordErrorCode(err: unknown): number | null {
  if (!err || typeof err !== "object") return null;
  const maybe = (err as { code?: unknown }).code;
  return typeof maybe === "number" ? maybe : null;
}

function isIgnorableInteractionError(err: unknown): boolean {
  const code = getDiscordErrorCode(err);
  return code === 10062 || code === 40060;
}

function formatError(err: unknown): string {
  if (err instanceof Error) {
    return `${err.name}: ${err.message}`;
  }
  return String(err);
}

async function safeReplyEphemeral(interaction: Interaction, content: string): Promise<void> {
  if (!interaction.isRepliable()) return;
  try {
    if (interaction.replied || interaction.deferred) {
      await interaction.followUp({ content, flags: MessageFlags.Ephemeral });
    } else {
      await interaction.reply({ content, flags: MessageFlags.Ephemeral });
    }
  } catch (err) {
    if (isIgnorableInteractionError(err)) {
      console.warn(`[gateway] skip interaction reply (ack/expired): ${formatError(err)}`);
      return;
    }
    throw err;
  }
}

async function registerSlashCommandsWithRetry(maxAttempts = 5): Promise<boolean> {
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      await registerSlashCommands();
      if (attempt > 1) {
        console.log(`[gateway] slash command registration succeeded on retry ${attempt}/${maxAttempts}.`);
      }
      return true;
    } catch (err) {
      const errText = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
      console.error(`[gateway] failed to register slash commands (${attempt}/${maxAttempts}): ${errText}`);
      if (attempt >= maxAttempts) {
        return false;
      }
      await sleep(Math.min(2000 * attempt, 10000));
    }
  }
  return false;
}

async function assertAuthorized(interaction: ChatInputCommandInteraction): Promise<boolean> {
  const member = interaction.inGuild() ? interaction.member : null;
  if (!interaction.inGuild() || !isAuthorized(member, interaction.user.id, cfg)) {
    await interaction.reply({ content: "Akses ditolak. Hubungi admin.", flags: MessageFlags.Ephemeral });
    return false;
  }
  return true;
}

function isAuthorizedAutocomplete(interaction: AutocompleteInteraction): boolean {
  const member = interaction.inGuild() ? interaction.member : null;
  return interaction.inGuild() && isAuthorized(member, interaction.user.id, cfg);
}

async function runNotifSchedulerTick(): Promise<void> {
  if (notifSchedulerBusy) return;
  notifSchedulerBusy = true;
  try {
    if (!channelPolicyStore.getAutoStatusEnabled()) return;
    if (!channelPolicyStore.getControlChannelId()) return;

    const intervalMinutes = channelPolicyStore.getAutoStatusIntervalMinutes();
    const lastSentAtRaw = channelPolicyStore.getLastAutoStatusAt();
    if (lastSentAtRaw) {
      const lastSentMs = Date.parse(lastSentAtRaw);
      if (Number.isFinite(lastSentMs)) {
        const diff = Date.now() - lastSentMs;
        if (diff < intervalMinutes * 60 * 1_000) return;
      }
    }

    const sent = await sendServiceNotification(client, channelPolicyStore, "auto");
    if (!sent.ok) {
      const now = Date.now();
      if (now - notifLastWarnAtMs >= 10 * 60 * 1_000) {
        notifLastWarnAtMs = now;
        console.warn(`[gateway] auto notifier skipped: ${sent.message}`);
      }
    }
  } finally {
    notifSchedulerBusy = false;
  }
}

function startNotifScheduler(): void {
  setInterval(() => {
    void runNotifSchedulerTick();
  }, 60_000);
  void runNotifSchedulerTick();
}

client.once(Events.ClientReady, async (ready) => {
  console.log(`[gateway] logged in as ${ready.user.tag}`);
  const registered = await registerSlashCommandsWithRetry();
  if (registered) {
    console.log("[gateway] slash commands registered: /status, /user, /qac, /domain, /network, /ops, /notify.");
  } else {
    console.error("[gateway] slash command registration failed after retries; bot continues running.");
  }
  startNotifScheduler();
  console.log("[gateway] notifier scheduler started (tick=60s).");
});

client.on(Events.InteractionCreate, async (interaction) => {
  try {
    if (interaction.isAutocomplete()) {
      if (!isAuthorizedAutocomplete(interaction)) {
        await interaction.respond([]);
        return;
      }
      await handleSlashAutocomplete(interaction, { backend });
      return;
    }

    if (interaction.isChatInputCommand()) {
      if (!(await assertAuthorized(interaction))) return;
      await handleSlashCommand(interaction, { client, backend, channelPolicyStore });
      return;
    }

    if (interaction.isButton()) {
      if (!interaction.inGuild() || !isAuthorized(interaction.member, interaction.user.id, cfg)) {
        await interaction.reply({ content: "Akses ditolak.", flags: MessageFlags.Ephemeral });
        return;
      }
      const notifHandled = await handleNotifyControlButton(interaction, { client, channelPolicyStore });
      if (notifHandled) return;
      const handled = await handleButton(interaction, backend);
      if (!handled && !interaction.replied) {
        await interaction.reply({ content: "Aksi tidak dikenali.", flags: MessageFlags.Ephemeral });
      }
      return;
    }

    if (interaction.isModalSubmit()) {
      if (!interaction.inGuild() || !isAuthorized(interaction.member, interaction.user.id, cfg)) {
        await interaction.reply({ content: "Akses ditolak.", flags: MessageFlags.Ephemeral });
        return;
      }
      await interaction.reply({
        content: "Form legacy tidak lagi didukung. Gunakan slash command aktif.",
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    if (interaction.isStringSelectMenu()) {
      if (!interaction.inGuild() || !isAuthorized(interaction.member, interaction.user.id, cfg)) {
        await interaction.reply({ content: "Akses ditolak.", flags: MessageFlags.Ephemeral });
        return;
      }
      await interaction.reply({
        content: "Select menu legacy tidak lagi didukung. Gunakan slash command aktif.",
        flags: MessageFlags.Ephemeral,
      });
    }
  } catch (err) {
    if (isIgnorableInteractionError(err)) {
      console.warn(`[gateway] interaction warning (ack/expired): ${formatError(err)}`);
      return;
    }
    const text = `Terjadi kesalahan: ${formatError(err)}`;
    await safeReplyEphemeral(interaction, text);
  }
});

client.login(cfg.token);

import { MessageFlags, ModalSubmitInteraction } from "discord.js";

import type { BackendClient } from "../api_client";
import { sendActionResult } from "./result";
import { buildSlashConfirmView } from "../slash/confirm";
import { menuConstants, type MenuUserContext } from "./menu";
import { createMenuState, getMenuState } from "./menu_state";
import { buildPurgeConfirmView } from "./purge";

function readField(interaction: ModalSubmitInteraction, fieldId: string): string {
  return interaction.fields.getTextInputValue(fieldId).trim();
}

function isUserType(value: string): value is MenuUserContext["type"] {
  return value === "vless" || value === "vmess" || value === "trojan" || value === "ssh";
}

export async function handleMenuModal(interaction: ModalSubmitInteraction, backend: BackendClient): Promise<boolean> {
  if (interaction.customId === menuConstants.DOMAIN_SET_MANUAL_MODAL_ID) {
    const domain = readField(interaction, "domain");
    if (!domain) {
      await interaction.reply({ content: "Domain wajib diisi.", flags: MessageFlags.Ephemeral });
      return true;
    }

    await interaction.reply({
      ...buildSlashConfirmView("domain", "set_manual", { domain }, "Set Domain Manual", [`Domain: ${domain}`]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId.startsWith(menuConstants.DOMAIN_SET_AUTO_MODAL_PREFIX)) {
    const token = interaction.customId.slice(menuConstants.DOMAIN_SET_AUTO_MODAL_PREFIX.length);
    const ctx = getMenuState<{ rootDomain: string }>(token);
    if (!ctx) {
      await interaction.reply({ content: "Context root domain kadaluarsa. Buka /menu lagi.", flags: MessageFlags.Ephemeral });
      return true;
    }

    const subdomainMode = readField(interaction, "subdomain_mode");
    if (!subdomainMode) {
      await interaction.reply({ content: "Subdomain mode wajib diisi.", flags: MessageFlags.Ephemeral });
      return true;
    }

    const subdomain = readField(interaction, "subdomain");
    const proxied = readField(interaction, "proxied");
    const allowExistingSameIp = readField(interaction, "allow_existing_same_ip");
    const params: Record<string, string> = {
      root_domain: ctx.rootDomain,
      subdomain_mode: subdomainMode,
    };
    if (subdomain) params.subdomain = subdomain;
    if (proxied) params.proxied = proxied;
    if (allowExistingSameIp) params.allow_existing_same_ip = allowExistingSameIp;

    await interaction.reply({
      ...buildSlashConfirmView("domain", "set_auto", params, "Set domain auto (Cloudflare)", [
        `Root domain: **${ctx.rootDomain}**`,
        `Subdomain mode: **${subdomainMode}**`,
        ...(subdomain ? [`Subdomain: **${subdomain}**`] : []),
        ...(proxied ? [`Proxied: **${proxied}**`] : []),
        ...(allowExistingSameIp ? [`Allow existing same IP: **${allowExistingSameIp}**`] : []),
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId === menuConstants.NETWORK_SET_DNS_PRIMARY_MODAL_ID) {
    const dns = readField(interaction, "dns");
    if (!dns) {
      await interaction.reply({ content: "DNS primary wajib diisi.", flags: MessageFlags.Ephemeral });
      return true;
    }
    await interaction.reply({
      ...buildSlashConfirmView("network", "set_dns_primary", { dns }, "Set DNS primary", [`DNS: **${dns}**`]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId === menuConstants.NETWORK_SET_DNS_SECONDARY_MODAL_ID) {
    const dns = readField(interaction, "dns");
    if (!dns) {
      await interaction.reply({ content: "DNS secondary wajib diisi.", flags: MessageFlags.Ephemeral });
      return true;
    }
    await interaction.reply({
      ...buildSlashConfirmView("network", "set_dns_secondary", { dns }, "Set DNS secondary", [`DNS: **${dns}**`]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId === menuConstants.OPS_TRAFFIC_SEARCH_MODAL_ID) {
    const query = readField(interaction, "query");
    if (!query) {
      await interaction.reply({ content: "Query wajib diisi.", flags: MessageFlags.Ephemeral });
      return true;
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    try {
      const res = await backend.runDomainAction("ops", "traffic_search", { query });
      await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    } catch (err) {
      await sendActionResult(interaction, "Backend Error", String(err), false);
    }
    return true;
  }

  if (interaction.customId === menuConstants.OPS_TRAFFIC_TOP_MODAL_ID) {
    const limit = readField(interaction, "limit");
    if (!limit) {
      await interaction.reply({ content: "Limit wajib diisi.", flags: MessageFlags.Ephemeral });
      return true;
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    try {
      const res = await backend.runDomainAction("ops", "traffic_top", { limit });
      await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    } catch (err) {
      await sendActionResult(interaction, "Backend Error", String(err), false);
    }
    return true;
  }

  if (interaction.customId === menuConstants.OPS_PURGE_MODAL_ID) {
    const mode = readField(interaction, "mode");
    const amount = readField(interaction, "amount");
    const normalizedMode = mode === "all_messages" ? "all_messages" : mode === "bot_only" ? "bot_only" : "";
    const amountValue = Number.parseInt(amount, 10);
    if (!normalizedMode) {
      await interaction.reply({
        content: "Mode purge harus `bot_only` atau `all_messages`.",
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }
    if (!Number.isFinite(amountValue) || amountValue < 1) {
      await interaction.reply({
        content: "Jumlah pesan harus berupa angka positif.",
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }
    const token = createMenuState<{ mode: "bot_only" | "all_messages"; amount: number }>({
      mode: normalizedMode,
      amount: Math.min(amountValue, 1000),
    });
    await interaction.reply({
      ...buildPurgeConfirmView(token, normalizedMode, Math.min(amountValue, 1000)),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId.startsWith(menuConstants.USER_ADD_MODAL_PREFIX)) {
    const scope = interaction.customId.slice(menuConstants.USER_ADD_MODAL_PREFIX.length);
    if (scope !== "xray" && scope !== "ssh") {
      await interaction.reply({ content: "Scope user tidak valid.", flags: MessageFlags.Ephemeral });
      return true;
    }

    const username = readField(interaction, "username");
    const days = readField(interaction, "days");
    const quotaGb = readField(interaction, "quota_gb");
    const ipLimit = readField(interaction, "ip_limit");

    const params: Record<string, string> = {
      type: scope === "ssh" ? "ssh" : readField(interaction, "type").toLowerCase(),
      username,
      days,
      quota_gb: quotaGb,
    };

    if (scope === "ssh") {
      params.type = "ssh";
      params.password = readField(interaction, "password");
    } else if (!isUserType(params.type) || params.type === "ssh") {
      await interaction.reply({ content: "Type Xray harus vless, vmess, atau trojan.", flags: MessageFlags.Ephemeral });
      return true;
    }

    if (ipLimit) {
      params.ip_limit = ipLimit;
    }

    await interaction.reply({
      ...buildSlashConfirmView("users", "add", params, "Buat user baru", [
        `Type: **${params.type.toUpperCase()}**`,
        `Username: **${username}**`,
        `Masa aktif: **${days} hari**`,
        `Quota: **${quotaGb} GB**`,
        ...(ipLimit ? [`IP/Login Limit: **${ipLimit}**`] : []),
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId.startsWith(menuConstants.USER_EXTEND_MODAL_PREFIX)) {
    const token = interaction.customId.slice(menuConstants.USER_EXTEND_MODAL_PREFIX.length);
    const ctx = getMenuState<MenuUserContext>(token);
    if (!ctx) {
      await interaction.reply({ content: "Context user kadaluarsa. Buka /menu lagi.", flags: MessageFlags.Ephemeral });
      return true;
    }
    const days = readField(interaction, "days");
    await interaction.reply({
      ...buildSlashConfirmView("users", "extend", { type: ctx.type, username: ctx.username, days }, "Perpanjang masa aktif user", [
        `Type: **${ctx.type.toUpperCase()}**`,
        `Username: **${ctx.username}**`,
        `Tambah masa aktif: **${days} hari**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId.startsWith(menuConstants.USER_RESET_PASSWORD_MODAL_PREFIX)) {
    const token = interaction.customId.slice(menuConstants.USER_RESET_PASSWORD_MODAL_PREFIX.length);
    const ctx = getMenuState<MenuUserContext>(token);
    if (!ctx) {
      await interaction.reply({ content: "Context user kadaluarsa. Buka /menu lagi.", flags: MessageFlags.Ephemeral });
      return true;
    }
    const password = readField(interaction, "password");
    await interaction.reply({
      ...buildSlashConfirmView("users", "reset_password", { type: "ssh", username: ctx.username, password }, "Reset password SSH", [
        `Username: **${ctx.username}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId.startsWith(menuConstants.QAC_SET_QUOTA_MODAL_PREFIX)) {
    const token = interaction.customId.slice(menuConstants.QAC_SET_QUOTA_MODAL_PREFIX.length);
    const ctx = getMenuState<MenuUserContext>(token);
    if (!ctx) {
      await interaction.reply({ content: "Context QAC kadaluarsa. Pilih user lagi dari /menu.", flags: MessageFlags.Ephemeral });
      return true;
    }
    const quotaGb = readField(interaction, "quota_gb");
    await interaction.reply({
      ...buildSlashConfirmView("qac", "set_quota", { type: ctx.type, username: ctx.username, quota_gb: quotaGb }, "Set quota limit", [
        `Type: **${ctx.type.toUpperCase()}**`,
        `Username: **${ctx.username}**`,
        `Quota baru: **${quotaGb} GB**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId.startsWith(menuConstants.QAC_SET_IP_LIMIT_MODAL_PREFIX)) {
    const token = interaction.customId.slice(menuConstants.QAC_SET_IP_LIMIT_MODAL_PREFIX.length);
    const ctx = getMenuState<MenuUserContext>(token);
    if (!ctx) {
      await interaction.reply({ content: "Context QAC kadaluarsa. Pilih user lagi dari /menu.", flags: MessageFlags.Ephemeral });
      return true;
    }
    const ipLimit = readField(interaction, "ip_limit");
    await interaction.reply({
      ...buildSlashConfirmView("qac", "set_ip_limit", { type: ctx.type, username: ctx.username, ip_limit: ipLimit }, "Set IP/Login limit", [
        `Type: **${ctx.type.toUpperCase()}**`,
        `Username: **${ctx.username}**`,
        `Limit: **${ipLimit}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId.startsWith(menuConstants.QAC_SET_SPEED_DOWN_MODAL_PREFIX)) {
    const token = interaction.customId.slice(menuConstants.QAC_SET_SPEED_DOWN_MODAL_PREFIX.length);
    const ctx = getMenuState<MenuUserContext>(token);
    if (!ctx) {
      await interaction.reply({ content: "Context QAC kadaluarsa. Pilih user lagi dari /menu.", flags: MessageFlags.Ephemeral });
      return true;
    }
    const mbit = readField(interaction, "mbit");
    await interaction.reply({
      ...buildSlashConfirmView("qac", "set_speed_down", { type: ctx.type, username: ctx.username, speed_down_mbit: mbit }, "Set speed download", [
        `Type: **${ctx.type.toUpperCase()}**`,
        `Username: **${ctx.username}**`,
        `Speed download: **${mbit} Mbps**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (interaction.customId.startsWith(menuConstants.QAC_SET_SPEED_UP_MODAL_PREFIX)) {
    const token = interaction.customId.slice(menuConstants.QAC_SET_SPEED_UP_MODAL_PREFIX.length);
    const ctx = getMenuState<MenuUserContext>(token);
    if (!ctx) {
      await interaction.reply({ content: "Context QAC kadaluarsa. Pilih user lagi dari /menu.", flags: MessageFlags.Ephemeral });
      return true;
    }
    const mbit = readField(interaction, "mbit");
    await interaction.reply({
      ...buildSlashConfirmView("qac", "set_speed_up", { type: ctx.type, username: ctx.username, speed_up_mbit: mbit }, "Set speed upload", [
        `Type: **${ctx.type.toUpperCase()}**`,
        `Username: **${ctx.username}**`,
        `Speed upload: **${mbit} Mbps**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  return false;
}

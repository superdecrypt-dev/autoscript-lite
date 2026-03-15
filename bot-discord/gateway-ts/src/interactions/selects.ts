import {
  ActionRowBuilder,
  MessageFlags,
  ModalBuilder,
  StringSelectMenuInteraction,
  TextInputBuilder,
  TextInputStyle,
} from "discord.js";

import type { BackendClient } from "../api_client";
import { sendActionResult } from "./result";
import { buildSlashConfirmView } from "../slash/confirm";
import { buildQacPanelView, menuConstants, type MenuUserContext } from "./menu";
import { createMenuState } from "./menu_state";

function parseUserValue(raw: string): { proto: string; username: string } | null {
  const [proto, username] = raw.split("|", 2);
  if (!proto || !username) return null;
  return { proto, username };
}

function showSingleFieldModal(interaction: StringSelectMenuInteraction, customId: string, title: string, fieldId: string, fieldLabel: string, placeholder: string) {
  const modal = new ModalBuilder().setCustomId(customId).setTitle(title);
  modal.addComponents(
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId(fieldId)
        .setLabel(fieldLabel)
        .setRequired(true)
        .setPlaceholder(placeholder)
        .setStyle(TextInputStyle.Short),
    ),
  );
  return interaction.showModal(modal);
}

export async function handleMenuSelect(interaction: StringSelectMenuInteraction, backend: BackendClient): Promise<boolean> {
  const id = interaction.customId;
  const selected = interaction.values[0] || "";
  const parsed = parseUserValue(selected);

  if (id === menuConstants.DOMAIN_SET_AUTO_ROOT_SELECT_ID) {
    const rootDomain = selected.trim();
    if (!rootDomain) {
      await interaction.reply({ content: "Root domain tidak valid.", flags: MessageFlags.Ephemeral });
      return true;
    }

    const token = createMenuState<{ rootDomain: string }>({ rootDomain });
    const modal = new ModalBuilder().setCustomId(`${menuConstants.DOMAIN_SET_AUTO_MODAL_PREFIX}${token}`).setTitle("Set Domain Auto");
    modal.addComponents(
      new ActionRowBuilder<TextInputBuilder>().addComponents(
        new TextInputBuilder()
          .setCustomId("subdomain_mode")
          .setLabel("Subdomain Mode")
          .setRequired(true)
          .setPlaceholder("auto / manual")
          .setStyle(TextInputStyle.Short),
      ),
      new ActionRowBuilder<TextInputBuilder>().addComponents(
        new TextInputBuilder()
          .setCustomId("subdomain")
          .setLabel("Subdomain (opsional)")
          .setRequired(false)
          .setPlaceholder("kosongkan jika auto")
          .setStyle(TextInputStyle.Short),
      ),
      new ActionRowBuilder<TextInputBuilder>().addComponents(
        new TextInputBuilder()
          .setCustomId("proxied")
          .setLabel("Cloudflare Proxy")
          .setRequired(false)
          .setPlaceholder("true / false")
          .setStyle(TextInputStyle.Short),
      ),
      new ActionRowBuilder<TextInputBuilder>().addComponents(
        new TextInputBuilder()
          .setCustomId("allow_existing_same_ip")
          .setLabel("Allow Existing Same IP")
          .setRequired(false)
          .setPlaceholder("true / false")
          .setStyle(TextInputStyle.Short),
      ),
    );
    await interaction.showModal(modal);
    return true;
  }

  if (id === menuConstants.NETWORK_SET_DNS_STRATEGY_SELECT_ID) {
    const strategy = selected.trim();
    if (!strategy) {
      await interaction.reply({ content: "Strategy DNS tidak valid.", flags: MessageFlags.Ephemeral });
      return true;
    }

    await interaction.reply({
      ...buildSlashConfirmView("network", "set_dns_strategy", { strategy }, "Set DNS query strategy", [
        `Strategy: **${strategy}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (id.startsWith(menuConstants.USER_INFO_SELECT_PREFIX)) {
    if (!parsed) {
      await interaction.reply({ content: "User tidak valid.", flags: MessageFlags.Ephemeral });
      return true;
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    try {
      const res = await backend.runDomainAction("users", "info", {
        type: parsed.proto,
        proto: parsed.proto,
        username: parsed.username,
      });
      await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
    } catch (err) {
      await sendActionResult(interaction, "Backend Error", String(err), false);
    }
    return true;
  }

  if (id.startsWith(menuConstants.USER_DELETE_SELECT_PREFIX)) {
    if (!parsed) {
      await interaction.reply({ content: "User tidak valid.", flags: MessageFlags.Ephemeral });
      return true;
    }

    await interaction.reply({
      ...buildSlashConfirmView("users", "delete", { type: parsed.proto, username: parsed.username }, "Hapus user", [
        `Type: **${parsed.proto.toUpperCase()}**`,
        `Username: **${parsed.username}**`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (id.startsWith(menuConstants.USER_EXTEND_SELECT_PREFIX)) {
    if (!parsed) {
      await interaction.reply({ content: "User tidak valid.", flags: MessageFlags.Ephemeral });
      return true;
    }

    const token = createMenuState<MenuUserContext>({ type: parsed.proto as MenuUserContext["type"], username: parsed.username });
    await showSingleFieldModal(
      interaction,
      `${menuConstants.USER_EXTEND_MODAL_PREFIX}${token}`,
      "Extend Expiry",
      "days",
      "Tambahan hari",
      "7",
    );
    return true;
  }

  if (id.startsWith(menuConstants.USER_RESET_PASSWORD_SELECT_PREFIX)) {
    if (!parsed) {
      await interaction.reply({ content: "User tidak valid.", flags: MessageFlags.Ephemeral });
      return true;
    }

    const token = createMenuState<MenuUserContext>({ type: "ssh", username: parsed.username });
    await showSingleFieldModal(
      interaction,
      `${menuConstants.USER_RESET_PASSWORD_MODAL_PREFIX}${token}`,
      "Reset Password SSH",
      "password",
      "Password Baru",
      "password SSH baru",
    );
    return true;
  }

  if (id.startsWith(menuConstants.QAC_PANEL_SELECT_PREFIX)) {
    if (!parsed) {
      await interaction.reply({ content: "User tidak valid.", flags: MessageFlags.Ephemeral });
      return true;
    }

    const token = createMenuState<MenuUserContext>({ type: parsed.proto as MenuUserContext["type"], username: parsed.username });
    let summary = null;
    try {
      summary = await backend.getQacUserSummary(parsed.proto, parsed.username);
    } catch {
      summary = null;
    }

    await interaction.update(buildQacPanelView(token, { type: parsed.proto as MenuUserContext["type"], username: parsed.username }, summary));
    return true;
  }

  if (id === menuConstants.OPS_RESTART_SELECT_ID) {
    const service = selected.trim().toLowerCase();
    if (!service) {
      await interaction.reply({ content: "Service tidak valid.", flags: MessageFlags.Ephemeral });
      return true;
    }

    await interaction.reply({
      ...buildSlashConfirmView("ops", "restart_service", { service }, "Restart Service", [
        `Service: ${service}`,
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  return false;
}

import {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonInteraction,
  ButtonStyle,
  ChatInputCommandInteraction,
  Client,
  EmbedBuilder,
  MessageFlags,
  ModalBuilder,
  StringSelectMenuBuilder,
  TextInputBuilder,
  TextInputStyle,
} from "discord.js";

import type {
  BackendClient,
  BackendQacSummary,
  BackendRootDomainOption,
  BackendUserOption,
} from "../api_client";
import { sendActionResult } from "./result";
import { buildSlashConfirmView } from "../slash/confirm";
import { buildOverviewStatusEmbed } from "../slash/handlers/status";
import { createMenuState, deleteMenuState, getMenuState } from "./menu_state";
import { buildQacSummaryEmbed, type UserType } from "./qac_summary";
import { runPurgeAction } from "./purge";

const MENU_PREFIX = "menu:";
const SECTION_PREFIX = `${MENU_PREFIX}section:`;
const RUN_PREFIX = `${MENU_PREFIX}run:`;
const PICK_PREFIX = `${MENU_PREFIX}pick:`;
const MODAL_PREFIX = `${MENU_PREFIX}modal:`;
const ACCOUNT_SCOPE_PREFIX = `${MENU_PREFIX}accounts:scope:`;
const QAC_PANEL_PREFIX = `${MENU_PREFIX}qac-panel:`;

const USER_INFO_SELECT_PREFIX = "menu-select:user-info:";
const USER_DELETE_SELECT_PREFIX = "menu-select:user-delete:";
const USER_EXTEND_SELECT_PREFIX = "menu-select:user-extend:";
const USER_RESET_PASSWORD_SELECT_PREFIX = "menu-select:user-reset-password:";
const QAC_PANEL_SELECT_PREFIX = "menu-select:qac-panel:";
const OPS_RESTART_SELECT_ID = "menu-select:ops:restart-service";
const DOMAIN_SET_AUTO_ROOT_SELECT_ID = "menu-select:domain:set-auto-root";
const NETWORK_SET_DNS_STRATEGY_SELECT_ID = "menu-select:network:set-dns-strategy";
const USER_PICKER_PAGE_PREFIX = "menu:user-picker-page:";

const DOMAIN_SET_MANUAL_MODAL_ID = "menu-modal:domain:set-manual";
const DOMAIN_SET_AUTO_MODAL_PREFIX = "menu-modal:domain:set-auto:";
const NETWORK_SET_DNS_PRIMARY_MODAL_ID = "menu-modal:network:set-dns-primary";
const NETWORK_SET_DNS_SECONDARY_MODAL_ID = "menu-modal:network:set-dns-secondary";
const OPS_TRAFFIC_SEARCH_MODAL_ID = "menu-modal:ops:traffic-search";
const OPS_TRAFFIC_TOP_MODAL_ID = "menu-modal:ops:traffic-top";
const OPS_PURGE_MODAL_ID = "menu-modal:ops:purge";
const OPS_PURGE_CONFIRM_PREFIX = "menu:ops:purge-confirm:";
const OPS_PURGE_CANCEL_PREFIX = "menu:ops:purge-cancel:";
const USER_ADD_MODAL_PREFIX = "menu-modal:user-add:";
const USER_EXTEND_MODAL_PREFIX = "menu-modal:user-extend:";
const USER_RESET_PASSWORD_MODAL_PREFIX = "menu-modal:user-reset-password:";
const QAC_SET_QUOTA_MODAL_PREFIX = "menu-modal:qac:set-quota:";
const QAC_SET_IP_LIMIT_MODAL_PREFIX = "menu-modal:qac:set-ip-limit:";
const QAC_SET_SPEED_DOWN_MODAL_PREFIX = "menu-modal:qac:set-speed-down:";
const QAC_SET_SPEED_UP_MODAL_PREFIX = "menu-modal:qac:set-speed-up:";

const MAX_SELECT_OPTIONS = 25;

type MenuSection = "accounts" | "qac" | "domain" | "network" | "ops";
type Scope = "xray" | "ssh";
type MenuDeps = { client: Client; backend: BackendClient };
export type MenuUserContext = { type: UserType; username: string };

function isUserType(value: string): value is UserType {
  return value === "vless" || value === "vmess" || value === "trojan" || value === "ssh";
}

function getScopeFilter(scope: Scope): UserType | undefined {
  return scope === "ssh" ? "ssh" : undefined;
}

function normalizeScopeUsers(scope: Scope, users: BackendUserOption[]): BackendUserOption[] {
  return users.filter((item) => (scope === "ssh" ? item.proto === "ssh" : item.proto !== "ssh"));
}

function scopeLabel(scope: Scope): string {
  return scope === "ssh" ? "SSH" : "Xray";
}

function navRow(refreshId: string, backId: string, backLabel = "Back") {
  return new ActionRowBuilder<ButtonBuilder>().addComponents(
    new ButtonBuilder().setCustomId(refreshId).setLabel("Refresh").setStyle(ButtonStyle.Secondary),
    new ButtonBuilder().setCustomId(backId).setLabel(backLabel).setStyle(ButtonStyle.Secondary),
    new ButtonBuilder().setCustomId(`${MENU_PREFIX}home`).setLabel("Main Menu").setStyle(ButtonStyle.Secondary),
    new ButtonBuilder().setCustomId(`${MENU_PREFIX}close`).setLabel("Close").setStyle(ButtonStyle.Danger),
  );
}

function homeButtons() {
  return [
    new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder().setCustomId(`${SECTION_PREFIX}accounts`).setLabel("Accounts").setStyle(ButtonStyle.Primary),
      new ButtonBuilder().setCustomId(`${SECTION_PREFIX}qac`).setLabel("QAC").setStyle(ButtonStyle.Primary),
      new ButtonBuilder().setCustomId(`${SECTION_PREFIX}domain`).setLabel("Domain").setStyle(ButtonStyle.Primary),
      new ButtonBuilder().setCustomId(`${SECTION_PREFIX}network`).setLabel("Network").setStyle(ButtonStyle.Primary),
      new ButtonBuilder().setCustomId(`${SECTION_PREFIX}ops`).setLabel("Ops").setStyle(ButtonStyle.Primary),
    ),
    new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder().setCustomId(`${MENU_PREFIX}refresh`).setLabel("Refresh").setStyle(ButtonStyle.Secondary),
      new ButtonBuilder().setCustomId(`${MENU_PREFIX}close`).setLabel("Close").setStyle(ButtonStyle.Danger),
    ),
  ];
}

async function buildHomeEmbed(client: Client, backend: BackendClient): Promise<EmbedBuilder> {
  const embed = await buildOverviewStatusEmbed(client, backend);
  const statusText = String(embed.data.description ?? "").trim();
  const description = ["Pilih kategori operasi utama.", statusText].filter(Boolean).join("\n\n");
  return embed.setTitle("Menu Utama").setDescription(description);
}

function buildSectionEmbed(title: string, description: string, lines: string[]): EmbedBuilder {
  const body = lines.map((line) => `- ${line}`).join("\n");
  return new EmbedBuilder()
    .setTitle(title)
    .setDescription(`${description}\n\n${body}`)
    .setColor(0x2f81f7);
}

function buildAccountsView() {
  return {
    embeds: [
      buildSectionEmbed("Accounts", "Pilih kelompok akun yang ingin dikelola.", [
        "Xray Users",
        "SSH Users",
      ]),
    ],
    components: [
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${ACCOUNT_SCOPE_PREFIX}xray`).setLabel("Xray Users").setStyle(ButtonStyle.Primary),
        new ButtonBuilder().setCustomId(`${ACCOUNT_SCOPE_PREFIX}ssh`).setLabel("SSH Users").setStyle(ButtonStyle.Primary),
      ),
      navRow(`${SECTION_PREFIX}accounts`, `${MENU_PREFIX}home`, "Main Menu"),
    ],
  };
}

function buildAccountScopeView(scope: Scope) {
  const label = scopeLabel(scope);
  const rows: ActionRowBuilder<ButtonBuilder>[] = [
    new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder().setCustomId(`${MODAL_PREFIX}user-add:${scope}`).setLabel(`Add ${label} User`).setStyle(ButtonStyle.Success),
      new ButtonBuilder().setCustomId(`${PICK_PREFIX}user-info:${scope}`).setLabel("Account Info").setStyle(ButtonStyle.Primary),
      new ButtonBuilder().setCustomId(`${PICK_PREFIX}user-delete:${scope}`).setLabel("Delete User").setStyle(ButtonStyle.Danger),
    ),
    new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder().setCustomId(`${PICK_PREFIX}user-extend:${scope}`).setLabel("Extend Expiry").setStyle(ButtonStyle.Secondary),
      ...(scope === "ssh"
        ? [new ButtonBuilder().setCustomId(`${PICK_PREFIX}user-reset-password:ssh`).setLabel("Reset Password").setStyle(ButtonStyle.Secondary)]
        : []),
    ),
  ];

  rows.push(navRow(`${ACCOUNT_SCOPE_PREFIX}${scope}`, `${SECTION_PREFIX}accounts`, "Accounts"));

  return {
    embeds: [
      buildSectionEmbed(`${label} Users`, `Kelola akun ${label} lewat panel interaktif.`, [
        "Add User",
        "Account Info",
        "Delete User",
        "Extend Expiry",
        ...(scope === "ssh" ? ["Reset Password"] : []),
      ]),
    ],
    components: rows,
  };
}

function buildQacHomeView() {
  return {
    embeds: [
      buildSectionEmbed("QAC", "Ringkasan dan panel kontrol quota/access.", [
        "Xray Summary",
        "SSH Summary",
        "Manage Xray User",
        "Manage SSH User",
      ]),
    ],
    components: [
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}qac:summary:xray`).setLabel("Xray Summary").setStyle(ButtonStyle.Primary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}qac:summary:ssh`).setLabel("SSH Summary").setStyle(ButtonStyle.Primary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${PICK_PREFIX}qac-panel:xray`).setLabel("Manage Xray User").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${PICK_PREFIX}qac-panel:ssh`).setLabel("Manage SSH User").setStyle(ButtonStyle.Secondary),
      ),
      navRow(`${SECTION_PREFIX}qac`, `${MENU_PREFIX}home`, "Main Menu"),
    ],
  };
}

function buildDomainView() {
  return {
    embeds: [
      buildSectionEmbed("Domain", "Kontrol domain dan identitas runtime.", [
        "View Domain Info",
        "View Nginx Name",
        "Set Domain Manual",
        "Set Domain Auto",
        "Refresh Accounts",
      ]),
    ],
    components: [
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}domain:info`).setLabel("View Domain Info").setStyle(ButtonStyle.Primary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}domain:server_name`).setLabel("View Nginx Name").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}domain:refresh-accounts`).setLabel("Refresh Accounts").setStyle(ButtonStyle.Secondary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${MODAL_PREFIX}domain:set-manual`).setLabel("Set Domain Manual").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${MODAL_PREFIX}domain:set-auto`).setLabel("Set Domain Auto").setStyle(ButtonStyle.Secondary),
      ),
      navRow(`${SECTION_PREFIX}domain`, `${MENU_PREFIX}home`, "Main Menu"),
    ],
  };
}

function buildNetworkView() {
  return {
    embeds: [
      buildSectionEmbed("Network", "Status DNS dan domain guard yang paling sering dicek.", [
        "DNS Summary",
        "State File",
        "Set DNS Primary/Secondary",
        "Set DNS Strategy",
        "Toggle DNS Cache",
        "Domain Guard Status",
        "Run Guard Check",
        "Renew Domain Guard",
      ]),
    ],
    components: [
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}network:dns_summary`).setLabel("DNS Summary").setStyle(ButtonStyle.Primary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}network:state_file`).setLabel("State File").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}network:toggle_dns_cache`).setLabel("Toggle DNS Cache").setStyle(ButtonStyle.Secondary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${MODAL_PREFIX}network:set-dns-primary`).setLabel("Set DNS Primary").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${MODAL_PREFIX}network:set-dns-secondary`).setLabel("Set DNS Secondary").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${PICK_PREFIX}network:set-dns-strategy`).setLabel("Set Strategy").setStyle(ButtonStyle.Secondary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}network:domain_guard_status`).setLabel("Guard Status").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}network:domain_guard_check`).setLabel("Run Guard Check").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}network:domain_guard_renew`).setLabel("Guard Renew").setStyle(ButtonStyle.Secondary),
      ),
      navRow(`${SECTION_PREFIX}network`, `${MENU_PREFIX}home`, "Main Menu"),
    ],
  };
}

function buildOpsView() {
  return {
    embeds: [
      buildSectionEmbed("Ops", "Aksi operasional yang paling sering dipakai.", [
        "Speedtest",
        "Service Status",
        "Traffic Overview",
        "Traffic Top",
        "Traffic Export",
        "Traffic Search",
        "Restart Service",
        "Purge Bot Messages",
      ]),
    ],
    components: [
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}ops:speedtest`).setLabel("Speedtest").setStyle(ButtonStyle.Primary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}ops:service_status`).setLabel("Service Status").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}ops:traffic_overview`).setLabel("Traffic Overview").setStyle(ButtonStyle.Secondary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${MODAL_PREFIX}ops:traffic-top`).setLabel("Traffic Top").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${RUN_PREFIX}ops:traffic_export`).setLabel("Traffic Export").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${MODAL_PREFIX}ops:traffic-search`).setLabel("Traffic Search").setStyle(ButtonStyle.Secondary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${PICK_PREFIX}ops:restart-service`).setLabel("Restart Service").setStyle(ButtonStyle.Danger),
        new ButtonBuilder().setCustomId(`${MODAL_PREFIX}ops:purge`).setLabel("Purge Messages").setStyle(ButtonStyle.Danger),
      ),
      navRow(`${SECTION_PREFIX}ops`, `${MENU_PREFIX}home`, "Main Menu"),
    ],
  };
}

function buildDomainSetAutoRootSelectView(roots: BackendRootDomainOption[]) {
  return {
    embeds: [
      buildSectionEmbed("Domain - Set Auto", "Pilih root domain Cloudflare yang ingin dipakai.", [
        ...roots.map((item) => item.root_domain),
      ]),
    ],
    components: [
      new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(
        new StringSelectMenuBuilder()
          .setCustomId(DOMAIN_SET_AUTO_ROOT_SELECT_ID)
          .setPlaceholder("Pilih root domain")
          .addOptions(
            roots.slice(0, MAX_SELECT_OPTIONS).map((item) => ({
              label: truncateLabel(item.root_domain),
              value: item.root_domain,
            })),
          ),
      ),
      navRow(`${SECTION_PREFIX}domain`, `${SECTION_PREFIX}domain`, "Domain"),
    ],
  };
}

function buildDnsStrategySelectView() {
  return {
    embeds: [
      buildSectionEmbed("Network - DNS Strategy", "Pilih strategy DNS query yang ingin diterapkan.", [
        "UseIP",
        "UseIPv4",
        "UseIPv6",
        "PreferIPv4",
        "PreferIPv6",
      ]),
    ],
    components: [
      new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(
        new StringSelectMenuBuilder()
          .setCustomId(NETWORK_SET_DNS_STRATEGY_SELECT_ID)
          .setPlaceholder("Pilih DNS strategy")
          .addOptions([
            { label: "UseIP", value: "UseIP" },
            { label: "UseIPv4", value: "UseIPv4" },
            { label: "UseIPv6", value: "UseIPv6" },
            { label: "PreferIPv4", value: "PreferIPv4" },
            { label: "PreferIPv6", value: "PreferIPv6" },
          ]),
      ),
      navRow(`${SECTION_PREFIX}network`, `${SECTION_PREFIX}network`, "Network"),
    ],
  };
}

export function buildQacPanelView(token: string, ctx: MenuUserContext, summary: BackendQacSummary | null) {
  const embed =
    summary != null
      ? buildQacSummaryEmbed(ctx.type, summary)
      : buildSectionEmbed(
          ctx.type === "ssh" ? "SSH QAC" : "Xray QAC",
          "Summary backend tidak tersedia, tapi panel aksi tetap bisa dipakai.",
          [`Username: ${ctx.username}`, `Type: ${ctx.type.toUpperCase()}`],
        );
  embed.setFooter({ text: `User: ${ctx.username} (${ctx.type.toUpperCase()})` });

  return {
    embeds: [embed],
    components: [
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:refresh`).setLabel("Refresh").setStyle(ButtonStyle.Primary),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:detail`).setLabel("Detail").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:change-user`).setLabel("Ganti User").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${SECTION_PREFIX}qac`).setLabel("Back").setStyle(ButtonStyle.Secondary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:set-quota`).setLabel("Set Quota").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:reset-used`).setLabel("Reset Used").setStyle(ButtonStyle.Danger),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:unlock-ip`).setLabel("Unlock IP").setStyle(ButtonStyle.Secondary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:block-on`).setLabel("Block ON").setStyle(ButtonStyle.Danger),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:block-off`).setLabel("Block OFF").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:set-ip-limit`).setLabel("Set IP Limit").setStyle(ButtonStyle.Secondary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:ip-on`).setLabel("IP ON").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:ip-off`).setLabel("IP OFF").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:speed-on`).setLabel("Speed ON").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:speed-off`).setLabel("Speed OFF").setStyle(ButtonStyle.Secondary),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:set-speed-down`).setLabel("Speed Down").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${QAC_PANEL_PREFIX}${token}:set-speed-up`).setLabel("Speed Up").setStyle(ButtonStyle.Secondary),
        new ButtonBuilder().setCustomId(`${MENU_PREFIX}home`).setLabel("Main Menu").setStyle(ButtonStyle.Secondary),
      ),
    ],
  };
}

function truncateLabel(input: string, max = 100): string {
  if (input.length <= max) return input;
  return `${input.slice(0, max - 1)}…`;
}

function sortUserOptions(users: BackendUserOption[]): BackendUserOption[] {
  return [...users].sort((a, b) => {
    const left = `${a.username}`.toLowerCase();
    const right = `${b.username}`.toLowerCase();
    if (left !== right) return left.localeCompare(right);
    return `${a.proto}`.toLowerCase().localeCompare(`${b.proto}`.toLowerCase());
  });
}

function buildUserSelectScreen(
  token: string,
  title: string,
  description: string,
  customId: string,
  users: BackendUserOption[],
  backId: string,
  backLabel: string,
  page: number,
) {
  const sorted = sortUserOptions(users);
  const totalPages = Math.max(1, Math.ceil(sorted.length / MAX_SELECT_OPTIONS));
  const safePage = Math.min(Math.max(page, 0), totalPages - 1);
  const start = safePage * MAX_SELECT_OPTIONS;
  const visible = sorted.slice(start, start + MAX_SELECT_OPTIONS);
  const lines = [
    `Total user: ${sorted.length}`,
    `Halaman: ${safePage + 1}/${totalPages}`,
  ];
  return {
    embeds: [buildSectionEmbed(title, description, lines)],
    components: [
      new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(
        new StringSelectMenuBuilder()
          .setCustomId(customId)
          .setPlaceholder("Pilih user")
          .addOptions(
            visible.map((item) => ({
              label: truncateLabel(item.proto === "ssh" ? item.username : `${item.username}@${item.proto}`),
              value: `${item.proto}|${item.username}`,
            })),
          ),
      ),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder()
          .setCustomId(`${USER_PICKER_PAGE_PREFIX}${token}:${Math.max(safePage - 1, 0)}`)
          .setLabel("Prev")
          .setStyle(ButtonStyle.Secondary)
          .setDisabled(safePage <= 0),
        new ButtonBuilder()
          .setCustomId(`${USER_PICKER_PAGE_PREFIX}${token}:${safePage}`)
          .setLabel("Refresh")
          .setStyle(ButtonStyle.Secondary),
        new ButtonBuilder()
          .setCustomId(`${MENU_PREFIX}noop`)
          .setLabel(`${safePage + 1}/${totalPages}`)
          .setStyle(ButtonStyle.Secondary)
          .setDisabled(true),
        new ButtonBuilder()
          .setCustomId(`${USER_PICKER_PAGE_PREFIX}${token}:${Math.min(safePage + 1, totalPages - 1)}`)
          .setLabel("Next")
          .setStyle(ButtonStyle.Secondary)
          .setDisabled(safePage >= totalPages - 1),
      ),
      navRow(`${USER_PICKER_PAGE_PREFIX}${token}:${safePage}`, backId, backLabel),
    ],
  };
}

function buildRestartServiceSelectView() {
  return {
    embeds: [
      buildSectionEmbed("Ops - Restart Service", "Pilih service yang ingin direstart.", [
        "xray",
        "nginx",
      ]),
    ],
    components: [
      new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(
        new StringSelectMenuBuilder()
          .setCustomId(OPS_RESTART_SELECT_ID)
          .setPlaceholder("Pilih service")
          .addOptions([
            { label: "xray", value: "xray" },
            { label: "nginx", value: "nginx" },
          ]),
      ),
      navRow(`${SECTION_PREFIX}ops`, `${MENU_PREFIX}home`, "Main Menu"),
    ],
  };
}

function parseDirectAction(customId: string): { domain: string; action: string; params: Record<string, string> } | null {
  if (!customId.startsWith(RUN_PREFIX)) return null;
  const parts = customId.split(":");
  if (parts.length < 4) return null;
  const domain = parts[2] || "";
  const action = parts[3] || "";
  const tail = parts[4] || "";
  if (!domain || !action) return null;

  if (domain === "qac" && action === "summary" && tail) {
    return { domain, action, params: { scope: tail } };
  }

  return { domain, action, params: {} };
}

async function showSection(interaction: ButtonInteraction, section: MenuSection): Promise<void> {
  const view =
    section === "accounts"
      ? buildAccountsView()
      : section === "qac"
        ? buildQacHomeView()
        : section === "domain"
          ? buildDomainView()
          : section === "network"
            ? buildNetworkView()
            : buildOpsView();
  await interaction.update(view);
}

async function loadScopeUsers(backend: BackendClient, scope: Scope): Promise<BackendUserOption[]> {
  const users = await backend.listUserOptions(getScopeFilter(scope));
  return normalizeScopeUsers(scope, users);
}

async function showUserPicker(
  interaction: ButtonInteraction,
  backend: BackendClient,
  opts: {
    scope: Scope;
    customId: string;
    title: string;
    description: string;
    backSection: "accounts" | "qac";
  },
) {
  const { scope, customId, title, description, backSection } = opts;
  const users = await loadScopeUsers(backend, scope);
  if (users.length === 0) {
    await interaction.reply({
      content: scope === "ssh" ? "Belum ada user SSH." : "Belum ada user Xray.",
      flags: MessageFlags.Ephemeral,
    });
    return;
  }
  const token = createMenuState(opts);
  await interaction.update(
    buildUserSelectScreen(
      token,
      title,
      description,
      customId,
      users,
      `${SECTION_PREFIX}${backSection}`,
      backSection === "accounts" ? "Accounts" : "QAC",
      0,
    ),
  );
}

function showDomainSetManualModal(interaction: ButtonInteraction) {
  const modal = new ModalBuilder().setCustomId(DOMAIN_SET_MANUAL_MODAL_ID).setTitle("Set Domain Manual");
  modal.addComponents(
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("domain")
        .setLabel("Domain (FQDN)")
        .setRequired(true)
        .setPlaceholder("vpn.example.com")
        .setStyle(TextInputStyle.Short),
    ),
  );
  return interaction.showModal(modal);
}

function showTrafficSearchModal(interaction: ButtonInteraction) {
  const modal = new ModalBuilder().setCustomId(OPS_TRAFFIC_SEARCH_MODAL_ID).setTitle("Traffic Search");
  modal.addComponents(
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("query")
        .setLabel("Username Query")
        .setRequired(true)
        .setPlaceholder("contoh: kartel")
        .setStyle(TextInputStyle.Short),
    ),
  );
  return interaction.showModal(modal);
}

function showNetworkValueModal(
  interaction: ButtonInteraction,
  customId: string,
  title: string,
  fieldId: string,
  fieldLabel: string,
  placeholder: string,
) {
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

function showOpsTrafficTopModal(interaction: ButtonInteraction) {
  const modal = new ModalBuilder().setCustomId(OPS_TRAFFIC_TOP_MODAL_ID).setTitle("Traffic Top");
  modal.addComponents(
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("limit")
        .setLabel("Jumlah user")
        .setRequired(true)
        .setPlaceholder("10")
        .setStyle(TextInputStyle.Short),
    ),
  );
  return interaction.showModal(modal);
}

function showOpsPurgeModal(interaction: ButtonInteraction) {
  const modal = new ModalBuilder().setCustomId(OPS_PURGE_MODAL_ID).setTitle("Purge Messages");
  modal.addComponents(
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("mode")
        .setLabel("Mode")
        .setRequired(true)
        .setPlaceholder("bot_only / all_messages")
        .setStyle(TextInputStyle.Short),
    ),
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("amount")
        .setLabel("Jumlah pesan")
        .setRequired(true)
        .setPlaceholder("100")
        .setStyle(TextInputStyle.Short),
    ),
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("channel")
        .setLabel("Target Channel (opsional)")
        .setRequired(false)
        .setPlaceholder("#general atau 1234567890")
        .setStyle(TextInputStyle.Short),
    ),
  );
  return interaction.showModal(modal);
}

function showUserAddModal(interaction: ButtonInteraction, scope: Scope) {
  const modal = new ModalBuilder()
    .setCustomId(`${USER_ADD_MODAL_PREFIX}${scope}`)
    .setTitle(scope === "ssh" ? "Add SSH User" : "Add Xray User");

  if (scope === "ssh") {
    modal.addComponents(
      new ActionRowBuilder<TextInputBuilder>().addComponents(
        new TextInputBuilder().setCustomId("username").setLabel("Username").setRequired(true).setStyle(TextInputStyle.Short),
      ),
      new ActionRowBuilder<TextInputBuilder>().addComponents(
        new TextInputBuilder().setCustomId("password").setLabel("Password SSH").setRequired(true).setStyle(TextInputStyle.Short),
      ),
      new ActionRowBuilder<TextInputBuilder>().addComponents(
        new TextInputBuilder().setCustomId("days").setLabel("Masa Aktif (hari)").setRequired(true).setStyle(TextInputStyle.Short),
      ),
      new ActionRowBuilder<TextInputBuilder>().addComponents(
        new TextInputBuilder().setCustomId("quota_gb").setLabel("Quota (GB)").setRequired(true).setStyle(TextInputStyle.Short),
      ),
      new ActionRowBuilder<TextInputBuilder>().addComponents(
        new TextInputBuilder()
          .setCustomId("ip_limit")
          .setLabel("IP/Login Limit (opsional)")
          .setRequired(false)
          .setPlaceholder("0 = OFF")
          .setStyle(TextInputStyle.Short),
      ),
    );
    return interaction.showModal(modal);
  }

  modal.addComponents(
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("type")
        .setLabel("Type")
        .setRequired(true)
        .setPlaceholder("vless / vmess / trojan")
        .setStyle(TextInputStyle.Short),
    ),
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder().setCustomId("username").setLabel("Username").setRequired(true).setStyle(TextInputStyle.Short),
    ),
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder().setCustomId("days").setLabel("Masa Aktif (hari)").setRequired(true).setStyle(TextInputStyle.Short),
    ),
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder().setCustomId("quota_gb").setLabel("Quota (GB)").setRequired(true).setStyle(TextInputStyle.Short),
    ),
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("ip_limit")
        .setLabel("IP/Login Limit (opsional)")
        .setRequired(false)
        .setPlaceholder("0 = OFF")
        .setStyle(TextInputStyle.Short),
    ),
  );
  return interaction.showModal(modal);
}

function showUserExtendModal(interaction: ButtonInteraction, token: string) {
  const modal = new ModalBuilder().setCustomId(`${USER_EXTEND_MODAL_PREFIX}${token}`).setTitle("Extend Expiry");
  modal.addComponents(
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("days")
        .setLabel("Tambahan hari")
        .setRequired(true)
        .setPlaceholder("7")
        .setStyle(TextInputStyle.Short),
    ),
  );
  return interaction.showModal(modal);
}

function showResetPasswordModal(interaction: ButtonInteraction, token: string) {
  const modal = new ModalBuilder().setCustomId(`${USER_RESET_PASSWORD_MODAL_PREFIX}${token}`).setTitle("Reset Password SSH");
  modal.addComponents(
    new ActionRowBuilder<TextInputBuilder>().addComponents(
      new TextInputBuilder()
        .setCustomId("password")
        .setLabel("Password Baru")
        .setRequired(true)
        .setStyle(TextInputStyle.Short),
    ),
  );
  return interaction.showModal(modal);
}

function showQacValueModal(interaction: ButtonInteraction, customId: string, title: string, fieldId: string, fieldLabel: string, placeholder: string) {
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

async function runDirectActionReply(interaction: ButtonInteraction, backend: BackendClient, domain: string, action: string, params: Record<string, string> = {}) {
  await interaction.deferReply({ flags: MessageFlags.Ephemeral });
  try {
    const res = await backend.runDomainAction(domain, action, params);
    await sendActionResult(interaction, res.title, res.message, res.ok, res.data);
  } catch (err) {
    await sendActionResult(interaction, "Backend Error", String(err), false);
  }
}

async function refreshQacPanel(interaction: ButtonInteraction, backend: BackendClient, token: string, ctx: MenuUserContext) {
  let summary: BackendQacSummary | null = null;
  try {
    summary = await backend.getQacUserSummary(ctx.type, ctx.username);
  } catch {
    summary = null;
  }
  await interaction.update(buildQacPanelView(token, ctx, summary));
}

export async function handleMenuSlashCommand(interaction: ChatInputCommandInteraction, deps: MenuDeps): Promise<void> {
  const embed = await buildHomeEmbed(deps.client, deps.backend);
  await interaction.reply({
    embeds: [embed],
    components: homeButtons(),
    flags: MessageFlags.Ephemeral,
  });
}

export async function handleMenuButton(interaction: ButtonInteraction, deps: MenuDeps): Promise<boolean> {
  const id = interaction.customId;
  if (!id.startsWith(MENU_PREFIX)) return false;

  if (id === `${MENU_PREFIX}home` || id === `${MENU_PREFIX}refresh`) {
    const embed = await buildHomeEmbed(deps.client, deps.backend);
    await interaction.update({
      embeds: [embed],
      components: homeButtons(),
    });
    return true;
  }

  if (id === `${MENU_PREFIX}close`) {
    await interaction.update({
      content: "Menu ditutup.",
      embeds: [],
      components: [],
    });
    return true;
  }

  if (id === `${MENU_PREFIX}noop`) {
    await interaction.deferUpdate();
    return true;
  }

  if (id.startsWith(SECTION_PREFIX)) {
    const section = id.slice(SECTION_PREFIX.length) as MenuSection;
    if (["accounts", "qac", "domain", "network", "ops"].includes(section)) {
      await showSection(interaction, section);
      return true;
    }
  }

  if (id.startsWith(ACCOUNT_SCOPE_PREFIX)) {
    const scope = id.slice(ACCOUNT_SCOPE_PREFIX.length) as Scope;
    if (scope === "xray" || scope === "ssh") {
      await interaction.update(buildAccountScopeView(scope));
      return true;
    }
  }

  if (id.startsWith(USER_PICKER_PAGE_PREFIX)) {
    const body = id.slice(USER_PICKER_PAGE_PREFIX.length);
    const [token, pageRaw] = body.split(":", 2);
    const ctx = getMenuState<{
      scope: Scope;
      customId: string;
      title: string;
      description: string;
      backSection: "accounts" | "qac";
    }>(token || "");
    if (!ctx) {
      await interaction.reply({ content: "Context picker kadaluarsa. Buka /menu lagi.", flags: MessageFlags.Ephemeral });
      return true;
    }
    const users = await loadScopeUsers(deps.backend, ctx.scope);
    if (users.length === 0) {
      await interaction.reply({
        content: ctx.scope === "ssh" ? "Belum ada user SSH." : "Belum ada user Xray.",
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }
    const page = Number.parseInt(pageRaw || "0", 10);
    await interaction.update(
      buildUserSelectScreen(
        token,
        ctx.title,
        ctx.description,
        ctx.customId,
        users,
        `${SECTION_PREFIX}${ctx.backSection}`,
        ctx.backSection === "accounts" ? "Accounts" : "QAC",
        Number.isFinite(page) ? page : 0,
      ),
    );
    return true;
  }

  if (id.startsWith(OPS_PURGE_CONFIRM_PREFIX)) {
    const token = id.slice(OPS_PURGE_CONFIRM_PREFIX.length);
    const ctx = getMenuState<{ mode: "bot_only" | "all_messages"; amount: number; channelInput?: string }>(token);
    if (!ctx) {
      await interaction.reply({ content: "Context purge kadaluarsa. Buka /menu lagi.", flags: MessageFlags.Ephemeral });
      return true;
    }
    deleteMenuState(token);
    await runPurgeAction(interaction, ctx.mode, ctx.amount, ctx.channelInput || "");
    return true;
  }

  if (id.startsWith(OPS_PURGE_CANCEL_PREFIX)) {
    const token = id.slice(OPS_PURGE_CANCEL_PREFIX.length);
    if (token) {
      deleteMenuState(token);
    }
    await interaction.update({
      content: "Purge dibatalkan.",
      embeds: [],
      components: [],
    });
    return true;
  }

  if (id === `${PICK_PREFIX}user-info:xray`) {
    await showUserPicker(
      interaction,
      deps.backend,
      { scope: "xray", customId: `${USER_INFO_SELECT_PREFIX}xray`, title: "Xray Account Info", description: "Pilih user untuk melihat ACCOUNT INFO.", backSection: "accounts" },
    );
    return true;
  }

  if (id === `${PICK_PREFIX}user-info:ssh`) {
    await showUserPicker(
      interaction,
      deps.backend,
      { scope: "ssh", customId: `${USER_INFO_SELECT_PREFIX}ssh`, title: "SSH Account Info", description: "Pilih user untuk melihat ACCOUNT INFO.", backSection: "accounts" },
    );
    return true;
  }

  if (id === `${PICK_PREFIX}user-delete:xray`) {
    await showUserPicker(
      interaction,
      deps.backend,
      { scope: "xray", customId: `${USER_DELETE_SELECT_PREFIX}xray`, title: "Delete Xray User", description: "Pilih user yang ingin dihapus.", backSection: "accounts" },
    );
    return true;
  }

  if (id === `${PICK_PREFIX}user-delete:ssh`) {
    await showUserPicker(
      interaction,
      deps.backend,
      { scope: "ssh", customId: `${USER_DELETE_SELECT_PREFIX}ssh`, title: "Delete SSH User", description: "Pilih user yang ingin dihapus.", backSection: "accounts" },
    );
    return true;
  }

  if (id === `${PICK_PREFIX}user-extend:xray`) {
    await showUserPicker(
      interaction,
      deps.backend,
      { scope: "xray", customId: `${USER_EXTEND_SELECT_PREFIX}xray`, title: "Extend Xray Expiry", description: "Pilih user yang ingin diperpanjang.", backSection: "accounts" },
    );
    return true;
  }

  if (id === `${PICK_PREFIX}user-extend:ssh`) {
    await showUserPicker(
      interaction,
      deps.backend,
      { scope: "ssh", customId: `${USER_EXTEND_SELECT_PREFIX}ssh`, title: "Extend SSH Expiry", description: "Pilih user yang ingin diperpanjang.", backSection: "accounts" },
    );
    return true;
  }

  if (id === `${PICK_PREFIX}user-reset-password:ssh`) {
    await showUserPicker(
      interaction,
      deps.backend,
      { scope: "ssh", customId: `${USER_RESET_PASSWORD_SELECT_PREFIX}ssh`, title: "Reset SSH Password", description: "Pilih user SSH yang ingin diubah password-nya.", backSection: "accounts" },
    );
    return true;
  }

  if (id === `${PICK_PREFIX}qac-panel:xray`) {
    await showUserPicker(
      interaction,
      deps.backend,
      { scope: "xray", customId: `${QAC_PANEL_SELECT_PREFIX}xray`, title: "Xray QAC Panel", description: "Pilih user untuk membuka panel QAC.", backSection: "qac" },
    );
    return true;
  }

  if (id === `${PICK_PREFIX}qac-panel:ssh`) {
    await showUserPicker(
      interaction,
      deps.backend,
      { scope: "ssh", customId: `${QAC_PANEL_SELECT_PREFIX}ssh`, title: "SSH QAC Panel", description: "Pilih user untuk membuka panel QAC.", backSection: "qac" },
    );
    return true;
  }

  if (id === `${PICK_PREFIX}ops:restart-service`) {
    await interaction.update(buildRestartServiceSelectView());
    return true;
  }

  if (id === `${PICK_PREFIX}network:set-dns-strategy`) {
    await interaction.update(buildDnsStrategySelectView());
    return true;
  }

  if (id === `${MODAL_PREFIX}domain:set-manual`) {
    await showDomainSetManualModal(interaction);
    return true;
  }

  if (id === `${MODAL_PREFIX}domain:set-auto`) {
    const roots = await deps.backend.listDomainRootOptions();
    if (roots.length === 0) {
      await interaction.reply({
        content: "Root domain Cloudflare belum tersedia.",
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }
    await interaction.update(buildDomainSetAutoRootSelectView(roots));
    return true;
  }

  if (id === `${MODAL_PREFIX}network:set-dns-primary`) {
    await showNetworkValueModal(interaction, NETWORK_SET_DNS_PRIMARY_MODAL_ID, "Set DNS Primary", "dns", "DNS Primary", "1.1.1.1");
    return true;
  }

  if (id === `${MODAL_PREFIX}network:set-dns-secondary`) {
    await showNetworkValueModal(interaction, NETWORK_SET_DNS_SECONDARY_MODAL_ID, "Set DNS Secondary", "dns", "DNS Secondary", "8.8.8.8");
    return true;
  }

  if (id === `${MODAL_PREFIX}ops:traffic-search`) {
    await showTrafficSearchModal(interaction);
    return true;
  }

  if (id === `${MODAL_PREFIX}ops:traffic-top`) {
    await showOpsTrafficTopModal(interaction);
    return true;
  }

  if (id === `${MODAL_PREFIX}ops:purge`) {
    await showOpsPurgeModal(interaction);
    return true;
  }

  if (id === `${MODAL_PREFIX}user-add:xray`) {
    await showUserAddModal(interaction, "xray");
    return true;
  }

  if (id === `${MODAL_PREFIX}user-add:ssh`) {
    await showUserAddModal(interaction, "ssh");
    return true;
  }

  if (id.startsWith(QAC_PANEL_PREFIX)) {
    const [, , token, action] = id.split(":");
    const ctx = getMenuState<MenuUserContext>(token || "");
    if (!ctx) {
      await interaction.reply({ content: "Context QAC kadaluarsa. Pilih user lagi dari /menu.", flags: MessageFlags.Ephemeral });
      return true;
    }

    if (action === "refresh") {
      await refreshQacPanel(interaction, deps.backend, token, ctx);
      return true;
    }

    if (action === "change-user") {
      const scope: Scope = ctx.type === "ssh" ? "ssh" : "xray";
      await showUserPicker(
        interaction,
        deps.backend,
        { scope, customId: `${QAC_PANEL_SELECT_PREFIX}${scope}`, title: `${scopeLabel(scope)} QAC Panel`, description: "Pilih user lain untuk membuka panel QAC.", backSection: "qac" },
      );
      return true;
    }

    if (action === "detail") {
      await runDirectActionReply(interaction, deps.backend, "qac", "detail", { type: ctx.type, username: ctx.username });
      return true;
    }

    if (action === "reset-used") {
      await interaction.reply({
        ...buildSlashConfirmView("qac", "reset_used", { type: ctx.type, username: ctx.username }, "Reset quota used", [
          `Type: **${ctx.type.toUpperCase()}**`,
          `Username: **${ctx.username}**`,
        ]),
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }

    if (action === "unlock-ip") {
      await interaction.reply({
        ...buildSlashConfirmView("qac", "unlock_ip", { type: ctx.type, username: ctx.username }, "Unlock IP/Login lock", [
          `Type: **${ctx.type.toUpperCase()}**`,
          `Username: **${ctx.username}**`,
        ]),
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }

    if (action === "block-on" || action === "block-off") {
      const enabled = action === "block-on" ? "true" : "false";
      await interaction.reply({
        ...buildSlashConfirmView("qac", "toggle_block", { type: ctx.type, username: ctx.username, enabled }, "Toggle manual block", [
          `Type: **${ctx.type.toUpperCase()}**`,
          `Username: **${ctx.username}**`,
          `Enabled: **${enabled.toUpperCase()}**`,
        ]),
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }

    if (action === "ip-on" || action === "ip-off") {
      const enabled = action === "ip-on" ? "true" : "false";
      await interaction.reply({
        ...buildSlashConfirmView("qac", "toggle_ip_limit", { type: ctx.type, username: ctx.username, enabled }, "Toggle IP/Login limit", [
          `Type: **${ctx.type.toUpperCase()}**`,
          `Username: **${ctx.username}**`,
          `Enabled: **${enabled.toUpperCase()}**`,
        ]),
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }

    if (action === "speed-on" || action === "speed-off") {
      const enabled = action === "speed-on" ? "true" : "false";
      await interaction.reply({
        ...buildSlashConfirmView("qac", "toggle_speed", { type: ctx.type, username: ctx.username, enabled }, "Toggle speed limit", [
          `Type: **${ctx.type.toUpperCase()}**`,
          `Username: **${ctx.username}**`,
          `Enabled: **${enabled.toUpperCase()}**`,
        ]),
        flags: MessageFlags.Ephemeral,
      });
      return true;
    }

    if (action === "set-quota") {
      await showQacValueModal(interaction, `${QAC_SET_QUOTA_MODAL_PREFIX}${token}`, "Set Quota", "quota_gb", "Quota (GB)", "10");
      return true;
    }

    if (action === "set-ip-limit") {
      await showQacValueModal(interaction, `${QAC_SET_IP_LIMIT_MODAL_PREFIX}${token}`, "Set IP/Login Limit", "ip_limit", "IP/Login Limit", "1");
      return true;
    }

    if (action === "set-speed-down") {
      await showQacValueModal(interaction, `${QAC_SET_SPEED_DOWN_MODAL_PREFIX}${token}`, "Set Speed Download", "mbit", "Speed Down Mbps", "10");
      return true;
    }

    if (action === "set-speed-up") {
      await showQacValueModal(interaction, `${QAC_SET_SPEED_UP_MODAL_PREFIX}${token}`, "Set Speed Upload", "mbit", "Speed Up Mbps", "5");
      return true;
    }
  }

  if (id === `${RUN_PREFIX}domain:refresh-accounts`) {
    await interaction.reply({
      ...buildSlashConfirmView("domain", "refresh_accounts", {}, "Refresh account info", [
        "Semua file account info akan direfresh sesuai domain aktif.",
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (id === `${RUN_PREFIX}network:toggle_dns_cache`) {
    await interaction.reply({
      ...buildSlashConfirmView("network", "toggle_dns_cache", {}, "Toggle DNS cache", [
        "DNS cache akan ditoggle sesuai state saat ini.",
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  if (id === `${RUN_PREFIX}network:domain_guard_renew`) {
    await interaction.reply({
      ...buildSlashConfirmView("network", "domain_guard_renew", { force: "false" }, "Renew domain guard", [
        "Mode force: **OFF**",
      ]),
      flags: MessageFlags.Ephemeral,
    });
    return true;
  }

  const direct = parseDirectAction(id);
  if (!direct) return false;
  await runDirectActionReply(interaction, deps.backend, direct.domain, direct.action, direct.params);
  return true;
}

export const menuConstants = {
  USER_INFO_SELECT_PREFIX,
  USER_DELETE_SELECT_PREFIX,
  USER_EXTEND_SELECT_PREFIX,
  USER_RESET_PASSWORD_SELECT_PREFIX,
  QAC_PANEL_SELECT_PREFIX,
  OPS_RESTART_SELECT_ID,
  DOMAIN_SET_AUTO_ROOT_SELECT_ID,
  NETWORK_SET_DNS_STRATEGY_SELECT_ID,
  DOMAIN_SET_MANUAL_MODAL_ID,
  DOMAIN_SET_AUTO_MODAL_PREFIX,
  NETWORK_SET_DNS_PRIMARY_MODAL_ID,
  NETWORK_SET_DNS_SECONDARY_MODAL_ID,
  OPS_TRAFFIC_SEARCH_MODAL_ID,
  OPS_TRAFFIC_TOP_MODAL_ID,
  OPS_PURGE_MODAL_ID,
  OPS_PURGE_CONFIRM_PREFIX,
  OPS_PURGE_CANCEL_PREFIX,
  USER_ADD_MODAL_PREFIX,
  USER_EXTEND_MODAL_PREFIX,
  USER_RESET_PASSWORD_MODAL_PREFIX,
  QAC_SET_QUOTA_MODAL_PREFIX,
  QAC_SET_IP_LIMIT_MODAL_PREFIX,
  QAC_SET_SPEED_DOWN_MODAL_PREFIX,
  QAC_SET_SPEED_UP_MODAL_PREFIX,
};

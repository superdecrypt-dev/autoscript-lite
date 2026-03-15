import { EmbedBuilder } from "discord.js";

import type { BackendQacSummary } from "../api_client";

export type UserType = "vless" | "vmess" | "trojan" | "ssh";

export function buildQacSummaryEmbed(type: UserType, summary: BackendQacSummary): EmbedBuilder {
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

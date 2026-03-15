import type { MenuDefinition } from "./types";

export const menu11: MenuDefinition = {
  id: "11",
  label: "SSH QAC",
  description: "Ringkasan quota dan kontrol akses untuk pengguna SSH.",
  actions: [
    { id: "summary", label: "View Quota Summary", mode: "direct", style: "primary" },
    {
      id: "detail",
      label: "View SSH QAC Detail",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "SSH QAC Detail",
        fields: [{ id: "username", label: "Username", style: "short", required: true, placeholder: "contoh: alice" }],
      },
    },
    {
      id: "set_quota_limit",
      label: "Set Quota Limit",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "Set SSH Quota Limit",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "alice" },
          { id: "quota_gb", label: "Quota GB", style: "short", required: true, placeholder: "100" },
        ],
      },
    },
    {
      id: "reset_quota_used",
      label: "Reset Quota Used",
      mode: "modal",
      style: "danger",
      confirm: true,
      modal: {
        title: "Reset SSH Quota Used",
        fields: [{ id: "username", label: "Username", style: "short", required: true, placeholder: "alice" }],
      },
    },
    {
      id: "manual_block",
      label: "Toggle Manual Block",
      mode: "modal",
      style: "danger",
      modal: {
        title: "SSH Manual Block",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "alice" },
          { id: "enabled", label: "Enabled", style: "short", required: true, placeholder: "on / off" },
        ],
      },
    },
    {
      id: "ip_limit_enable",
      label: "Toggle IP/Login Limit",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "SSH IP/Login Limit Enable/Disable",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "alice" },
          { id: "enabled", label: "Enabled", style: "short", required: true, placeholder: "on / off" },
        ],
      },
    },
    {
      id: "set_ip_limit",
      label: "Set IP/Login Limit",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "Set SSH IP/Login Limit",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "alice" },
          { id: "ip_limit", label: "IP/Login Limit", style: "short", required: true, placeholder: "2" },
        ],
      },
    },
    {
      id: "unlock_ip_lock",
      label: "Unlock IP/Login Lock",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "Unlock SSH IP/Login Lock",
        fields: [{ id: "username", label: "Username", style: "short", required: true, placeholder: "alice" }],
      },
    },
    {
      id: "set_speed_download",
      label: "Set Speed Down",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "Set SSH Speed Download",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "alice" },
          { id: "speed_down_mbit", label: "Speed Down Mbps", style: "short", required: true, placeholder: "20" },
        ],
      },
    },
    {
      id: "set_speed_upload",
      label: "Set Speed Up",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "Set SSH Speed Upload",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "alice" },
          { id: "speed_up_mbit", label: "Speed Up Mbps", style: "short", required: true, placeholder: "10" },
        ],
      },
    },
    {
      id: "speed_limit",
      label: "Toggle Speed Limit",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "SSH Speed Limit Enable/Disable",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "alice" },
          { id: "enabled", label: "Enabled", style: "short", required: true, placeholder: "on / off" },
        ],
      },
    },
  ],
};

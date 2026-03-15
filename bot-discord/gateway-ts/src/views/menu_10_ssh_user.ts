import type { MenuDefinition } from "./types";

export const menu10: MenuDefinition = {
  id: "10",
  label: "SSH Users",
  description: "Kelola akun SSH, masa aktif, password, pencarian, dan informasi akun.",
  actions: [
    {
      id: "add_user",
      label: "Add User",
      mode: "modal",
      style: "success",
      modal: {
        title: "Add SSH User",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "contoh: alice" },
          { id: "password", label: "Password SSH", style: "short", required: true, placeholder: "password SSH wajib diisi" },
          { id: "days", label: "Masa Aktif (hari)", style: "short", required: true, placeholder: "30" },
          { id: "quota_gb", label: "Quota (GB)", style: "short", required: true, placeholder: "100" },
          { id: "ip_limit", label: "IP/Login Limit (opsional)", style: "short", required: false, placeholder: "0 = OFF" },
        ],
      },
    },
    {
      id: "delete_user",
      label: "Delete User",
      mode: "modal",
      style: "danger",
      confirm: true,
      modal: {
        title: "Delete SSH User",
        fields: [{ id: "username", label: "Username", style: "short", required: true, placeholder: "contoh: alice" }],
      },
    },
    {
      id: "extend_expiry",
      label: "Set User Expiry",
      mode: "modal",
      style: "primary",
      modal: {
        title: "Extend/Set SSH Expiry",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "contoh: alice" },
          { id: "mode", label: "Mode", style: "short", required: true, placeholder: "extend / set" },
          { id: "value", label: "Value", style: "short", required: true, placeholder: "7 atau 2026-12-31" },
        ],
      },
    },
    {
      id: "reset_password",
      label: "Reset SSH Password",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "Reset SSH Password",
        fields: [
          { id: "username", label: "Username", style: "short", required: true, placeholder: "contoh: alice" },
          { id: "password", label: "Password Baru", style: "short", required: true, placeholder: "password SSH baru" },
        ],
      },
    },
    { id: "list_users", label: "View User List", mode: "direct", style: "primary" },
    {
      id: "search_user",
      label: "Search User",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "Search SSH User",
        fields: [{ id: "query", label: "Username Query", style: "short", required: true, placeholder: "contoh: alice" }],
      },
    },
    {
      id: "account_info",
      label: "View Account Info",
      mode: "modal",
      style: "secondary",
      modal: {
        title: "SSH Account Info",
        fields: [{ id: "username", label: "Username", style: "short", required: true, placeholder: "contoh: alice" }],
      },
    },
  ],
};

import type { AccountSummary } from "@/types/portal"

export function protocolLabel(protocol: string) {
  const current = String(protocol || "").trim().toLowerCase()
  const labels: Record<string, string> = {
    vless: "VLESS",
    vmess: "VMESS",
    trojan: "TROJAN",
    ssh: "SSH",
    openvpn: "OPENVPN",
  }

  return labels[current] ?? current.toUpperCase() ?? "-"
}

export function statusVariant(status: string) {
  const current = String(status || "").trim().toLowerCase()
  if (current === "active") return "success" as const
  if (current === "expired") return "warning" as const
  return "destructive" as const
}

export function quotaPercent(summary: AccountSummary) {
  if (!summary.quota_limit_bytes || summary.quota_limit_bytes <= 0) return 0
  return Math.max(0, Math.min(100, Math.round((summary.quota_used_bytes / summary.quota_limit_bytes) * 100)))
}

export function daysLabel(value: number | null) {
  return typeof value === "number" && value >= 0 ? `${value} hari` : "-"
}

export function activeIpHint(summary: AccountSummary) {
  if (summary.active_ip !== "-" && summary.active_ip_last_seen_at !== "-") {
    return `Terakhir aktif: ${summary.active_ip_last_seen_at}`
  }
  if (summary.active_ip !== "-") return "Sedang aktif."
  if (summary.active_ip_last_seen_at !== "-") {
    return `Terakhir aktif: ${summary.active_ip_last_seen_at}`
  }
  return "Belum ada login aktif."
}

export function nextAction(summary: AccountSummary) {
  const percent = quotaPercent(summary)
  const status = String(summary.status || "").trim().toLowerCase()

  if (status === "blocked") {
    return {
      tone: "destructive" as const,
      text: "Akun diblokir. Hubungi admin.",
    }
  }

  if (status === "expired") {
    return {
      tone: "warning" as const,
      text: "Masa aktif habis. Hubungi admin.",
    }
  }

  if (percent >= 90) {
    return {
      tone: "warning" as const,
      text: "Quota hampir habis.",
    }
  }

  if (typeof summary.days_remaining === "number" && summary.days_remaining <= 3) {
    return {
      tone: "warning" as const,
      text: "Masa aktif hampir habis.",
    }
  }

  return {
    tone: null,
    text: "",
  }
}

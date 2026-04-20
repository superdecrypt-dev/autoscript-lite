export type PortalStatus = "active" | "expired" | "blocked" | string

export type ImportLink = {
  label: string
  url: string
}

export type AccessDetail = {
  label: string
  value: string
}

export type AccountSummary = {
  ok: boolean
  token: string
  protocol: string
  username: string
  status: PortalStatus
  status_text: string
  valid_until: string
  days_remaining: number | null
  quota_limit: string
  quota_limit_bytes: number
  quota_used: string
  quota_used_bytes: number
  quota_remaining: string
  quota_remaining_bytes: number
  ip_limit_text: string
  speed_limit_text: string
  active_ip: string
  active_ip_last_seen_at: string
  access_domain: string
  access_ports: string
  access_path: string
  access_details: AccessDetail[]
  credentials_available: boolean
  credentials_username: string
  credentials_password: string
  xray_json_available: boolean
  xray_json_url: string
  import_links: ImportLink[]
  portal_url: string
  last_updated: string
}

export type TrafficPoint = {
  ts: number
  rate_bps: number
  total_rate_bps?: number
  down_rate_bps: number
  up_rate_bps: number
}

export type TrafficPayload = {
  ok: boolean
  active: boolean
  source: string
  source_text: string
  supports_split: boolean
  sample_interval_seconds: number
  window_seconds: number
  default_window_seconds: number
  available_windows: number[]
  current_rate_bps: number
  current_rate_text: string
  current_down_rate_bps: number
  current_down_rate_text: string
  current_up_rate_bps: number
  current_up_rate_text: string
  points: TrafficPoint[]
}

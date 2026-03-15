import axios, { AxiosInstance } from "axios";

const DEFAULT_BACKEND_TIMEOUT_MS = 30_000;
const ACTION_TIMEOUT_MS: Record<string, number> = {
  "domain:set_manual": 420_000,
  "domain:set_auto": 420_000,
  "network:domain_guard_check": 190_000,
  "network:domain_guard_renew": 320_000,
  "ops:speedtest": 190_000,
};

function resolveActionTimeoutMs(domain: string, action: string): number {
  return ACTION_TIMEOUT_MS[`${domain}:${action}`] ?? DEFAULT_BACKEND_TIMEOUT_MS;
}

export interface BackendActionResponse {
  ok: boolean;
  code: string;
  title: string;
  message: string;
  data?: Record<string, unknown>;
}

export interface BackendHealthResponse {
  status?: string;
  service?: string;
  mutations_enabled?: boolean;
}

export interface BackendUserOption {
  proto: string;
  username: string;
}

export interface BackendRootDomainOption {
  root_domain: string;
}

export interface BackendQacSummary {
  username: string;
  quota_limit: string;
  quota_used: string;
  expired_at: string;
  ip_limit: string;
  block_reason: string;
  ip_limit_max: string;
  speed_download: string;
  speed_upload: string;
  speed_limit: string;
  distinct_ip_count?: string;
  distinct_ips?: string;
  ip_limit_metric?: string;
  account_locked?: string;
  active_sessions_total?: string;
}

export class BackendClient {
  private readonly client: AxiosInstance;

  constructor(baseURL: string, sharedSecret: string) {
    this.client = axios.create({
      baseURL,
      timeout: DEFAULT_BACKEND_TIMEOUT_MS,
      headers: {
        "X-Internal-Shared-Secret": sharedSecret,
      },
    });
  }

  async runDomainAction(domain: string, action: string, params: Record<string, string> = {}): Promise<BackendActionResponse> {
    const timeout = resolveActionTimeoutMs(domain, action);
    const res = await this.client.post<BackendActionResponse>(
      `/api/${domain}/action`,
      {
        action,
        params,
      },
      {
        timeout,
      },
    );
    return res.data;
  }

  async listUserOptions(proto?: string): Promise<BackendUserOption[]> {
    const res = await this.client.get<{ users?: BackendUserOption[] }>("/api/users/options", {
      params: proto ? { proto } : {},
    });
    const users = Array.isArray(res.data?.users) ? res.data.users : [];
    return users.filter((item) => item && typeof item.proto === "string" && typeof item.username === "string");
  }

  async listDomainRootOptions(): Promise<BackendRootDomainOption[]> {
    const res = await this.client.get<{ roots?: BackendRootDomainOption[] }>("/api/domain/root-options");
    const roots = Array.isArray(res.data?.roots) ? res.data.roots : [];
    return roots.filter((item) => item && typeof item.root_domain === "string");
  }

  async getQacUserSummary(proto: string, username: string): Promise<BackendQacSummary | null> {
    const res = await this.client.get<{ ok?: boolean; summary?: BackendQacSummary }>("/api/qac/summary", {
      params: { proto, username },
      timeout: 8_000,
    });
    if (!res.data?.ok || !res.data.summary) {
      return null;
    }
    return res.data.summary;
  }

  async getHealth(timeout = 8_000): Promise<BackendHealthResponse> {
    const res = await this.client.get<BackendHealthResponse>("/health", { timeout });
    return res.data;
  }
}

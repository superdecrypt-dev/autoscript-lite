import fs from "node:fs";
import path from "node:path";
import dotenv from "dotenv";

export interface AppConfig {
  token: string;
  applicationId: string;
  guildId: string;
  backendBaseUrl: string;
  sharedSecret: string;
  adminRoleIds: Set<string>;
  adminUserIds: Set<string>;
  channelPolicyFile: string;
}

function loadEnv(): void {
  if (process.env.BOT_ENV_FILE?.trim()) {
    return;
  }
  const candidates = [
    path.resolve(process.cwd(), ".env"),
    path.resolve(__dirname, "../../.env"),
  ];
  for (const envPath of candidates) {
    if (fs.existsSync(envPath)) {
      dotenv.config({ path: envPath, override: false });
      return;
    }
  }
}

loadEnv();

function parseSet(input: string | undefined): Set<string> {
  const out = new Set<string>();
  if (!input) return out;
  for (const part of input.split(",")) {
    const value = part.trim();
    if (value) out.add(value);
  }
  return out;
}

function requireEnv(name: string): string {
  const raw = process.env[name]?.trim();
  if (!raw) {
    throw new Error(`${name} belum diset.`);
  }
  return raw;
}

function parsePort(name: string, raw: string | undefined, fallback: number): number {
  const value = raw?.trim() || `${fallback}`;
  const port = Number.parseInt(value, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error(`${name} tidak valid: ${value}`);
  }
  return port;
}

function formatHostForUrl(host: string): string {
  if (host.includes(":") && !host.startsWith("[") && !host.endsWith("]")) {
    return `[${host}]`;
  }
  return host;
}

function normalizeBackendBaseUrl(raw: string): string {
  const value = raw.trim();
  if (!value) {
    throw new Error("BACKEND_BASE_URL belum diset.");
  }

  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("BACKEND_BASE_URL tidak memiliki host:port yang valid.");
  }

  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("BACKEND_BASE_URL harus memakai skema http/https.");
  }
  if (!parsed.hostname) {
    throw new Error("BACKEND_BASE_URL tidak memiliki host:port yang valid.");
  }
  if (parsed.username || parsed.password) {
    throw new Error("BACKEND_BASE_URL tidak boleh menyertakan kredensial.");
  }
  if (parsed.search || parsed.hash) {
    throw new Error("BACKEND_BASE_URL tidak boleh berisi query/fragment.");
  }
  if (parsed.pathname && parsed.pathname !== "/") {
    throw new Error("BACKEND_BASE_URL tidak boleh berisi path tambahan.");
  }

  parsed.pathname = "";
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString().replace(/\/$/, "");
}

function resolveBackendBaseUrl(defaultPort: number): string {
  const rawBaseUrl = process.env.BACKEND_BASE_URL?.trim() || "";
  const rawHost = process.env.BACKEND_HOST?.trim() || "";
  const rawPort = process.env.BACKEND_PORT?.trim() || "";

  if (rawHost || rawPort) {
    const host = rawHost || "127.0.0.1";
    const port = parsePort("BACKEND_PORT", rawPort, defaultPort);
    const derived = normalizeBackendBaseUrl(`http://${formatHostForUrl(host)}:${port}`);
    if (rawBaseUrl) {
      const normalizedBaseUrl = normalizeBackendBaseUrl(rawBaseUrl);
      if (normalizedBaseUrl !== derived) {
        throw new Error("BACKEND_BASE_URL tidak sinkron dengan BACKEND_HOST/BACKEND_PORT.");
      }
    }
    return derived;
  }

  return normalizeBackendBaseUrl(rawBaseUrl || `http://127.0.0.1:${defaultPort}`);
}

function resolveChannelPolicyFile(): string {
  const rawPolicyFile = process.env.DISCORD_CHANNEL_POLICY_FILE?.trim();
  if (rawPolicyFile) {
    return path.resolve(rawPolicyFile);
  }

  const rawStateDir = process.env.BOT_STATE_DIR?.trim();
  if (rawStateDir) {
    return path.resolve(rawStateDir, "channel-policy.json");
  }

  return path.resolve(__dirname, "../../runtime/channel-policy.json");
}

export function loadConfig(): AppConfig {
  const channelPolicyFile = resolveChannelPolicyFile();
  const adminRoleIds = parseSet(process.env.DISCORD_ADMIN_ROLE_IDS);
  const adminUserIds = parseSet(process.env.DISCORD_ADMIN_USER_IDS);
  if (adminRoleIds.size === 0 && adminUserIds.size === 0) {
    throw new Error("Set minimal salah satu: DISCORD_ADMIN_ROLE_IDS atau DISCORD_ADMIN_USER_IDS.");
  }

  return {
    token: requireEnv("DISCORD_BOT_TOKEN"),
    applicationId: requireEnv("DISCORD_APPLICATION_ID"),
    guildId: requireEnv("DISCORD_GUILD_ID"),
    backendBaseUrl: resolveBackendBaseUrl(8080),
    sharedSecret: requireEnv("INTERNAL_SHARED_SECRET"),
    adminRoleIds,
    adminUserIds,
    channelPolicyFile,
  };
}

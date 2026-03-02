import type { AppConfig } from "./config";

function extractRoleIds(member: unknown): string[] {
  if (!member || typeof member !== "object") return [];

  const rawRoles = (member as { roles?: unknown }).roles;
  if (Array.isArray(rawRoles)) {
    return rawRoles.filter((roleId): roleId is string => typeof roleId === "string" && roleId.length > 0);
  }

  if (!rawRoles || typeof rawRoles !== "object") return [];
  const rawCache = (rawRoles as { cache?: unknown }).cache;
  if (!rawCache || typeof rawCache !== "object") return [];

  const rawKeys = (rawCache as { keys?: unknown }).keys;
  if (typeof rawKeys !== "function") return [];

  const roleIds: string[] = [];
  for (const roleId of rawKeys.call(rawCache) as Iterable<unknown>) {
    if (typeof roleId === "string" && roleId.length > 0) {
      roleIds.push(roleId);
    }
  }
  return roleIds;
}

export function isAuthorized(member: unknown, userId: string, cfg: AppConfig): boolean {
  if (cfg.adminUserIds.size > 0 && cfg.adminUserIds.has(userId)) {
    return true;
  }

  if (cfg.adminRoleIds.size > 0) {
    for (const roleId of extractRoleIds(member)) {
      if (cfg.adminRoleIds.has(roleId)) {
        return true;
      }
    }
  }

  return false;
}

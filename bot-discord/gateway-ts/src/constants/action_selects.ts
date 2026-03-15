export interface ActionSingleSelectOption {
  label: string;
  value: string;
  description?: string;
}

export interface ActionSingleSelectConfig {
  fieldId: string;
  title: string;
  placeholder: string;
  options: readonly ActionSingleSelectOption[];
}

const ROOT_DOMAIN_FALLBACK_VALUES = [
  "vyxara1.web.id",
  "vyxara2.web.id",
] as const;

const NETWORK_SINGLE_SELECTS: Record<string, ActionSingleSelectConfig> = {
  set_dns_query_strategy: {
    fieldId: "strategy",
    title: "Set DNS Query Strategy",
    placeholder: "Pilih query strategy",
    options: [
      { label: "UseIP", value: "UseIP", description: "Gunakan IPv4/IPv6 otomatis" },
      { label: "UseIPv4", value: "UseIPv4", description: "Paksa IPv4" },
      { label: "UseIPv6", value: "UseIPv6", description: "Paksa IPv6" },
      { label: "PreferIPv4", value: "PreferIPv4", description: "Prioritaskan IPv4" },
      { label: "PreferIPv6", value: "PreferIPv6", description: "Prioritaskan IPv6" },
    ],
  },
};

const USER_SINGLE_SELECTS: Record<string, ActionSingleSelectConfig> = {
  extend_expiry: {
    fieldId: "mode",
    title: "Extend/Set Mode",
    placeholder: "Pilih mode expiry",
    options: [
      { label: "extend", value: "extend", description: "Tambah masa aktif (hari)" },
      { label: "set", value: "set", description: "Set expiry ke tanggal spesifik" },
    ],
  },
};

const QUOTA_SINGLE_SELECTS: Record<string, ActionSingleSelectConfig> = {
  manual_block: {
    fieldId: "enabled",
    title: "Manual Block",
    placeholder: "Pilih status manual block",
    options: [
      { label: "on", value: "on", description: "Aktifkan manual block" },
      { label: "off", value: "off", description: "Nonaktifkan manual block" },
    ],
  },
  ip_limit_enable: {
    fieldId: "enabled",
    title: "IP Limit",
    placeholder: "Pilih status IP limit",
    options: [
      { label: "on", value: "on", description: "Aktifkan IP limit enforcement" },
      { label: "off", value: "off", description: "Nonaktifkan IP limit enforcement" },
    ],
  },
  speed_limit: {
    fieldId: "enabled",
    title: "Speed Limit",
    placeholder: "Pilih status speed limit",
    options: [
      { label: "on", value: "on", description: "Aktifkan speed limit" },
      { label: "off", value: "off", description: "Nonaktifkan speed limit" },
    ],
  },
};

export function getSingleFieldSelectConfig(menuId: string, actionId: string): ActionSingleSelectConfig | null {
  if (menuId === "2") {
    return USER_SINGLE_SELECTS[actionId] || null;
  }
  if (menuId === "3") {
    return QUOTA_SINGLE_SELECTS[actionId] || null;
  }
  if (menuId === "4") {
    return NETWORK_SINGLE_SELECTS[actionId] || null;
  }
  if (menuId === "5" && actionId === "setup_domain_cloudflare") {
    return {
      fieldId: "root_domain",
      title: "Cloudflare Root Domain",
      placeholder: "Pilih root domain Cloudflare",
      options: ROOT_DOMAIN_FALLBACK_VALUES.map((value, idx) => ({
        label: value,
        value,
        description: `Root domain ${idx + 1}`,
      })),
    };
  }
  return null;
}

export function withSingleFieldSelectOptions(
  config: ActionSingleSelectConfig | null,
  values: readonly string[]
): ActionSingleSelectConfig | null {
  if (!config) {
    return null;
  }
  const normalizedValues = Array.from(
    new Set(
      values
        .map((value) => String(value || "").trim())
        .filter((value) => Boolean(value))
    )
  );
  if (normalizedValues.length === 0) {
    return config;
  }
  return {
    ...config,
    options: normalizedValues.map((value, idx) => ({
      label: value,
      value,
      description: `Root domain ${idx + 1}`,
    })),
  };
}

export function shouldSelectContinueToModal(menuId: string, actionId: string): boolean {
  if (menuId === "2" && actionId === "extend_expiry") {
    return true;
  }
  if (menuId === "5" && actionId === "setup_domain_cloudflare") {
    return true;
  }
  return false;
}

export function encodeSingleSelectPreset(fieldId: string, value: string): string {
  return `${fieldId}|${encodeURIComponent(value)}`;
}

export function decodeSingleSelectPreset(raw: string): { fieldId: string; value: string } | null {
  const source = String(raw || "").trim();
  if (!source || !source.includes("|")) {
    return null;
  }
  const idx = source.indexOf("|");
  const fieldId = source.slice(0, idx).trim();
  const encodedValue = source.slice(idx + 1).trim();
  if (!fieldId || !encodedValue) {
    return null;
  }
  try {
    return { fieldId, value: decodeURIComponent(encodedValue) };
  } catch {
    return { fieldId, value: encodedValue };
  }
}

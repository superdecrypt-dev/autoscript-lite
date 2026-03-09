import type { ActionMode, ButtonTone, MenuActionDef, MenuDefinition, ModalDef, ModalFieldDef } from "./views/types";
import { menu1 } from "./views/menu_1_status";
import { menu2 } from "./views/menu_2_user";
import { menu3 } from "./views/menu_3_quota";
import { menu4 } from "./views/menu_4_network";
import { menu5 } from "./views/menu_5_domain";
import { menu6 } from "./views/menu_6_speedtest";
import { menu7 } from "./views/menu_7_security";
import { menu8 } from "./views/menu_8_maintenance";
import { menu12 } from "./views/menu_12_traffic";

const BASE_MENUS: MenuDefinition[] = [menu1, menu2, menu3, menu4, menu5, menu6, menu7, menu8, menu12];
const KNOWN_BUTTON_TONES = new Set<ButtonTone>(["primary", "secondary", "success", "danger"]);
const KNOWN_ACTION_MODES = new Set<ActionMode>(["direct", "modal"]);

function cloneMenus(menus: MenuDefinition[]): MenuDefinition[] {
  return menus.map((menu) => ({
    ...menu,
    actions: menu.actions.map((action) => ({
      ...action,
      modal: action.modal
        ? {
            ...action.modal,
            fields: action.modal.fields.map((field) => ({ ...field })),
          }
        : undefined,
    })),
  }));
}

let disabledActionKeys = new Set<string>();
export let MENUS: MenuDefinition[] = cloneMenus(BASE_MENUS);

function rebuildDisabledActionKeys(): void {
  disabledActionKeys = new Set<string>();
  for (const menu of BASE_MENUS) {
    const visibleIds = new Set((MENUS.find((item) => item.id === menu.id)?.actions || []).map((action) => action.id));
    for (const action of menu.actions) {
      if (!visibleIds.has(action.id)) {
        disabledActionKeys.add(`${menu.id}:${action.id}`);
      }
    }
  }
}

rebuildDisabledActionKeys();

export function findMenu(menuId: string): MenuDefinition | undefined {
  return MENUS.find((m) => m.id === menuId);
}

export function findAction(menuId: string, actionId: string): MenuActionDef | undefined {
  const menu = findMenu(menuId);
  return menu?.actions.find((a) => a.id === actionId);
}

export function isKnownDisabledAction(menuId: string, actionId: string): boolean {
  return disabledActionKeys.has(`${menuId}:${actionId}`);
}

type RawField = {
  id: string;
  label: string;
  style: ModalFieldDef["style"];
  required: boolean;
  placeholder: string;
};

type RawModal = {
  title: string;
  fields: RawField[];
};

type RawAction = {
  id: string;
  label: string;
  mode?: ActionMode;
  style?: ButtonTone;
  dangerous?: boolean;
  confirm?: boolean;
  modal?: RawModal;
};

type RawMenu = {
  id: string;
  label: string;
  description: string;
  actions: RawAction[];
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function parseButtonTone(raw: unknown): ButtonTone | undefined {
  const value = String(raw || "").trim() as ButtonTone;
  return KNOWN_BUTTON_TONES.has(value) ? value : undefined;
}

function parseActionMode(raw: unknown): ActionMode | undefined {
  const value = String(raw || "").trim().toLowerCase() as ActionMode;
  return KNOWN_ACTION_MODES.has(value) ? value : undefined;
}

function parseRawField(raw: unknown): RawField | null {
  if (!isRecord(raw)) {
    return null;
  }
  const fieldId = String(raw.id || "").trim();
  if (!fieldId) {
    return null;
  }
  const style = String(raw.style || "").trim().toLowerCase() === "paragraph" ? "paragraph" : "short";
  return {
    id: fieldId,
    label: String(raw.label || fieldId),
    style,
    required: Boolean(raw.required),
    placeholder: String(raw.placeholder || "").trim(),
  };
}

function parseRawModal(raw: unknown): RawModal | undefined {
  if (!isRecord(raw)) {
    return undefined;
  }
  const fields = Array.isArray(raw.fields) ? raw.fields.map(parseRawField).filter((field): field is RawField => Boolean(field)) : [];
  return {
    title: String(raw.title || "Input"),
    fields,
  };
}

function parseRawAction(raw: unknown): RawAction | null {
  if (!isRecord(raw)) {
    return null;
  }
  const actionId = String(raw.id || "").trim();
  if (!actionId) {
    return null;
  }
  return {
    id: actionId,
    label: String(raw.label || actionId),
    mode: parseActionMode(raw.mode),
    style: parseButtonTone(raw.style),
    dangerous: typeof raw.dangerous === "boolean" ? raw.dangerous : undefined,
    confirm: typeof raw.confirm === "boolean" ? raw.confirm : undefined,
    modal: parseRawModal(raw.modal),
  };
}

function parseRawMenu(raw: unknown): RawMenu | null {
  if (!isRecord(raw)) {
    return null;
  }
  const menuId = String(raw.id || "").trim();
  if (!menuId) {
    return null;
  }
  const actions = Array.isArray(raw.actions) ? raw.actions.map(parseRawAction).filter((action): action is RawAction => Boolean(action)) : [];
  return {
    id: menuId,
    label: String(raw.label || `Menu ${menuId}`),
    description: String(raw.description || "").trim(),
    actions,
  };
}

function normalizeBackendModalForGateway(menuId: string, actionId: string, modal: RawModal | undefined): ModalDef | undefined {
  if (!modal) {
    return undefined;
  }

  let fields = [...modal.fields];
  if (menuId === "2" && (actionId === "extend_expiry" || actionId === "account_info")) {
    fields = fields.filter((field) => field.id !== "proto");
  }

  if (menuId === "2" && actionId === "add_user") {
    const fieldMap = new Map(fields.map((field) => [field.id, field]));
    const normalizedFields: ModalFieldDef[] = [];
    for (const fieldId of ["username", "days", "quota_gb", "ip_limit"]) {
      const field = fieldMap.get(fieldId);
      if (field) {
        normalizedFields.push({ ...field });
      }
    }
    if (fieldMap.has("speed_limit")) {
      normalizedFields.push({ ...fieldMap.get("speed_limit")! });
    } else if (
      fieldMap.has("speed_limit_enabled") &&
      fieldMap.has("speed_down_mbit") &&
      fieldMap.has("speed_up_mbit")
    ) {
      normalizedFields.push({
        id: "speed_limit",
        label: "Speed Limit Mbps (opsional)",
        style: "short",
        required: false,
        placeholder: "off | 20 | 20/10 (down/up)",
      });
    }
    return {
      title: modal.title,
      fields: normalizedFields,
    };
  }

  return {
    title: modal.title,
    fields: fields.map((field) => ({ ...field })),
  };
}

function mergeActionFromBackend(menuId: string, localAction: MenuActionDef, rawAction: RawAction, issues: string[]): MenuActionDef {
  const merged: MenuActionDef = {
    ...localAction,
    label: rawAction.label || localAction.label,
    style: rawAction.style || localAction.style,
    dangerous: rawAction.dangerous ?? localAction.dangerous,
    confirm: rawAction.confirm ?? localAction.confirm,
  };

  if (rawAction.mode && rawAction.mode !== localAction.mode) {
    issues.push(`backend action mode tidak cocok dengan gateway: ${menuId}:${localAction.id} (${rawAction.mode} != ${localAction.mode})`);
  }

  const localModal = localAction.modal;
  const normalizedModal = normalizeBackendModalForGateway(menuId, localAction.id, rawAction.modal);

  if (!localModal && normalizedModal) {
    issues.push(`backend action memiliki modal yang tidak didukung gateway: ${menuId}:${localAction.id}`);
    return merged;
  }
  if (localModal && !normalizedModal && rawAction.mode === "modal") {
    issues.push(`backend action modal tidak valid untuk gateway: ${menuId}:${localAction.id}`);
    return merged;
  }
  if (!localModal || !normalizedModal) {
    return merged;
  }

  const localFieldIds = localModal.fields.map((field) => field.id);
  const backendFieldIds = normalizedModal.fields.map((field) => field.id);
  if (localFieldIds.join(",") !== backendFieldIds.join(",")) {
    issues.push(
      `backend action field tidak cocok dengan gateway: ${menuId}:${localAction.id} ` +
        `(backend=[${backendFieldIds.join(",")}], gateway=[${localFieldIds.join(",")}])`
    );
    return merged;
  }

  merged.modal = {
    title: normalizedModal.title || localModal.title,
    fields: localModal.fields.map((field, idx) => {
      const backendField = normalizedModal.fields[idx];
      return {
        ...field,
        label: backendField.label || field.label,
        style: backendField.style || field.style,
        required: backendField.required,
        placeholder: backendField.placeholder || field.placeholder,
      };
    }),
  };
  return merged;
}

export function syncMenusFromBackend(rawMenus: unknown[]): string[] {
  const issues: string[] = [];
  const backendMenus = new Map<string, RawMenu>();

  for (const rawMenu of rawMenus) {
    const parsedMenu = parseRawMenu(rawMenu);
    if (!parsedMenu) {
      continue;
    }
    backendMenus.set(parsedMenu.id, parsedMenu);
  }

  for (const [menuId, backendMenu] of backendMenus.entries()) {
    const localMenu = BASE_MENUS.find((menu) => menu.id === menuId);
    if (!localMenu) {
      issues.push(`backend menu tidak dikenal oleh gateway: ${menuId}`);
      continue;
    }
    const localActionIds = new Set(localMenu.actions.map((action) => action.id));
    for (const action of backendMenu.actions) {
      if (!localActionIds.has(action.id)) {
        issues.push(`backend action tidak dikenal oleh gateway: ${menuId}:${action.id}`);
      }
    }
  }

  MENUS = cloneMenus(BASE_MENUS)
    .map((menu) => {
      const backendMenu = backendMenus.get(menu.id);
      if (!backendMenu) return null;
      const backendActions = new Map(backendMenu.actions.map((action) => [action.id, action]));
      const actions = menu.actions
        .filter((action) => backendActions.has(action.id))
        .map((action) => mergeActionFromBackend(menu.id, action, backendActions.get(action.id)!, issues));
      if (actions.length === 0) return null;
      return {
        ...menu,
        label: backendMenu.label || menu.label,
        description: backendMenu.description || menu.description,
        actions,
      };
    })
    .filter((menu): menu is MenuDefinition => Boolean(menu));

  rebuildDisabledActionKeys();
  return issues;
}

import type { MenuActionDef, MenuDefinition } from "./views/types";
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

export function syncMenusFromBackend(rawMenus: unknown[]): string[] {
  const warnings: string[] = [];
  const allowed = new Map<string, Set<string>>();

  for (const rawMenu of rawMenus) {
    if (!rawMenu || typeof rawMenu !== "object") continue;
    const menuId = String((rawMenu as { id?: unknown }).id || "").trim();
    if (!menuId) continue;
    const rawActions = Array.isArray((rawMenu as { actions?: unknown }).actions)
      ? ((rawMenu as { actions?: unknown[] }).actions || [])
      : [];
    const actionIds = new Set<string>();
    for (const rawAction of rawActions) {
      if (!rawAction || typeof rawAction !== "object") continue;
      const actionId = String((rawAction as { id?: unknown }).id || "").trim();
      if (actionId) actionIds.add(actionId);
    }
    allowed.set(menuId, actionIds);
  }

  for (const [menuId, actionIds] of allowed.entries()) {
    const localMenu = BASE_MENUS.find((menu) => menu.id === menuId);
    if (!localMenu) {
      warnings.push(`backend menu tidak dikenal oleh gateway: ${menuId}`);
      continue;
    }
    const localActionIds = new Set(localMenu.actions.map((action) => action.id));
    for (const actionId of actionIds) {
      if (!localActionIds.has(actionId)) {
        warnings.push(`backend action tidak dikenal oleh gateway: ${menuId}:${actionId}`);
      }
    }
  }

  MENUS = cloneMenus(BASE_MENUS)
    .map((menu) => {
      const allowedActions = allowed.get(menu.id);
      if (!allowedActions) return null;
      const actions = menu.actions.filter((action) => allowedActions.has(action.id));
      if (actions.length === 0) return null;
      return {
        ...menu,
        actions,
      };
    })
    .filter((menu): menu is MenuDefinition => Boolean(menu));

  rebuildDisabledActionKeys();
  return warnings;
}

import { randomBytes } from "crypto";

interface Entry<T> {
  createdAtMs: number;
  payload: T;
}

const EXPIRE_MS = 10 * 60 * 1000;
const MAX_ENTRIES = 512;

const store = new Map<string, Entry<unknown>>();

function nowMs(): number {
  return Date.now();
}

function cleanup(): void {
  const cutoff = nowMs() - EXPIRE_MS;
  for (const [token, entry] of store.entries()) {
    if (entry.createdAtMs < cutoff) {
      store.delete(token);
    }
  }

  if (store.size <= MAX_ENTRIES) return;
  const ordered = [...store.entries()].sort((a, b) => a[1].createdAtMs - b[1].createdAtMs);
  const removeCount = store.size - MAX_ENTRIES;
  for (let i = 0; i < removeCount; i += 1) {
    store.delete(ordered[i][0]);
  }
}

export function createMenuState<T>(payload: T): string {
  cleanup();
  let token = "";
  do {
    token = randomBytes(9).toString("base64url");
  } while (store.has(token));
  store.set(token, { createdAtMs: nowMs(), payload });
  return token;
}

export function getMenuState<T>(token: string): T | null {
  cleanup();
  const entry = store.get(token);
  if (!entry) return null;
  if (entry.createdAtMs + EXPIRE_MS < nowMs()) {
    store.delete(token);
    return null;
  }
  return entry.payload as T;
}

export function deleteMenuState(token: string): void {
  store.delete(token);
}

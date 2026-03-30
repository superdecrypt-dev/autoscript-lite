import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const rootDir = resolve(dirname(currentFile), "..");
const sourceDir = resolve(rootDir, "pages");
const outputDir = resolve(rootDir, "dist");

const fallbackConfigPath = resolve(sourceDir, "config.js");
const fallbackConfig = readFileSync(fallbackConfigPath, "utf8");
const fallbackValues = extractFallbackConfig(fallbackConfig);

const apiBaseUrl = normalizeUrl(process.env.PAGES_API_BASE_URL || fallbackValues.apiBaseUrl);
const turnstileSiteKey = String(
  process.env.PAGES_TURNSTILE_SITE_KEY || process.env.TURNSTILE_SITE_KEY || fallbackValues.turnstileSiteKey
).trim();

rmSync(outputDir, { force: true, recursive: true });
mkdirSync(outputDir, { recursive: true });
cpSync(sourceDir, outputDir, { recursive: true });

const generatedConfig = `window.AUTOSCRIPT_PORTAL_CONFIG = ${JSON.stringify(
  {
    apiBaseUrl,
    turnstileSiteKey,
  },
  null,
  2
)};\n`;

writeFileSync(resolve(outputDir, "config.js"), generatedConfig, "utf8");

if (!apiBaseUrl) {
  console.warn("[build:pages] PAGES_API_BASE_URL belum di-set; dist/config.js tetap kosong.");
}

if (!turnstileSiteKey) {
  console.warn("[build:pages] PAGES_TURNSTILE_SITE_KEY belum di-set; portal akan mengandalkan /api/public/config.");
}

console.log(`[build:pages] wrote ${resolve(outputDir, "config.js")}`);

function extractFallbackConfig(source) {
  return {
    apiBaseUrl: matchConfigValue(source, "apiBaseUrl"),
    turnstileSiteKey: matchConfigValue(source, "turnstileSiteKey"),
  };
}

function matchConfigValue(source, key) {
  const matcher = new RegExp(`${key}:\\s*["']([^"']*)["']`);
  const match = source.match(matcher);
  return match ? match[1].trim() : "";
}

function normalizeUrl(value) {
  const raw = String(value || "").trim().replace(/\/+$/, "");
  if (!raw) {
    return "";
  }
  try {
    return new URL(raw).origin;
  } catch (_error) {
    return raw;
  }
}

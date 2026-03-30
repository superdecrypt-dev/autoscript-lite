const publicState = {
  apiBaseUrl: (window.AUTOSCRIPT_PORTAL_CONFIG?.apiBaseUrl || "").replace(/\/+$/, ""),
  turnstileSiteKey: window.AUTOSCRIPT_PORTAL_CONFIG?.turnstileSiteKey || "",
  licenseDurationDays: 14,
  workerConfigLoaded: false,
  widgets: {
    create: null,
    status: null,
    renew: null,
  },
};

const publicDom = {
  banner: document.getElementById("public-banner"),
  statusBadge: document.getElementById("public-status-badge"),
  createForm: document.getElementById("create-form"),
  statusForm: document.getElementById("status-form"),
  renewForm: document.getElementById("renew-form"),
  createIp: document.getElementById("create-ip"),
  statusIp: document.getElementById("status-ip"),
  renewEntryId: document.getElementById("renew-entry-id"),
  renewIp: document.getElementById("renew-ip"),
  renewToken: document.getElementById("renew-token"),
  createResult: document.getElementById("create-result"),
  statusResult: document.getElementById("status-result"),
  renewResult: document.getElementById("renew-result"),
  durationDays: document.getElementById("license-duration-days"),
  renewDurationDays: document.getElementById("renew-duration-days"),
  createTurnstile: document.getElementById("create-turnstile"),
  statusTurnstile: document.getElementById("status-turnstile"),
  renewTurnstile: document.getElementById("renew-turnstile"),
};

bootstrapPublicPortal();

async function bootstrapPublicPortal() {
  bindPublicEvents();
  applyRenewPrefillFromUrl();
  renderDurationDays();
  if (!publicState.apiBaseUrl) {
    setPublicBanner("Operator belum mengisi API base URL di config.js.", "error");
    setStatusBadge("Portal not configured", "error");
    return;
  }
  await loadWorkerPublicConfig();
  renderTurnstileWidgetsWhenReady();
}

function bindPublicEvents() {
  publicDom.createForm.addEventListener("submit", handleCreateSubmit);
  publicDom.statusForm.addEventListener("submit", handleStatusSubmit);
  publicDom.renewForm.addEventListener("submit", handleRenewSubmit);
}

async function loadWorkerPublicConfig() {
  try {
    const payload = await publicApiFetch("/api/public/config", { method: "GET" });
    publicState.workerConfigLoaded = true;
    publicState.licenseDurationDays = Number(payload.license_duration_days || 14);
    if (payload.turnstile_site_key) {
      publicState.turnstileSiteKey = payload.turnstile_site_key;
    }
    renderDurationDays();
    setPublicBanner("Portal siap dipakai. Selesaikan Turnstile untuk setiap aksi publik.", "ok");
    setStatusBadge("Worker connected", "ok");
  } catch (error) {
    setPublicBanner(error.message || "Gagal mengambil konfigurasi Worker publik.", "error");
    setStatusBadge("Worker config failed", "error");
  }
}

function renderDurationDays() {
  publicDom.durationDays.textContent = String(publicState.licenseDurationDays);
  publicDom.renewDurationDays.textContent = String(publicState.licenseDurationDays);
}

function renderTurnstileWidgetsWhenReady() {
  if (!publicState.turnstileSiteKey) {
    setPublicBanner("TURNSTILE_SITE_KEY belum tersedia di portal.", "warn");
    return;
  }
  if (!window.turnstile) {
    window.setTimeout(renderTurnstileWidgetsWhenReady, 250);
    return;
  }
  if (!publicState.widgets.create) {
    publicState.widgets.create = window.turnstile.render(publicDom.createTurnstile, {
      sitekey: publicState.turnstileSiteKey,
      theme: "light",
    });
  }
  if (!publicState.widgets.status) {
    publicState.widgets.status = window.turnstile.render(publicDom.statusTurnstile, {
      sitekey: publicState.turnstileSiteKey,
      theme: "light",
    });
  }
  if (!publicState.widgets.renew) {
    publicState.widgets.renew = window.turnstile.render(publicDom.renewTurnstile, {
      sitekey: publicState.turnstileSiteKey,
      theme: "light",
    });
  }
}

function applyRenewPrefillFromUrl() {
  const params = new URLSearchParams(window.location.search);
  if ((params.get("mode") || "").trim().toLowerCase() === "renew") {
    publicDom.renewEntryId.value = params.get("entry") || "";
    publicDom.renewIp.value = params.get("ip") || "";
    window.setTimeout(() => {
      publicDom.renewEntryId.scrollIntoView({ behavior: "smooth", block: "center" });
    }, 120);
  }
}

async function handleCreateSubmit(event) {
  event.preventDefault();
  const turnstileToken = getTurnstileResponse("create");
  if (!turnstileToken) {
    showPublicResult(publicDom.createResult, "Selesaikan Turnstile challenge dulu.", "error");
    return;
  }

  try {
    const payload = await publicApiFetch("/api/public/license/create", {
      method: "POST",
      body: JSON.stringify({
        ip: publicDom.createIp.value.trim(),
        turnstile_token: turnstileToken,
      }),
    });
    resetTurnstile("create");
    publicDom.createForm.reset();
    publicDom.renewEntryId.value = payload.item.entry_id || "";
    publicDom.renewIp.value = payload.item.ip || "";
    showPublicResult(
      publicDom.createResult,
      renderCreateResult(payload),
      "ok",
      true
    );
  } catch (error) {
    resetTurnstile("create");
    showPublicResult(publicDom.createResult, error.message || "Create gagal.", "error");
  }
}

async function handleStatusSubmit(event) {
  event.preventDefault();
  const turnstileToken = getTurnstileResponse("status");
  if (!turnstileToken) {
    showPublicResult(publicDom.statusResult, "Selesaikan Turnstile challenge dulu.", "error");
    return;
  }

  try {
    const payload = await publicApiFetch("/api/public/license/status", {
      method: "POST",
      body: JSON.stringify({
        ip: publicDom.statusIp.value.trim(),
        turnstile_token: turnstileToken,
      }),
    });
    resetTurnstile("status");
    showPublicResult(
      publicDom.statusResult,
      renderStatusResult(payload),
      payload.status === "active" ? "ok" : "error",
      true
    );
    if (payload.entry_id) {
      publicDom.renewEntryId.value = payload.entry_id;
      publicDom.renewIp.value = payload.ip || publicDom.statusIp.value.trim();
    }
  } catch (error) {
    resetTurnstile("status");
    showPublicResult(publicDom.statusResult, error.message || "Check status gagal.", "error");
  }
}

async function handleRenewSubmit(event) {
  event.preventDefault();
  const turnstileToken = getTurnstileResponse("renew");
  if (!turnstileToken) {
    showPublicResult(publicDom.renewResult, "Selesaikan Turnstile challenge dulu.", "error");
    return;
  }

  try {
    const payload = await publicApiFetch("/api/public/license/renew", {
      method: "POST",
      body: JSON.stringify({
        entry_id: publicDom.renewEntryId.value.trim(),
        ip: publicDom.renewIp.value.trim(),
        renewal_token: publicDom.renewToken.value.trim(),
        turnstile_token: turnstileToken,
      }),
    });
    resetTurnstile("renew");
    showPublicResult(
      publicDom.renewResult,
      renderRenewResult(payload),
      "ok",
      true
    );
  } catch (error) {
    resetTurnstile("renew");
    showPublicResult(publicDom.renewResult, error.message || "Renew gagal.", "error");
  }
}

function renderCreateResult(payload) {
  const item = payload.item || {};
  const renewalLink = payload.renewal_link || "";
  return `
    <h3 class="result-title">License Created</h3>
    <p>${escapeHtml(payload.message || "")}</p>
    <div class="result-grid">
      <article>
        <strong>Entry ID</strong>
        <span class="mono">${escapeHtml(item.entry_id || "-")}</span>
      </article>
      <article>
        <strong>IPv4</strong>
        <span class="mono">${escapeHtml(item.ip || "-")}</span>
      </article>
      <article>
        <strong>Status</strong>
        <span>${escapeHtml(item.status || "-")}</span>
      </article>
      <article>
        <strong>Expires At</strong>
        <span>${escapeHtml(formatDate(item.expires_at) || "-")}</span>
      </article>
    </div>
    <p>Simpan renewal token berikut. Token ini hanya tampil sekali.</p>
    <div class="mono-block">${escapeHtml(payload.renewal_token || "")}</div>
    ${
      renewalLink
        ? `<p>Renewal link: <a class="result-link" href="${escapeHtml(renewalLink)}">${escapeHtml(renewalLink)}</a></p>`
        : ""
    }
  `;
}

function renderStatusResult(payload) {
  return `
    <h3 class="result-title">License Status</h3>
    <div class="result-grid">
      <article>
        <strong>Status</strong>
        <span>${escapeHtml(payload.status || "-")}</span>
      </article>
      <article>
        <strong>IPv4</strong>
        <span class="mono">${escapeHtml(payload.ip || "-")}</span>
      </article>
      <article>
        <strong>Entry ID</strong>
        <span class="mono">${escapeHtml(payload.entry_id || "-")}</span>
      </article>
      <article>
        <strong>Days Remaining</strong>
        <span>${escapeHtml(String(payload.days_remaining ?? 0))}</span>
      </article>
      <article>
        <strong>Expires At</strong>
        <span>${escapeHtml(formatDate(payload.expires_at) || "-")}</span>
      </article>
      <article>
        <strong>Renewable</strong>
        <span>${payload.renewable ? "yes" : "no"}</span>
      </article>
    </div>
  `;
}

function renderRenewResult(payload) {
  const item = payload.item || {};
  return `
    <h3 class="result-title">Renew Success</h3>
    <p>${escapeHtml(payload.message || "")}</p>
    <div class="result-grid">
      <article>
        <strong>Entry ID</strong>
        <span class="mono">${escapeHtml(item.entry_id || "-")}</span>
      </article>
      <article>
        <strong>IPv4</strong>
        <span class="mono">${escapeHtml(item.ip || "-")}</span>
      </article>
      <article>
        <strong>Status</strong>
        <span>${escapeHtml(item.status || "-")}</span>
      </article>
      <article>
        <strong>New Expiry</strong>
        <span>${escapeHtml(formatDate(item.expires_at) || "-")}</span>
      </article>
    </div>
  `;
}

async function publicApiFetch(path, options = {}) {
  const response = await fetch(`${publicState.apiBaseUrl}${path}`, {
    method: options.method || "GET",
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    body: options.body,
  });

  let payload = {};
  try {
    payload = await response.json();
  } catch (_error) {
    payload = {};
  }

  if (!response.ok) {
    throw new Error(payload.message || `HTTP ${response.status}`);
  }
  return payload;
}

function getTurnstileResponse(key) {
  const widgetId = publicState.widgets[key];
  if (!widgetId || !window.turnstile) {
    return "";
  }
  return window.turnstile.getResponse(widgetId) || "";
}

function resetTurnstile(key) {
  const widgetId = publicState.widgets[key];
  if (widgetId && window.turnstile) {
    window.turnstile.reset(widgetId);
  }
}

function showPublicResult(target, htmlOrText, tone = "ok", isHtml = false) {
  target.className = `result-card ${tone}`;
  target.innerHTML = isHtml ? htmlOrText : `<p>${escapeHtml(htmlOrText)}</p>`;
}

function setPublicBanner(message, tone = "muted") {
  publicDom.banner.textContent = message;
  publicDom.banner.className = `public-banner ${tone}`;
}

function setStatusBadge(message, tone = "muted") {
  publicDom.statusBadge.textContent = message;
  publicDom.statusBadge.className = `status-pill ${tone}`;
}

function formatDate(value) {
  if (!value) {
    return "";
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return value;
  }
  return new Intl.DateTimeFormat("en-GB", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(parsed);
}

function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

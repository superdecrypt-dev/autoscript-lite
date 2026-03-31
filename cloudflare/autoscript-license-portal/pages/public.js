const publicState = {
  apiBaseUrl: (window.AUTOSCRIPT_PORTAL_CONFIG?.apiBaseUrl || "").replace(/\/+$/, ""),
  licenseDurationDays: 14,
  workerConfigLoaded: false,
};

const publicDom = {
  banner: document.getElementById("public-banner"),
  statusBadge: document.getElementById("public-status-badge"),
  createForm: document.getElementById("create-form"),
  statusForm: document.getElementById("status-form"),
  createIp: document.getElementById("create-ip"),
  statusIp: document.getElementById("status-ip"),
  createResult: document.getElementById("create-result"),
  statusResult: document.getElementById("status-result"),
  durationDays: document.getElementById("license-duration-days"),
};

bootstrapPublicPortal();

async function bootstrapPublicPortal() {
  bindPublicEvents();
  renderDurationDays();
  if (!publicState.apiBaseUrl) {
    setPublicBanner("Operator belum mengisi API base URL di config.js.", "error");
    setStatusBadge("Portal not configured", "error");
    return;
  }
  await loadWorkerPublicConfig();
}

function bindPublicEvents() {
  publicDom.createForm.addEventListener("submit", handleCreateSubmit);
  publicDom.statusForm.addEventListener("submit", handleStatusSubmit);
}

async function loadWorkerPublicConfig() {
  try {
    const payload = await publicApiFetch("/api/public/config", { method: "GET" });
    publicState.workerConfigLoaded = true;
    publicState.licenseDurationDays = Number(payload.license_duration_days || 14);
    renderDurationDays();
    setPublicBanner("Portal siap dipakai. Input IP VPS untuk create, cek status, atau renew.", "ok");
    setStatusBadge("Worker connected", "ok");
  } catch (error) {
    setPublicBanner(error.message || "Gagal mengambil konfigurasi Worker publik.", "error");
    setStatusBadge("Worker config failed", "error");
  }
}

function renderDurationDays() {
  publicDom.durationDays.textContent = String(publicState.licenseDurationDays);
}

async function handleCreateSubmit(event) {
  event.preventDefault();

  try {
    const payload = await publicApiFetch("/api/public/license/create", {
      method: "POST",
      body: JSON.stringify({
        ip: publicDom.createIp.value.trim(),
      }),
    });
    publicDom.createForm.reset();
    showPublicResult(
      publicDom.createResult,
      renderCreateResult(payload),
      "ok",
      true
    );
  } catch (error) {
    showPublicResult(publicDom.createResult, error.message || "Create gagal.", "error");
  }
}

async function handleStatusSubmit(event) {
  event.preventDefault();

  try {
    const payload = await publicApiFetch("/api/public/license/status", {
      method: "POST",
      body: JSON.stringify({
        ip: publicDom.statusIp.value.trim(),
      }),
    });
    showPublicResult(
      publicDom.statusResult,
      renderStatusResult(payload),
      payload.status === "active" ? "ok" : "error",
      true
    );
  } catch (error) {
    showPublicResult(publicDom.statusResult, error.message || "Check status gagal.", "error");
  }
}

function renderCreateResult(payload) {
  const item = payload.item || {};
  return `
    <h3 class="result-title">IP Activated</h3>
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
    <p>Untuk memperpanjang, input IP yang sama lagi di form aktivasi.</p>
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

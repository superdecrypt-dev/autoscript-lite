const state = {
  apiBaseUrl:
    localStorage.getItem("autoscriptLicenseApiBaseUrl") ||
    (window.AUTOSCRIPT_PORTAL_CONFIG?.apiBaseUrl || "").replace(/\/+$/, ""),
  entries: [],
  auditLogs: [],
  session: null,
};

const dom = {
  apiBaseInput: document.getElementById("api-base-input"),
  saveApiBaseBtn: document.getElementById("save-api-base-btn"),
  refreshDashboardBtn: document.getElementById("refresh-dashboard-btn"),
  refreshAuditBtn: document.getElementById("refresh-audit-btn"),
  resetFormBtn: document.getElementById("reset-form-btn"),
  cancelEditBtn: document.getElementById("cancel-edit-btn"),
  statusBanner: document.getElementById("status-banner"),
  sessionBadge: document.getElementById("session-badge"),
  metricActive: document.getElementById("metric-active"),
  metricExpired: document.getElementById("metric-expired"),
  metricRevoked: document.getElementById("metric-revoked"),
  metricAudit: document.getElementById("metric-audit"),
  searchInput: document.getElementById("search-input"),
  statusFilter: document.getElementById("status-filter"),
  entriesBody: document.getElementById("entries-body"),
  auditBody: document.getElementById("audit-body"),
  form: document.getElementById("entry-form"),
  formTitle: document.getElementById("form-title"),
  entryId: document.getElementById("entry-id"),
  fieldIp: document.getElementById("field-ip"),
  fieldLabel: document.getElementById("field-label"),
  fieldOwner: document.getElementById("field-owner"),
  fieldExpiresAt: document.getElementById("field-expires-at"),
  fieldNotes: document.getElementById("field-notes"),
  submitEntryBtn: document.getElementById("submit-entry-btn"),
};

bootstrap();

function bootstrap() {
  dom.apiBaseInput.value = state.apiBaseUrl;
  bindEvents();
  refreshVisuals();
  if (state.apiBaseUrl) {
    refreshDashboard();
  }
}

function bindEvents() {
  dom.saveApiBaseBtn.addEventListener("click", handleSaveApiBase);
  dom.refreshDashboardBtn.addEventListener("click", refreshDashboard);
  dom.refreshAuditBtn.addEventListener("click", refreshAuditLogs);
  dom.resetFormBtn.addEventListener("click", resetForm);
  dom.cancelEditBtn.addEventListener("click", resetForm);
  dom.form.addEventListener("submit", handleSubmitEntry);
  dom.searchInput.addEventListener("input", refreshEntries);
  dom.statusFilter.addEventListener("change", refreshEntries);
}

async function handleSaveApiBase() {
  const candidate = normalizeApiBase(dom.apiBaseInput.value);
  if (!candidate) {
    setBanner("Masukkan Worker API Base URL yang valid.", "error");
    return;
  }
  state.apiBaseUrl = candidate;
  localStorage.setItem("autoscriptLicenseApiBaseUrl", candidate);
  setBanner("Worker API Base URL disimpan. Mencoba koneksi admin...", "muted");
  await refreshDashboard();
}

async function refreshDashboard() {
  if (!ensureApiBase()) {
    return;
  }
  try {
    const [session, entriesPayload, auditPayload] = await Promise.all([
      apiFetch("/api/admin/session"),
      fetchEntries(),
      fetchAuditLogs(),
    ]);
    state.session = session;
    state.entries = entriesPayload.items || [];
    state.auditLogs = auditPayload.items || [];
    setBanner(`Connected as ${session.admin_email || "admin"}`, "ok");
    dom.sessionBadge.textContent = session.admin_email || "Access Verified";
    dom.sessionBadge.className = "session-badge ok";
    refreshVisuals();
  } catch (error) {
    state.session = null;
    state.entries = [];
    state.auditLogs = [];
    dom.sessionBadge.textContent = "Connection Failed";
    dom.sessionBadge.className = "session-badge error";
    setBanner(error.message || "Gagal mengambil data dari Worker API.", "error");
    refreshVisuals();
  }
}

async function refreshEntries() {
  if (!ensureApiBase()) {
    return;
  }
  try {
    const payload = await fetchEntries();
    state.entries = payload.items || [];
    refreshVisuals();
  } catch (error) {
    setBanner(error.message || "Gagal refresh daftar IP.", "error");
  }
}

async function refreshAuditLogs() {
  if (!ensureApiBase()) {
    return;
  }
  try {
    const payload = await fetchAuditLogs();
    state.auditLogs = payload.items || [];
    refreshVisuals();
  } catch (error) {
    setBanner(error.message || "Gagal refresh audit log.", "error");
  }
}

async function fetchEntries() {
  const search = dom.searchInput.value.trim();
  const status = dom.statusFilter.value;
  const params = new URLSearchParams();
  if (search) {
    params.set("search", search);
  }
  if (status && status !== "all") {
    params.set("status", status);
  }
  const suffix = params.toString() ? `?${params.toString()}` : "";
  return apiFetch(`/api/admin/license-entries${suffix}`);
}

async function fetchAuditLogs() {
  return apiFetch("/api/admin/audit-logs?limit=120");
}

async function handleSubmitEntry(event) {
  event.preventDefault();
  if (!ensureApiBase()) {
    return;
  }
  const id = dom.entryId.value.trim();
  const payload = {
    ip: dom.fieldIp.value.trim(),
    label: dom.fieldLabel.value.trim(),
    owner: dom.fieldOwner.value.trim(),
    notes: dom.fieldNotes.value.trim(),
    expires_at: normalizeDateTimeLocal(dom.fieldExpiresAt.value),
  };

  try {
    if (id) {
      await apiFetch(`/api/admin/license-entries/${encodeURIComponent(id)}`, {
        method: "PATCH",
        body: JSON.stringify(payload),
      });
      setBanner(`Entry ${payload.ip} berhasil diperbarui.`, "ok");
    } else {
      await apiFetch("/api/admin/license-entries", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      setBanner(`Entry ${payload.ip} berhasil dibuat.`, "ok");
    }
    resetForm();
    await refreshDashboard();
  } catch (error) {
    setBanner(error.message || "Gagal menyimpan entry.", "error");
  }
}

function beginEditEntry(id) {
  const entry = state.entries.find((item) => item.id === id);
  if (!entry) {
    return;
  }
  dom.entryId.value = entry.id;
  dom.fieldIp.value = entry.ip || "";
  dom.fieldLabel.value = entry.label || "";
  dom.fieldOwner.value = entry.owner || "";
  dom.fieldNotes.value = entry.notes || "";
  dom.fieldExpiresAt.value = formatForDateTimeLocal(entry.expires_at || "");
  dom.formTitle.textContent = `Edit ${entry.ip}`;
  dom.submitEntryBtn.textContent = "Update Entry";
  window.scrollTo({ top: 0, behavior: "smooth" });
}

async function toggleEntry(id, action) {
  const label = action === "revoke" ? "revoke" : "reactivate";
  const entry = state.entries.find((item) => item.id === id);
  if (!entry) {
    return;
  }
  try {
    await apiFetch(`/api/admin/license-entries/${encodeURIComponent(id)}/${label}`, {
      method: "POST",
      body: JSON.stringify({}),
    });
    setBanner(`Entry ${entry.ip} berhasil di-${label}.`, "ok");
    await refreshDashboard();
  } catch (error) {
    setBanner(error.message || `Gagal ${label} entry.`, "error");
  }
}

function resetForm() {
  dom.entryId.value = "";
  dom.form.reset();
  dom.formTitle.textContent = "Create IP Entry";
  dom.submitEntryBtn.textContent = "Save Entry";
}

function refreshVisuals() {
  renderSummary();
  renderEntries();
  renderAuditLogs();
}

function renderSummary() {
  const active = state.entries.filter((item) => item.effective_status === "active").length;
  const expired = state.entries.filter((item) => item.effective_status === "expired").length;
  const revoked = state.entries.filter((item) => item.effective_status === "revoked").length;
  dom.metricActive.textContent = String(active);
  dom.metricExpired.textContent = String(expired);
  dom.metricRevoked.textContent = String(revoked);
  dom.metricAudit.textContent = String(state.auditLogs.length);
}

function renderEntries() {
  if (!state.entries.length) {
    dom.entriesBody.innerHTML = `
      <tr>
        <td colspan="6" class="empty-row">Belum ada entry IP. Tambahkan dari form di samping.</td>
      </tr>
    `;
    return;
  }

  dom.entriesBody.innerHTML = state.entries
    .map((entry) => {
      const canRevoke = entry.effective_status !== "revoked";
      const canReactivate = entry.status === "revoked";
      return `
        <tr>
          <td>
            <div class="entry-meta">
              <strong class="mono">${escapeHtml(entry.ip)}</strong>
              <span>${escapeHtml(entry.label || "-")}</span>
            </div>
          </td>
          <td>
            <div class="entry-meta">
              <strong>${escapeHtml(entry.owner || "-")}</strong>
              <span>${escapeHtml(entry.notes || "-")}</span>
            </div>
          </td>
          <td><span class="status-pill ${entry.effective_status}">${escapeHtml(entry.effective_status)}</span></td>
          <td>${escapeHtml(formatDate(entry.expires_at) || "Never")}</td>
          <td>${escapeHtml(formatDate(entry.updated_at) || "-")}</td>
          <td>
            <div class="action-stack">
              <button type="button" data-action="edit" data-entry-id="${entry.id}">Edit</button>
              ${canRevoke ? `<button type="button" data-action="revoke" data-entry-id="${entry.id}">Revoke</button>` : ""}
              ${canReactivate ? `<button type="button" data-action="reactivate" data-entry-id="${entry.id}">Reactivate</button>` : ""}
            </div>
          </td>
        </tr>
      `;
    })
    .join("");

  dom.entriesBody.querySelectorAll("button[data-action]").forEach((button) => {
    button.addEventListener("click", async () => {
      const { action, entryId } = button.dataset;
      if (action === "edit") {
        beginEditEntry(entryId);
      } else if (action === "revoke") {
        await toggleEntry(entryId, "revoke");
      } else if (action === "reactivate") {
        await toggleEntry(entryId, "reactivate");
      }
    });
  });
}

function renderAuditLogs() {
  if (!state.auditLogs.length) {
    dom.auditBody.innerHTML = `
      <tr>
        <td colspan="6" class="empty-row">Belum ada audit log.</td>
      </tr>
    `;
    return;
  }

  dom.auditBody.innerHTML = state.auditLogs
    .map(
      (log) => `
        <tr>
          <td>${escapeHtml(formatDate(log.created_at) || "-")}</td>
          <td>${escapeHtml(log.event_type || "-")}</td>
          <td class="mono">${escapeHtml(log.ip || "-")}</td>
          <td>${escapeHtml(log.stage || "-")}</td>
          <td>${escapeHtml(log.decision || "-")}</td>
          <td>${escapeHtml(log.actor_email || "worker")}</td>
        </tr>
      `
    )
    .join("");
}

async function apiFetch(path, options = {}) {
  const response = await fetch(`${state.apiBaseUrl}${path}`, {
    method: options.method || "GET",
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    credentials: "include",
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

function ensureApiBase() {
  if (state.apiBaseUrl) {
    return true;
  }
  setBanner("Set Worker API Base URL terlebih dahulu.", "error");
  return false;
}

function setBanner(message, tone = "muted") {
  dom.statusBanner.textContent = message;
  dom.statusBanner.className = `status-banner ${tone}`;
}

function normalizeApiBase(value) {
  const raw = String(value || "").trim().replace(/\/+$/, "");
  if (!raw) {
    return "";
  }
  try {
    const url = new URL(raw);
    return url.origin;
  } catch (_error) {
    return "";
  }
}

function normalizeDateTimeLocal(value) {
  if (!value) {
    return "";
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return "";
  }
  return parsed.toISOString();
}

function formatForDateTimeLocal(value) {
  if (!value) {
    return "";
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return "";
  }
  const tzOffset = parsed.getTimezoneOffset();
  const local = new Date(parsed.getTime() - tzOffset * 60 * 1000);
  return local.toISOString().slice(0, 16);
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

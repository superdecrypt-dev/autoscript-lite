const IPV4_RE = /^(?:\d{1,3}\.){3}\d{1,3}$/;
const ACCESS_JWKS_TTL_MS = 5 * 60 * 1000;

let cachedJwks = {
  fetchedAt: 0,
  keys: [],
};

export default {
  async fetch(request, env) {
    try {
      return await routeRequest(request, env);
    } catch (error) {
      return jsonResponse(
        {
          error: "internal_error",
          message: error instanceof Error ? error.message : "Unhandled error",
        },
        500
      );
    }
  },
};

async function routeRequest(request, env) {
  const url = new URL(request.url);
  const pathname = url.pathname.replace(/\/+$/, "") || "/";

  if (request.method === "OPTIONS" && pathname.startsWith("/api/public/")) {
    return buildPublicCorsResponse(request, env);
  }
  if (request.method === "OPTIONS" && pathname.startsWith("/api/admin/")) {
    return buildAdminCorsResponse(request, env);
  }

  if (request.method === "GET" && pathname === "/healthz") {
    return jsonResponse({ ok: true, service: "autoscript-license-api" });
  }

  if (request.method === "GET" && pathname === "/api/public/config") {
    return withPublicCors(request, env, jsonResponse(buildPublicConfig(env, url.origin)));
  }

  if (request.method === "POST" && pathname === "/api/public/license/create") {
    return withPublicCors(request, env, await handlePublicCreate(request, env));
  }

  if (request.method === "POST" && pathname === "/api/public/license/status") {
    return withPublicCors(request, env, await handlePublicStatus(request, env));
  }

  if (request.method === "POST" && pathname === "/api/public/license/renew") {
    return withPublicCors(request, env, await handlePublicRenew(request, env));
  }

  if (request.method === "POST" && pathname === "/api/v1/license/check") {
    return handleWorkerLicenseCheck(request, env);
  }

  if (pathname.startsWith("/api/admin/")) {
    const admin = await requireAdminAccess(request, env);
    if (admin.response) {
      return withAdminCors(request, env, admin.response);
    }

    if (request.method === "GET" && pathname === "/api/admin/session") {
      return withAdminCors(
        request,
        env,
        jsonResponse({
          admin_email: admin.email,
          cache_ttl_sec_default: parseIntSafe(env.CACHE_TTL_SEC_DEFAULT, 86400),
          license_duration_days: getLicenseDurationDays(env),
          worker_api_base_url: url.origin,
        })
      );
    }

    if (request.method === "GET" && pathname === "/api/admin/license-entries") {
      return withAdminCors(request, env, await handleAdminListEntries(request, env));
    }

    if (request.method === "POST" && pathname === "/api/admin/license-entries") {
      return withAdminCors(request, env, await handleAdminCreateEntry(request, env, admin.email));
    }

    if (request.method === "GET" && pathname === "/api/admin/audit-logs") {
      return withAdminCors(request, env, await handleAdminListAuditLogs(request, env));
    }

    const entryMatch = pathname.match(/^\/api\/admin\/license-entries\/([^/]+)$/);
    if (request.method === "PATCH" && entryMatch) {
      return withAdminCors(
        request,
        env,
        await handleAdminPatchEntry(request, env, admin.email, entryMatch[1])
      );
    }

    const revokeMatch = pathname.match(/^\/api\/admin\/license-entries\/([^/]+)\/revoke$/);
    if (request.method === "POST" && revokeMatch) {
      return withAdminCors(
        request,
        env,
        await handleAdminToggleEntry(request, env, admin.email, revokeMatch[1], "revoked")
      );
    }

    const reactivateMatch = pathname.match(/^\/api\/admin\/license-entries\/([^/]+)\/reactivate$/);
    if (request.method === "POST" && reactivateMatch) {
      return withAdminCors(
        request,
        env,
        await handleAdminToggleEntry(request, env, admin.email, reactivateMatch[1], "active")
      );
    }

    return withAdminCors(
      request,
      env,
      jsonResponse({ error: "not_found", message: "Admin endpoint tidak ditemukan" }, 404)
    );
  }

  return jsonResponse({ error: "not_found", message: "Endpoint tidak ditemukan" }, 404);
}

function buildPublicConfig(env, workerOrigin) {
  return {
    turnstile_site_key: String(env.TURNSTILE_SITE_KEY || "").trim(),
    license_duration_days: getLicenseDurationDays(env),
    public_ui_origin: String(env.PUBLIC_UI_ORIGIN || "").trim(),
    worker_api_base_url: workerOrigin,
  };
}

async function handleWorkerLicenseCheck(request, env) {
  const unauthorized = requireWorkerBearer(request, env);
  if (unauthorized) {
    return unauthorized;
  }

  const body = await parseJsonBody(request);
  if (body.error) {
    return body.error;
  }

  const publicIp = normalizeIpv4(body.data.public_ipv4);
  if (!publicIp) {
    return jsonResponse({ error: "invalid_request", message: "public_ipv4 harus IPv4 literal yang valid" }, 400);
  }

  const stage = normalizeStage(body.data.stage);
  const product = normalizeShortText(body.data.product, 64) || "autoscript";
  const hostname = normalizeShortText(body.data.hostname, 255);
  const entry = await getLicenseEntryByIp(env, publicIp);
  const decision = buildLicenseDecision(entry, env);

  await insertAuditLog(env, {
    eventType: "license_check",
    ip: publicIp,
    entryId: entry?.id || "",
    stage,
    decision: decision.allowed ? "allow" : "deny",
    actorEmail: "",
    requestIp: getVisitorIp(request),
    userAgent: request.headers.get("User-Agent") || "",
    payload: {
      hostname,
      product,
      reason: decision.reason,
      stage,
    },
  });

  return jsonResponse({
    allowed: decision.allowed,
    reason: decision.reason,
    cache_ttl_sec: parseIntSafe(env.CACHE_TTL_SEC_DEFAULT, 86400),
  });
}

async function handlePublicCreate(request, env) {
  const body = await parseJsonBody(request);
  if (body.error) {
    return body.error;
  }

  const visitorIp = getVisitorIp(request);
  const limit = await enforcePublicRateLimit(
    env,
    "public_create",
    visitorIp,
    parseIntSafe(env.PUBLIC_CREATE_LIMIT_MAX, 5),
    parseIntSafe(env.PUBLIC_CREATE_WINDOW_SEC, 900)
  );
  if (!limit.allowed) {
    await insertAuditLog(env, {
      eventType: "public_create_rate_limited",
      ip: "",
      entryId: "",
      stage: "public",
      decision: "rate_limited",
      actorEmail: "",
      requestIp: visitorIp,
      userAgent: request.headers.get("User-Agent") || "",
      payload: { retry_after_sec: limit.retryAfterSec },
    });
    return jsonResponse(
      {
        error: "rate_limited",
        message: "Terlalu banyak request create. Coba lagi nanti.",
        retry_after_sec: limit.retryAfterSec,
      },
      429
    );
  }

  const turnstile = await verifyTurnstile(body.data.turnstile_token, request, env);
  if (!turnstile.ok) {
    return jsonResponse({ error: "turnstile_failed", message: turnstile.message }, 400);
  }

  const publicIp = normalizeIpv4(body.data.ip);
  if (!publicIp) {
    return jsonResponse({ error: "invalid_request", message: "IP harus IPv4 literal yang valid" }, 400);
  }

  const existing = await getLicenseEntryByIp(env, publicIp);
  if (existing) {
    return jsonResponse(
      {
        error: "conflict",
        message: "IP sudah terdaftar. Gunakan Check Status atau Renew jika Anda pemilik renewal token.",
      },
      409
    );
  }

  const nowIso = nowIsoString();
  const durationDays = getLicenseDurationDays(env);
  const expiresAt = addDaysIso(nowIso, durationDays);
  const id = crypto.randomUUID();
  const renewalToken = generateRenewalToken();
  const renewalTokenHash = await hashRenewalToken(renewalToken, env);

  await runStatement(
    env,
    `
      INSERT INTO license_entries (
        id, ip, label, owner, notes, status, expires_at,
        created_at, updated_at, created_by, updated_by, revoked_at,
        entry_source, renewal_token_hash, last_renewed_at, created_request_ip
      )
      VALUES (?, ?, '', '', '', 'active', ?, ?, ?, 'public', 'public', NULL, 'public', ?, NULL, ?)
    `,
    [id, publicIp, expiresAt, nowIso, nowIso, renewalTokenHash, visitorIp]
  );

  await insertAuditLog(env, {
    eventType: "public_create",
    ip: publicIp,
    entryId: id,
    stage: "public",
    decision: "allow",
    actorEmail: "",
    requestIp: visitorIp,
    userAgent: request.headers.get("User-Agent") || "",
    payload: {
      expires_at: expiresAt,
      source: "public",
    },
  });

  const created = await getLicenseEntryById(env, id);
  return jsonResponse(
    {
      item: serializePublicStatusEntry(created, nowIso),
      renewal_token: renewalToken,
      renewal_link: buildRenewalLink(env, id, publicIp),
      message: `Izin IP aktif selama ${durationDays} hari. Simpan renewal token ini dengan aman.`,
    },
    201
  );
}

async function handlePublicStatus(request, env) {
  const body = await parseJsonBody(request);
  if (body.error) {
    return body.error;
  }

  const visitorIp = getVisitorIp(request);
  const limit = await enforcePublicRateLimit(
    env,
    "public_status",
    visitorIp,
    parseIntSafe(env.PUBLIC_STATUS_LIMIT_MAX, 30),
    parseIntSafe(env.PUBLIC_STATUS_WINDOW_SEC, 900)
  );
  if (!limit.allowed) {
    await insertAuditLog(env, {
      eventType: "public_status_rate_limited",
      ip: "",
      entryId: "",
      stage: "public",
      decision: "rate_limited",
      actorEmail: "",
      requestIp: visitorIp,
      userAgent: request.headers.get("User-Agent") || "",
      payload: { retry_after_sec: limit.retryAfterSec },
    });
    return jsonResponse(
      {
        error: "rate_limited",
        message: "Terlalu banyak request status. Coba lagi nanti.",
        retry_after_sec: limit.retryAfterSec,
      },
      429
    );
  }

  const turnstile = await verifyTurnstile(body.data.turnstile_token, request, env);
  if (!turnstile.ok) {
    return jsonResponse({ error: "turnstile_failed", message: turnstile.message }, 400);
  }

  const publicIp = normalizeIpv4(body.data.ip);
  if (!publicIp) {
    return jsonResponse({ error: "invalid_request", message: "IP harus IPv4 literal yang valid" }, 400);
  }

  const entry = await getLicenseEntryByIp(env, publicIp);
  const statusPayload = serializePublicStatusEntry(entry, nowIsoString());

  await insertAuditLog(env, {
    eventType: "public_status",
    ip: publicIp,
    entryId: entry?.id || "",
    stage: "public",
    decision: statusPayload.status,
    actorEmail: "",
    requestIp: visitorIp,
    userAgent: request.headers.get("User-Agent") || "",
    payload: {
      status: statusPayload.status,
    },
  });

  return jsonResponse(statusPayload);
}

async function handlePublicRenew(request, env) {
  const body = await parseJsonBody(request);
  if (body.error) {
    return body.error;
  }

  const visitorIp = getVisitorIp(request);
  const limit = await enforcePublicRateLimit(
    env,
    "public_renew",
    visitorIp,
    parseIntSafe(env.PUBLIC_RENEW_LIMIT_MAX, 10),
    parseIntSafe(env.PUBLIC_RENEW_WINDOW_SEC, 900)
  );
  if (!limit.allowed) {
    await insertAuditLog(env, {
      eventType: "public_renew_rate_limited",
      ip: "",
      entryId: "",
      stage: "public",
      decision: "rate_limited",
      actorEmail: "",
      requestIp: visitorIp,
      userAgent: request.headers.get("User-Agent") || "",
      payload: { retry_after_sec: limit.retryAfterSec },
    });
    return jsonResponse(
      {
        error: "rate_limited",
        message: "Terlalu banyak request renew. Coba lagi nanti.",
        retry_after_sec: limit.retryAfterSec,
      },
      429
    );
  }

  const turnstile = await verifyTurnstile(body.data.turnstile_token, request, env);
  if (!turnstile.ok) {
    return jsonResponse({ error: "turnstile_failed", message: turnstile.message }, 400);
  }

  const publicIp = normalizeIpv4(body.data.ip);
  const entryId = normalizeShortText(body.data.entry_id, 64);
  const renewalToken = normalizeShortText(body.data.renewal_token, 255);
  if (!publicIp || !entryId || !renewalToken) {
    return jsonResponse(
      {
        error: "invalid_request",
        message: "ip, entry_id, dan renewal_token wajib diisi.",
      },
      400
    );
  }

  const entry = await getLicenseEntryById(env, entryId);
  if (!entry || entry.ip !== publicIp) {
    return jsonResponse(
      {
        error: "invalid_credentials",
        message: "Kombinasi IP, entry, atau renewal token tidak valid.",
      },
      403
    );
  }
  if (entry.status === "revoked") {
    return jsonResponse(
      {
        error: "revoked",
        message: "Entry ini sudah direvoke admin dan tidak bisa di-renew dari website publik.",
      },
      403
    );
  }

  const expectedHash = entry.renewal_token_hash || "";
  if (!expectedHash) {
    return jsonResponse(
      {
        error: "invalid_credentials",
        message: "Entry ini tidak memiliki renewal token aktif.",
      },
      403
    );
  }

  const actualHash = await hashRenewalToken(renewalToken, env);
  if (actualHash !== expectedHash) {
    return jsonResponse(
      {
        error: "invalid_credentials",
        message: "Kombinasi IP, entry, atau renewal token tidak valid.",
      },
      403
    );
  }

  const nowIso = nowIsoString();
  const durationDays = getLicenseDurationDays(env);
  const newExpiresAt = extendExpiryIso(entry.expires_at || "", nowIso, durationDays);

  await runStatement(
    env,
    `
      UPDATE license_entries
      SET expires_at = ?, updated_at = ?, updated_by = 'public-renew', last_renewed_at = ?
      WHERE id = ?
    `,
    [newExpiresAt, nowIso, nowIso, entryId]
  );

  await insertAuditLog(env, {
    eventType: "public_renew",
    ip: publicIp,
    entryId,
    stage: "public",
    decision: "allow",
    actorEmail: "",
    requestIp: visitorIp,
    userAgent: request.headers.get("User-Agent") || "",
    payload: {
      expires_at: newExpiresAt,
      previous_expires_at: entry.expires_at || "",
    },
  });

  const updated = await getLicenseEntryById(env, entryId);
  return jsonResponse({
    item: serializePublicStatusEntry(updated, nowIso),
    message: `Renew berhasil. Masa aktif ditambah ${durationDays} hari.`,
  });
}

async function handleAdminListEntries(request, env) {
  const url = new URL(request.url);
  const search = normalizeShortText(url.searchParams.get("search"), 255);
  const statusFilter = normalizeStatusFilter(url.searchParams.get("status"));
  const nowIso = nowIsoString();
  const binds = [];

  let sql = `
    SELECT
      id,
      ip,
      label,
      owner,
      notes,
      status,
      expires_at,
      created_at,
      updated_at,
      created_by,
      updated_by,
      revoked_at,
      entry_source,
      last_renewed_at,
      created_request_ip,
      renewal_token_hash
    FROM license_entries
    WHERE 1 = 1
  `;

  if (search) {
    sql += `
      AND (
        lower(ip) LIKE ?
        OR lower(label) LIKE ?
        OR lower(owner) LIKE ?
        OR lower(notes) LIKE ?
        OR lower(entry_source) LIKE ?
      )
    `;
    const like = `%${search.toLowerCase()}%`;
    binds.push(like, like, like, like, like);
  }

  if (statusFilter === "active") {
    sql += ` AND status = 'active' AND (expires_at IS NULL OR expires_at = '' OR expires_at > ?)`;
    binds.push(nowIso);
  } else if (statusFilter === "revoked") {
    sql += ` AND status = 'revoked'`;
  } else if (statusFilter === "expired") {
    sql += ` AND status = 'active' AND expires_at IS NOT NULL AND expires_at != '' AND expires_at <= ?`;
    binds.push(nowIso);
  }

  sql += ` ORDER BY updated_at DESC LIMIT 250`;

  const rows = await allRows(env, sql, binds);
  return jsonResponse({
    items: rows.map((row) => serializeLicenseEntry(row, nowIso)),
  });
}

async function handleAdminCreateEntry(request, env, actorEmail) {
  const body = await parseJsonBody(request);
  if (body.error) {
    return body.error;
  }

  const normalized = normalizeEntryPayload(body.data);
  if (normalized.error) {
    return jsonResponse({ error: "invalid_request", message: normalized.error }, 400);
  }

  const existing = await getLicenseEntryByIp(env, normalized.entry.ip);
  if (existing) {
    return jsonResponse({ error: "conflict", message: "IP sudah terdaftar" }, 409);
  }

  const nowIso = nowIsoString();
  const id = crypto.randomUUID();
  await runStatement(
    env,
    `
      INSERT INTO license_entries (
        id, ip, label, owner, notes, status, expires_at,
        created_at, updated_at, created_by, updated_by, revoked_at,
        entry_source, renewal_token_hash, last_renewed_at, created_request_ip
      )
      VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, NULL, 'admin', '', NULL, ?)
    `,
    [
      id,
      normalized.entry.ip,
      normalized.entry.label,
      normalized.entry.owner,
      normalized.entry.notes,
      normalized.entry.expiresAt,
      nowIso,
      nowIso,
      actorEmail,
      actorEmail,
      getVisitorIp(request),
    ]
  );

  await insertAuditLog(env, {
    eventType: "admin_create",
    ip: normalized.entry.ip,
    entryId: id,
    stage: "admin",
    decision: "mutate",
    actorEmail,
    requestIp: getVisitorIp(request),
    userAgent: request.headers.get("User-Agent") || "",
    payload: normalized.entry,
  });

  const created = await getLicenseEntryById(env, id);
  return jsonResponse({ item: serializeLicenseEntry(created, nowIso) }, 201);
}

async function handleAdminPatchEntry(request, env, actorEmail, entryId) {
  const existing = await getLicenseEntryById(env, entryId);
  if (!existing) {
    return jsonResponse({ error: "not_found", message: "Entry tidak ditemukan" }, 404);
  }

  const body = await parseJsonBody(request);
  if (body.error) {
    return body.error;
  }

  const normalized = normalizeEntryPayload(body.data);
  if (normalized.error) {
    return jsonResponse({ error: "invalid_request", message: normalized.error }, 400);
  }

  const other = await getLicenseEntryByIp(env, normalized.entry.ip);
  if (other && other.id !== entryId) {
    return jsonResponse({ error: "conflict", message: "IP sudah dipakai entry lain" }, 409);
  }

  const nowIso = nowIsoString();
  await runStatement(
    env,
    `
      UPDATE license_entries
      SET ip = ?, label = ?, owner = ?, notes = ?, expires_at = ?, updated_at = ?, updated_by = ?
      WHERE id = ?
    `,
    [
      normalized.entry.ip,
      normalized.entry.label,
      normalized.entry.owner,
      normalized.entry.notes,
      normalized.entry.expiresAt,
      nowIso,
      actorEmail,
      entryId,
    ]
  );

  await insertAuditLog(env, {
    eventType: "admin_update",
    ip: normalized.entry.ip,
    entryId,
    stage: "admin",
    decision: "mutate",
    actorEmail,
    requestIp: getVisitorIp(request),
    userAgent: request.headers.get("User-Agent") || "",
    payload: normalized.entry,
  });

  const updated = await getLicenseEntryById(env, entryId);
  return jsonResponse({ item: serializeLicenseEntry(updated, nowIso) });
}

async function handleAdminToggleEntry(request, env, actorEmail, entryId, targetStatus) {
  const existing = await getLicenseEntryById(env, entryId);
  if (!existing) {
    return jsonResponse({ error: "not_found", message: "Entry tidak ditemukan" }, 404);
  }

  const nowIso = nowIsoString();
  const revokedAt = targetStatus === "revoked" ? nowIso : null;
  await runStatement(
    env,
    `
      UPDATE license_entries
      SET status = ?, revoked_at = ?, updated_at = ?, updated_by = ?
      WHERE id = ?
    `,
    [targetStatus, revokedAt, nowIso, actorEmail, entryId]
  );

  await insertAuditLog(env, {
    eventType: targetStatus === "revoked" ? "admin_revoke" : "admin_reactivate",
    ip: existing.ip,
    entryId,
    stage: "admin",
    decision: "mutate",
    actorEmail,
    requestIp: getVisitorIp(request),
    userAgent: request.headers.get("User-Agent") || "",
    payload: {
      target_status: targetStatus,
    },
  });

  const updated = await getLicenseEntryById(env, entryId);
  return jsonResponse({ item: serializeLicenseEntry(updated, nowIso) });
}

async function handleAdminListAuditLogs(request, env) {
  const url = new URL(request.url);
  const limit = Math.min(250, Math.max(1, parseIntSafe(url.searchParams.get("limit"), 100)));
  const ip = normalizeIpv4(url.searchParams.get("ip") || "");
  const binds = [];
  let sql = `
    SELECT id, event_type, ip, entry_id, stage, decision, actor_email, request_ip, user_agent, payload_json, created_at
    FROM audit_logs
    WHERE 1 = 1
  `;
  if (ip) {
    sql += ` AND ip = ?`;
    binds.push(ip);
  }
  sql += ` ORDER BY created_at DESC LIMIT ?`;
  binds.push(limit);
  const rows = await allRows(env, sql, binds);
  return jsonResponse({
    items: rows.map((row) => ({
      ...row,
      payload_json: parseJsonSafe(row.payload_json, {}),
    })),
  });
}

function buildLicenseDecision(entry, env) {
  const nowIso = nowIsoString();
  const durationDays = getLicenseDurationDays(env);
  if (!entry) {
    return { allowed: false, reason: "ip not registered" };
  }
  if (entry.status === "revoked") {
    return { allowed: false, reason: "license revoked" };
  }
  if (entry.expires_at && entry.expires_at <= nowIso) {
    return { allowed: false, reason: "license expired" };
  }
  return {
    allowed: true,
    reason: `matched active entry${entry.label ? ` (${entry.label})` : ""}`,
    cacheTtlSec: parseIntSafe(env.CACHE_TTL_SEC_DEFAULT, 86400),
    licenseDurationDays: durationDays,
  };
}

function serializeLicenseEntry(row, nowIso = nowIsoString()) {
  const expiresAt = row.expires_at || "";
  const effectiveStatus = effectiveStatusForRow(row, nowIso);
  return {
    id: row.id,
    ip: row.ip,
    label: row.label || "",
    owner: row.owner || "",
    notes: row.notes || "",
    status: row.status || "active",
    effective_status: effectiveStatus,
    is_expired: effectiveStatus === "expired",
    expires_at: expiresAt,
    created_at: row.created_at || "",
    updated_at: row.updated_at || "",
    created_by: row.created_by || "",
    updated_by: row.updated_by || "",
    revoked_at: row.revoked_at || "",
    entry_source: row.entry_source || "admin",
    last_renewed_at: row.last_renewed_at || "",
    created_request_ip: row.created_request_ip || "",
    has_renewal_token: Boolean(row.renewal_token_hash),
  };
}

function serializePublicStatusEntry(row, nowIso = nowIsoString()) {
  if (!row) {
    return {
      status: "not_found",
      allowed: false,
      entry_id: "",
      ip: "",
      expires_at: "",
      days_remaining: 0,
      renewable: false,
    };
  }
  const effectiveStatus = effectiveStatusForRow(row, nowIso);
  return {
    status: effectiveStatus,
    allowed: effectiveStatus === "active",
    entry_id: row.id,
    ip: row.ip,
    expires_at: row.expires_at || "",
    days_remaining: calculateDaysRemaining(row.expires_at || "", nowIso),
    renewable: effectiveStatus !== "revoked" && Boolean(row.renewal_token_hash),
  };
}

function effectiveStatusForRow(row, nowIso) {
  if ((row.status || "active") === "revoked") {
    return "revoked";
  }
  if (row.expires_at && row.expires_at <= nowIso) {
    return "expired";
  }
  return row.status || "active";
}

function calculateDaysRemaining(expiresAt, nowIso) {
  if (!expiresAt) {
    return 0;
  }
  const diffMs = new Date(expiresAt).getTime() - new Date(nowIso).getTime();
  if (!Number.isFinite(diffMs) || diffMs <= 0) {
    return 0;
  }
  return Math.ceil(diffMs / 86400000);
}

function normalizeEntryPayload(raw) {
  const ip = normalizeIpv4(raw?.ip);
  if (!ip) {
    return { error: "IP harus IPv4 literal yang valid" };
  }
  const expiresAt = normalizeOptionalIsoDate(raw?.expires_at);
  if (raw?.expires_at && !expiresAt) {
    return { error: "expires_at harus ISO datetime yang valid atau kosong" };
  }
  return {
    entry: {
      ip,
      label: normalizeShortText(raw?.label, 120),
      owner: normalizeShortText(raw?.owner, 120),
      notes: normalizeLongText(raw?.notes, 2000),
      expiresAt,
    },
  };
}

function normalizeStatusFilter(value) {
  const raw = String(value || "all").trim().toLowerCase();
  if (raw === "active" || raw === "revoked" || raw === "expired") {
    return raw;
  }
  return "all";
}

function normalizeStage(value) {
  const raw = String(value || "").trim().toLowerCase();
  if (["run", "setup", "manage", "runtime"].includes(raw)) {
    return raw;
  }
  return raw || "runtime";
}

function normalizeIpv4(value) {
  const raw = String(value || "").trim();
  if (!IPV4_RE.test(raw)) {
    return "";
  }
  const parts = raw.split(".").map((item) => Number(item));
  if (parts.some((part) => Number.isNaN(part) || part < 0 || part > 255)) {
    return "";
  }
  return parts.join(".");
}

function normalizeShortText(value, maxLength) {
  return String(value || "").trim().slice(0, maxLength);
}

function normalizeLongText(value, maxLength) {
  return String(value || "").trim().slice(0, maxLength);
}

function normalizeOptionalIsoDate(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return null;
  }
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) {
    return null;
  }
  return parsed.toISOString();
}

async function requireAdminAccess(request, env) {
  const token = request.headers.get("Cf-Access-Jwt-Assertion") || "";
  if (!token) {
    return {
      response: jsonResponse({ error: "unauthorized", message: "Cloudflare Access JWT tidak ditemukan" }, 401),
    };
  }
  try {
    const payload = await verifyAccessJwt(token, env);
    return {
      email: String(payload.email || payload.sub || ""),
      payload,
    };
  } catch (error) {
    return {
      response: jsonResponse(
        {
          error: "unauthorized",
          message: error instanceof Error ? error.message : "Access JWT tidak valid",
        },
        401
      ),
    };
  }
}

function requireWorkerBearer(request, env) {
  const expected = String(env.AUTOSCRIPT_SHARED_BEARER_TOKEN || "").trim();
  if (!expected) {
    return jsonResponse({ error: "misconfigured", message: "Secret AUTOSCRIPT_SHARED_BEARER_TOKEN belum di-set" }, 500);
  }
  const authHeader = request.headers.get("Authorization") || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
  if (!token || token !== expected) {
    return jsonResponse({ error: "unauthorized", message: "Bearer token tidak valid" }, 401);
  }
  return null;
}

async function verifyAccessJwt(token, env) {
  const teamDomain = String(env.CF_ACCESS_TEAM_DOMAIN || "").trim();
  const expectedAud = String(env.CF_ACCESS_AUD || "").trim();
  if (!teamDomain || !expectedAud) {
    throw new Error("Worker belum dikonfigurasi untuk validasi Cloudflare Access");
  }

  const parts = token.split(".");
  if (parts.length !== 3) {
    throw new Error("Format JWT Access tidak valid");
  }

  const header = parseJsonSafe(base64UrlDecode(parts[0]), null);
  const payload = parseJsonSafe(base64UrlDecode(parts[1]), null);
  if (!header || !payload) {
    throw new Error("JWT Access tidak dapat di-parse");
  }

  const jwk = await getAccessJwk(teamDomain, header.kid);
  if (!jwk) {
    throw new Error("Kunci JWT Access tidak ditemukan");
  }

  const algorithm = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
  const key = await crypto.subtle.importKey("jwk", jwk, algorithm, false, ["verify"]);
  const encoder = new TextEncoder();
  const data = encoder.encode(`${parts[0]}.${parts[1]}`);
  const signature = base64UrlToUint8Array(parts[2]);
  const verified = await crypto.subtle.verify(algorithm, key, signature, data);
  if (!verified) {
    throw new Error("Signature JWT Access tidak valid");
  }

  const nowEpoch = Math.floor(Date.now() / 1000);
  if (!payload.exp || payload.exp <= nowEpoch) {
    throw new Error("JWT Access sudah expired");
  }

  const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!audiences.includes(expectedAud)) {
    throw new Error("Audience JWT Access tidak cocok");
  }

  const expectedIssuer = `https://${teamDomain}`;
  if (payload.iss && payload.iss !== expectedIssuer) {
    throw new Error("Issuer JWT Access tidak cocok");
  }

  return payload;
}

async function getAccessJwk(teamDomain, kid) {
  const now = Date.now();
  if (!cachedJwks.keys.length || now - cachedJwks.fetchedAt > ACCESS_JWKS_TTL_MS) {
    const response = await fetch(`https://${teamDomain}/cdn-cgi/access/certs`);
    if (!response.ok) {
      throw new Error("Gagal mengambil JWKS Cloudflare Access");
    }
    const body = await response.json();
    cachedJwks = {
      fetchedAt: now,
      keys: Array.isArray(body.keys) ? body.keys : [],
    };
  }
  return cachedJwks.keys.find((item) => item.kid === kid) || null;
}

async function verifyTurnstile(token, request, env) {
  const secret = String(env.TURNSTILE_SECRET_KEY || "").trim();
  if (!secret) {
    return { ok: false, message: "Worker belum dikonfigurasi untuk Turnstile." };
  }
  const responseToken = String(token || "").trim();
  if (!responseToken) {
    return { ok: false, message: "Turnstile token wajib diisi." };
  }
  const form = new URLSearchParams();
  form.set("secret", secret);
  form.set("response", responseToken);
  const remoteIp = getVisitorIp(request);
  if (remoteIp) {
    form.set("remoteip", remoteIp);
  }
  const response = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: form.toString(),
  });
  if (!response.ok) {
    return { ok: false, message: "Verifikasi Turnstile gagal." };
  }
  const payload = await response.json();
  if (!payload.success) {
    return { ok: false, message: "Turnstile challenge tidak valid." };
  }
  return { ok: true };
}

async function enforcePublicRateLimit(env, endpoint, clientIp, maxRequests, windowSec) {
  const slot = Math.floor(Date.now() / 1000 / windowSec);
  const existing = await firstRow(
    env,
    `
      SELECT request_count
      FROM public_rate_limits
      WHERE endpoint = ? AND client_ip = ? AND window_slot = ?
      LIMIT 1
    `,
    [endpoint, clientIp, slot]
  );

  let requestCount = 1;
  if (!existing) {
    await runStatement(
      env,
      `
        INSERT INTO public_rate_limits (endpoint, client_ip, window_slot, request_count, updated_at)
        VALUES (?, ?, ?, 1, ?)
      `,
      [endpoint, clientIp, slot, nowIsoString()]
    );
  } else {
    requestCount = Number(existing.request_count || 0) + 1;
    await runStatement(
      env,
      `
        UPDATE public_rate_limits
        SET request_count = ?, updated_at = ?
        WHERE endpoint = ? AND client_ip = ? AND window_slot = ?
      `,
      [requestCount, nowIsoString(), endpoint, clientIp, slot]
    );
  }

  const nowSec = Math.floor(Date.now() / 1000);
  const retryAfterSec = Math.max(1, slot * windowSec + windowSec - nowSec);
  return {
    allowed: requestCount <= maxRequests,
    requestCount,
    retryAfterSec,
  };
}

async function getLicenseEntryByIp(env, ip) {
  return firstRow(
    env,
    `
      SELECT
        id, ip, label, owner, notes, status, expires_at,
        created_at, updated_at, created_by, updated_by, revoked_at,
        entry_source, renewal_token_hash, last_renewed_at, created_request_ip
      FROM license_entries
      WHERE ip = ?
      LIMIT 1
    `,
    [ip]
  );
}

async function getLicenseEntryById(env, id) {
  return firstRow(
    env,
    `
      SELECT
        id, ip, label, owner, notes, status, expires_at,
        created_at, updated_at, created_by, updated_by, revoked_at,
        entry_source, renewal_token_hash, last_renewed_at, created_request_ip
      FROM license_entries
      WHERE id = ?
      LIMIT 1
    `,
    [id]
  );
}

async function insertAuditLog(env, data) {
  await runStatement(
    env,
    `
      INSERT INTO audit_logs (
        id, event_type, ip, entry_id, stage, decision, actor_email, request_ip, user_agent, payload_json, created_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `,
    [
      crypto.randomUUID(),
      data.eventType,
      data.ip || "",
      data.entryId || null,
      data.stage || "",
      data.decision || "",
      data.actorEmail || "",
      data.requestIp || "",
      data.userAgent || "",
      JSON.stringify(data.payload || {}),
      nowIsoString(),
    ]
  );
}

async function parseJsonBody(request) {
  try {
    const data = await request.json();
    return { data };
  } catch (_error) {
    return {
      error: jsonResponse({ error: "invalid_json", message: "Body JSON tidak valid" }, 400),
    };
  }
}

async function firstRow(env, sql, binds = []) {
  const stmt = env.LICENSE_DB.prepare(sql).bind(...binds);
  return stmt.first();
}

async function allRows(env, sql, binds = []) {
  const stmt = env.LICENSE_DB.prepare(sql).bind(...binds);
  const result = await stmt.all();
  return Array.isArray(result.results) ? result.results : [];
}

async function runStatement(env, sql, binds = []) {
  const stmt = env.LICENSE_DB.prepare(sql).bind(...binds);
  return stmt.run();
}

function buildPublicCorsResponse(request, env) {
  return new Response(null, {
    status: 204,
    headers: buildCorsHeaders(request, env, {
      origin: String(env.PUBLIC_UI_ORIGIN || "").trim(),
      allowHeaders: "Content-Type",
      allowMethods: "GET, POST, OPTIONS",
      allowCredentials: false,
    }),
  });
}

function buildAdminCorsResponse(request, env) {
  return new Response(null, {
    status: 204,
    headers: buildCorsHeaders(request, env, {
      origin: String(env.ADMIN_UI_ORIGIN || "").trim(),
      allowHeaders: "Content-Type, Cf-Access-Jwt-Assertion",
      allowMethods: "GET, POST, PATCH, OPTIONS",
      allowCredentials: true,
    }),
  });
}

function withPublicCors(request, env, response) {
  return withCors(
    request,
    env,
    response,
    {
      origin: String(env.PUBLIC_UI_ORIGIN || "").trim(),
      allowHeaders: "Content-Type",
      allowMethods: "GET, POST, OPTIONS",
      allowCredentials: false,
    }
  );
}

function withAdminCors(request, env, response) {
  return withCors(
    request,
    env,
    response,
    {
      origin: String(env.ADMIN_UI_ORIGIN || "").trim(),
      allowHeaders: "Content-Type, Cf-Access-Jwt-Assertion",
      allowMethods: "GET, POST, PATCH, OPTIONS",
      allowCredentials: true,
    }
  );
}

function withCors(request, env, response, options) {
  const headers = new Headers(response.headers);
  const cors = buildCorsHeaders(request, env, options);
  cors.forEach((value, key) => headers.set(key, value));
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function buildCorsHeaders(request, _env, options) {
  const requestOrigin = request.headers.get("Origin") || "";
  const allowedOrigin = options.origin || requestOrigin || "*";
  const headers = new Headers({
    "Access-Control-Allow-Headers": options.allowHeaders,
    "Access-Control-Allow-Methods": options.allowMethods,
    "Access-Control-Allow-Origin": allowedOrigin,
    "Vary": "Origin",
  });
  if (options.allowCredentials) {
    headers.set("Access-Control-Allow-Credentials", "true");
  }
  return headers;
}

function jsonResponse(payload, status = 200, extraHeaders = {}) {
  const headers = new Headers(extraHeaders);
  headers.set("Content-Type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(payload, null, 2), {
    status,
    headers,
  });
}

function parseIntSafe(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (Number.isFinite(parsed) && parsed > 0) {
    return parsed;
  }
  return fallback;
}

function getLicenseDurationDays(env) {
  return parseIntSafe(env.PUBLIC_LICENSE_DURATION_DAYS, 14);
}

function nowIsoString() {
  return new Date().toISOString();
}

function parseJsonSafe(value, fallback) {
  try {
    return JSON.parse(value);
  } catch (_error) {
    return fallback;
  }
}

function getVisitorIp(request) {
  return String(request.headers.get("CF-Connecting-IP") || "").trim();
}

function addDaysIso(baseIso, days) {
  const parsed = new Date(baseIso);
  parsed.setUTCDate(parsed.getUTCDate() + days);
  return parsed.toISOString();
}

function extendExpiryIso(existingIso, nowIso, days) {
  const base = existingIso && existingIso > nowIso ? existingIso : nowIso;
  return addDaysIso(base, days);
}

function buildRenewalLink(env, entryId, ip) {
  const origin = String(env.PUBLIC_UI_ORIGIN || "").trim();
  if (!origin) {
    return "";
  }
  const url = new URL(origin);
  url.searchParams.set("mode", "renew");
  url.searchParams.set("entry", entryId);
  url.searchParams.set("ip", ip);
  return url.toString();
}

function generateRenewalToken() {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

async function hashRenewalToken(token, env) {
  const pepper = String(env.RENEWAL_TOKEN_PEPPER || "").trim();
  if (!pepper) {
    throw new Error("Secret RENEWAL_TOKEN_PEPPER belum di-set");
  }
  const encoder = new TextEncoder();
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(`${token}:${pepper}`));
  return bytesToHex(new Uint8Array(digest));
}

function base64UrlEncode(bytes) {
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function base64UrlDecode(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const remainder = normalized.length % 4;
  const padded = normalized + (remainder ? "=".repeat(4 - remainder) : "");
  const binary = atob(padded);
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

function base64UrlToUint8Array(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const remainder = normalized.length % 4;
  const padded = normalized + (remainder ? "=".repeat(4 - remainder) : "");
  const binary = atob(padded);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

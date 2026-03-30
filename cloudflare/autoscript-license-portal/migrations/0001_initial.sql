CREATE TABLE IF NOT EXISTS license_entries (
  id TEXT PRIMARY KEY,
  ip TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL DEFAULT '',
  owner TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  expires_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_by TEXT NOT NULL DEFAULT '',
  updated_by TEXT NOT NULL DEFAULT '',
  revoked_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_license_entries_status ON license_entries (status);
CREATE INDEX IF NOT EXISTS idx_license_entries_updated_at ON license_entries (updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_license_entries_expires_at ON license_entries (expires_at);

CREATE TABLE IF NOT EXISTS audit_logs (
  id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  ip TEXT NOT NULL DEFAULT '',
  entry_id TEXT,
  stage TEXT NOT NULL DEFAULT '',
  decision TEXT NOT NULL DEFAULT '',
  actor_email TEXT NOT NULL DEFAULT '',
  request_ip TEXT NOT NULL DEFAULT '',
  user_agent TEXT NOT NULL DEFAULT '',
  payload_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_ip ON audit_logs (ip);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event_type ON audit_logs (event_type);

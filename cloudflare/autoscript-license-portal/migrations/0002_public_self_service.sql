ALTER TABLE license_entries ADD COLUMN entry_source TEXT NOT NULL DEFAULT 'admin';
ALTER TABLE license_entries ADD COLUMN renewal_token_hash TEXT NOT NULL DEFAULT '';
ALTER TABLE license_entries ADD COLUMN last_renewed_at TEXT;
ALTER TABLE license_entries ADD COLUMN created_request_ip TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_license_entries_entry_source ON license_entries (entry_source);
CREATE INDEX IF NOT EXISTS idx_license_entries_last_renewed_at ON license_entries (last_renewed_at DESC);

CREATE TABLE IF NOT EXISTS public_rate_limits (
  endpoint TEXT NOT NULL,
  client_ip TEXT NOT NULL,
  window_slot INTEGER NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (endpoint, client_ip, window_slot)
);

CREATE INDEX IF NOT EXISTS idx_public_rate_limits_updated_at ON public_rate_limits (updated_at DESC);

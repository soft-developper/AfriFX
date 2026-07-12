-- ============================================================
-- Maintenance mode — take the platform, or one section of it, offline
-- from the admin dashboard. No code change, no redeploy.
--
-- Run EACH statement individually (a "table already exists" or "duplicate
-- column" error is harmless — just move to the next):
--
--   turso db shell <db> "CREATE TABLE IF NOT EXISTS maintenance_state (...);"
--
-- (The whole file also works on a first, clean run.)
-- ============================================================

CREATE TABLE IF NOT EXISTS maintenance_state (
  section      TEXT PRIMARY KEY,     -- 'platform' | 'convert' | 'marketplace' | …
  enabled      INTEGER NOT NULL DEFAULT 0,
  message      TEXT,                 -- shown to users; falls back to a default
  eta          TEXT,                 -- optional, e.g. "back by 04:00 UTC"
  enabled_by   TEXT,                 -- admin username
  enabled_at   INTEGER,
  updated_at   INTEGER NOT NULL
);

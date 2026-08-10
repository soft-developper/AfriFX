-- ============================================================
-- Admin authentication and audit tables.
--
-- Like the core tables in 0000, these were created ad hoc and never
-- written down, so a fresh database had no `admins` table and every
-- admin feature failed. Migration 0005 (duty sessions) alters
-- `admins`, so this has to come first.
--
-- Reconstructed from the INSERT statements and row normalizers in:
--   src/lib/adminAuth.ts, src/lib/seedAdmin.ts,
--   src/routes/adminAuth.ts, src/routes/adminManage.ts
--
-- Production already has these, so this is a no-op there.
--
-- Note: `permissions` holds either a JSON array of permission strings
-- or the literal 'all' for the super admin - see parsePermissions().
-- ============================================================

CREATE TABLE IF NOT EXISTS admins (
  id              TEXT PRIMARY KEY,
  username        TEXT NOT NULL UNIQUE,
  email           TEXT NOT NULL UNIQUE,
  password_hash   TEXT NOT NULL,
  wallet_address  TEXT,
  role            TEXT NOT NULL DEFAULT 'sub_admin',
  permissions     TEXT,
  status          TEXT NOT NULL DEFAULT 'active',
  suspended_until INTEGER,
  created_by      TEXT,
  last_login      INTEGER,
  setup_completed INTEGER NOT NULL DEFAULT 0,
  is_active       INTEGER NOT NULL DEFAULT 1,
  login_attempts  INTEGER NOT NULL DEFAULT 0,
  locked_until    INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_sessions (
  id             TEXT PRIMARY KEY,
  admin_id       TEXT NOT NULL,
  token          TEXT NOT NULL UNIQUE,
  ip_address     TEXT,
  user_agent     TEXT,
  created_at     INTEGER NOT NULL,
  expires_at     INTEGER NOT NULL,
  last_active_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_admin_sessions_token
  ON admin_sessions (token);
CREATE INDEX IF NOT EXISTS idx_admin_sessions_admin
  ON admin_sessions (admin_id);

CREATE TABLE IF NOT EXISTS admin_audit_log (
  id          TEXT PRIMARY KEY,
  admin_id    TEXT,
  admin_name  TEXT,
  action      TEXT NOT NULL,
  target_type TEXT,
  target_id   TEXT,
  details     TEXT,
  ip_address  TEXT,
  created_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_admin
  ON admin_audit_log (admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_audit_created
  ON admin_audit_log (created_at);

CREATE TABLE IF NOT EXISTS admin_login_log (
  id         TEXT PRIMARY KEY,
  admin_id   TEXT,
  email      TEXT,
  success    INTEGER NOT NULL DEFAULT 0,
  ip_address TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_password_resets (
  id         TEXT PRIMARY KEY,
  admin_id   TEXT NOT NULL,
  token      TEXT NOT NULL UNIQUE,
  used_at    INTEGER,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_invitations (
  id          TEXT PRIMARY KEY,
  email       TEXT NOT NULL,
  invited_by  TEXT,
  permissions TEXT,
  token       TEXT NOT NULL UNIQUE,
  accepted_at INTEGER,
  expires_at  INTEGER NOT NULL,
  created_at  INTEGER NOT NULL
);

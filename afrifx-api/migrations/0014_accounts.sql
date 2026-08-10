-- ============================================================
-- Phase 1: accounts and sessions.
--
-- Replaces "connect a wallet" onboarding with a real account.
-- Circle is the identity provider: the user authenticates with
-- Google or an email OTP, Circle returns a 60-minute userToken, we
-- verify it server-side and issue our own longer-lived session.
--
-- We therefore store NO passwords and NO OTP state. There is also no
-- separate "confirm your email" token: Circle's OTP already proves
-- the address, and Google proves it for social login.
--
-- WHY A NEW TABLE, NOT A REWRITE OF `users`:
-- The whole app currently keys off wallet_address (users, profiles,
-- offers, invoices, payroll, ...). `accounts.wallet_address` starts
-- NULL and is filled in Phase 2 when the Circle wallet is created,
-- so every existing feature keeps working unchanged and can be
-- migrated to account_id one at a time later.
-- ============================================================

CREATE TABLE IF NOT EXISTS accounts (
  id              TEXT PRIMARY KEY,

  -- Stored lowercase. UNIQUE is case-sensitive in SQLite, so the
  -- application must lowercase before writing or comparing; doing it
  -- at the column level would need a generated column or trigger.
  email           TEXT NOT NULL UNIQUE,
  username        TEXT NOT NULL UNIQUE,

  first_name      TEXT NOT NULL,
  last_name       TEXT NOT NULL,

  -- Circle's stable user id, from GET /v1/w3s/user. This is the link
  -- between our account and the user's Circle wallet identity.
  circle_user_id  TEXT UNIQUE,

  -- Filled in Phase 2 once the user-controlled wallet exists. NULL
  -- until then, which is why every wallet-keyed feature must tolerate
  -- an account with no wallet yet.
  wallet_address  TEXT UNIQUE,

  -- pending  : row created, wallet not yet provisioned
  -- active   : usable account
  -- suspended: blocked by an admin
  status          TEXT NOT NULL DEFAULT 'pending',

  -- Optional social handles, purely profile enrichment.
  twitter_handle  TEXT,

  last_login_at   INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_accounts_email       ON accounts (email);
CREATE INDEX IF NOT EXISTS idx_accounts_username    ON accounts (username);
CREATE INDEX IF NOT EXISTS idx_accounts_circle_user ON accounts (circle_user_id);
CREATE INDEX IF NOT EXISTS idx_accounts_wallet      ON accounts (wallet_address);

-- Our own sessions, independent of Circle's 60-minute userToken.
-- Only a SHA-256 hash of the token is stored, so a database leak does
-- not hand over live sessions.
CREATE TABLE IF NOT EXISTS account_sessions (
  id             TEXT PRIMARY KEY,
  account_id     TEXT NOT NULL,
  token_hash     TEXT NOT NULL UNIQUE,
  ip_address     TEXT,
  user_agent     TEXT,
  created_at     INTEGER NOT NULL,
  expires_at     INTEGER NOT NULL,
  last_active_at INTEGER,
  revoked_at     INTEGER
);

CREATE INDEX IF NOT EXISTS idx_account_sessions_hash
  ON account_sessions (token_hash);
CREATE INDEX IF NOT EXISTS idx_account_sessions_account
  ON account_sessions (account_id);

-- Usernames we never hand out: routes, impersonation risks, support.
CREATE TABLE IF NOT EXISTS reserved_usernames (
  username TEXT PRIMARY KEY
);

INSERT OR IGNORE INTO reserved_usernames (username) VALUES
  ('admin'), ('administrator'), ('support'), ('help'), ('security'),
  ('root'), ('system'), ('official'), ('staff'), ('team'),
  ('afrifx'), ('nexum'), ('circle'), ('arc'), ('usdc'),
  ('api'), ('www'), ('mail'), ('billing'), ('payments'),
  ('login'), ('signup'), ('settings'), ('account'), ('wallet'),
  ('me'), ('null'), ('undefined'), ('anonymous'), ('moderator');

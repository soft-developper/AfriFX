-- ============================================================
-- Sign-in first, details later.
--
-- The original accounts table required username, first_name, last_name
-- and email up front, because sign-up collected them before creating
-- anything. The flow is now: sign in with Google or an email code, get
-- a wallet, THEN fill in your profile. So those columns must be
-- optional at insert time.
--
-- SQLite cannot drop a NOT NULL constraint in place, so the table is
-- rebuilt. Existing rows are preserved.
--
-- email stays present but nullable: we know it for email sign-in, and
-- for Google we only know it if the OAuth response includes it.
-- ============================================================

CREATE TABLE IF NOT EXISTS accounts_new (
  id              TEXT PRIMARY KEY,
  email           TEXT UNIQUE,
  username        TEXT UNIQUE,
  first_name      TEXT,
  last_name       TEXT,
  circle_user_id  TEXT UNIQUE,
  wallet_address  TEXT UNIQUE,
  status          TEXT NOT NULL DEFAULT 'pending',
  twitter_handle  TEXT,
  last_login_at   INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

INSERT OR IGNORE INTO accounts_new
  (id, email, username, first_name, last_name, circle_user_id,
   wallet_address, status, twitter_handle, last_login_at,
   created_at, updated_at)
SELECT
   id, email, username, first_name, last_name, circle_user_id,
   wallet_address, status, twitter_handle, last_login_at,
   created_at, updated_at
FROM accounts;

DROP TABLE accounts;

ALTER TABLE accounts_new RENAME TO accounts;

CREATE INDEX IF NOT EXISTS idx_accounts_email       ON accounts (email);
CREATE INDEX IF NOT EXISTS idx_accounts_username    ON accounts (username);
CREATE INDEX IF NOT EXISTS idx_accounts_circle_user ON accounts (circle_user_id);
CREATE INDEX IF NOT EXISTS idx_accounts_wallet      ON accounts (wallet_address);

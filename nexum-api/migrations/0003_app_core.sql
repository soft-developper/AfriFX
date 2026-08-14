-- ============================================================
-- Remaining application tables.
--
-- The last group of tables created ad hoc and never written down.
-- Later migrations depend on these existing: 0009 (broadcasts) adds
-- columns to `profiles`, so this must run before it.
--
-- Reconstructed from the INSERT statements in:
--   src/routes/profile.ts, src/routes/messages.ts, src/routes/invoices.ts,
--   src/routes/payments.ts, src/routes/treasury.ts, src/routes/disputes.ts,
--   src/services/notify.ts
--
-- Production already has these, so this is a no-op there.
-- ============================================================

-- User profiles (username, socials, notification prefs).
CREATE TABLE IF NOT EXISTS profiles (
  wallet_address   TEXT PRIMARY KEY,
  username         TEXT UNIQUE,
  display_name     TEXT,
  bio              TEXT,
  email            TEXT,
  twitter_handle   TEXT,
  telegram_handle  TEXT,
  avatar_color     TEXT,
  show_socials     INTEGER NOT NULL DEFAULT 1,
  suspended        INTEGER NOT NULL DEFAULT 0,
  last_active_at   INTEGER,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_profiles_username
  ON profiles (username);

-- P2P trade chat.
CREATE TABLE IF NOT EXISTS messages (
  id           TEXT PRIMARY KEY,
  offer_id     TEXT NOT NULL,
  sender       TEXT NOT NULL,
  content      TEXT,
  media_url    TEXT,
  media_type   TEXT,
  msg_type     TEXT NOT NULL DEFAULT 'text',
  quick_action TEXT,
  read_at      INTEGER,
  created_at   INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_messages_offer
  ON messages (offer_id);

-- Dispute handling: which admin took it, and the dispute thread.
CREATE TABLE IF NOT EXISTS dispute_assignments (
  id          TEXT PRIMARY KEY,
  dispute_id  TEXT NOT NULL,
  admin_id    TEXT NOT NULL,
  admin_name  TEXT,
  accepted_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dispute_assignments_dispute
  ON dispute_assignments (dispute_id);

CREATE TABLE IF NOT EXISTS dispute_messages (
  id          TEXT PRIMARY KEY,
  dispute_id  TEXT NOT NULL,
  sender_id   TEXT,
  sender_type TEXT,
  sender_name TEXT,
  content     TEXT,
  media_url   TEXT,
  media_type  TEXT,
  admin_only  INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_dispute_messages_dispute
  ON dispute_messages (dispute_id);

-- Outbound email/notification queue.
CREATE TABLE IF NOT EXISTS notifications (
  id              TEXT PRIMARY KEY,
  user_wallet     TEXT,
  recipient_email TEXT,
  type            TEXT NOT NULL,
  subject         TEXT,
  payload         TEXT,
  status          TEXT NOT NULL DEFAULT 'pending',
  attempts        INTEGER NOT NULL DEFAULT 0,
  sent_at         INTEGER,
  created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_notifications_status
  ON notifications (status);

-- Throttle for transactional email, keyed by "type:recipient".
CREATE TABLE IF NOT EXISTS email_rate_limits (
  key       TEXT PRIMARY KEY,
  last_sent INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS invoices (
  id               TEXT PRIMARY KEY,
  creator_address  TEXT NOT NULL,
  payer_address    TEXT,
  amount           REAL NOT NULL,
  currency         TEXT NOT NULL DEFAULT 'USDC',
  description      TEXT,
  notes            TEXT,
  due_date         INTEGER,
  memo_ref         TEXT,
  status           TEXT NOT NULL DEFAULT 'pending',
  reminder_sent_at INTEGER,
  paid_at          INTEGER,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_invoices_creator
  ON invoices (creator_address);
CREATE INDEX IF NOT EXISTS idx_invoices_payer
  ON invoices (payer_address);

CREATE TABLE IF NOT EXISTS payments (
  id                TEXT PRIMARY KEY,
  sender_address    TEXT NOT NULL,
  recipient_address TEXT NOT NULL,
  amount            REAL NOT NULL,
  currency          TEXT NOT NULL DEFAULT 'USDC',
  local_currency    TEXT,
  local_amount      REAL,
  description       TEXT,
  invoice_ref       TEXT,
  invoice_id        TEXT,
  memo_ref          TEXT,
  status            TEXT NOT NULL DEFAULT 'pending',
  arc_tx_hash       TEXT,
  created_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_payments_sender
  ON payments (sender_address);
CREATE INDEX IF NOT EXISTS idx_payments_recipient
  ON payments (recipient_address);

-- Treasury automation rules (parked until the mainnet contract lands).
CREATE TABLE IF NOT EXISTS treasury_rules (
  id                TEXT PRIMARY KEY,
  wallet_address    TEXT NOT NULL,
  name              TEXT NOT NULL,
  trigger_threshold REAL,
  action_percent    REAL,
  action_amount     REAL,
  target_currency   TEXT,
  enabled           INTEGER NOT NULL DEFAULT 1,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_treasury_rules_wallet
  ON treasury_rules (wallet_address);

-- ============================================================
-- Payroll batches and recipients.
--
-- These tables were created directly in the Turso shell during an
-- earlier session and never captured in a schema file, so a fresh
-- database had no way to create them. Reconstructed here from the
-- columns the payroll route reads and writes.
--
-- The production database already has these tables. Running this
-- there is a no-op (IF NOT EXISTS), and the dest_chain ALTER is
-- tolerated by the runner if the column is already present.
-- ============================================================

CREATE TABLE IF NOT EXISTS payroll_batches (
  id              TEXT PRIMARY KEY,
  wallet_address  TEXT NOT NULL,
  name            TEXT NOT NULL,
  description     TEXT,
  total_amount    REAL NOT NULL DEFAULT 0,
  currency        TEXT NOT NULL DEFAULT 'USDC',
  recipient_count INTEGER NOT NULL DEFAULT 0,
  status          TEXT NOT NULL DEFAULT 'draft',
  executed_at     INTEGER,
  created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_payroll_batches_wallet
  ON payroll_batches (wallet_address);

CREATE TABLE IF NOT EXISTS payroll_recipients (
  id             TEXT PRIMARY KEY,
  batch_id       TEXT NOT NULL,
  name           TEXT,
  wallet_address TEXT NOT NULL,
  amount         REAL NOT NULL,
  currency       TEXT NOT NULL DEFAULT 'USDC',
  memo_ref       TEXT,
  status         TEXT NOT NULL DEFAULT 'pending',
  tx_hash        TEXT,
  created_at     INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_payroll_recipients_batch
  ON payroll_recipients (batch_id);

-- Multichain payouts: which Gateway chain this batch settles on.
-- 'arc' keeps the original behaviour (direct transfer + Memo).
ALTER TABLE payroll_batches ADD COLUMN dest_chain TEXT NOT NULL DEFAULT 'arc';

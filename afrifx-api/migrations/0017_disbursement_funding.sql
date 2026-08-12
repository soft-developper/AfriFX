-- ============================================================
-- Payroll disbursement funding ledger (hybrid custody, Phase 7b).
--
-- The platform holds a reusable USDC "float" in an MPC disbursement wallet;
-- employers top it up, and the backend pays batches out of it. This table is
-- the AUDIT TRAIL of top-ups: who funded, how much, which on-chain tx, and
-- whether it confirmed.
--
-- It is NOT the source of truth for spendable balance - that is always read
-- live from Circle before a payout (so the ledger drifting can never cause an
-- overspend). This table answers "who put money in and when", for
-- reconciliation and display.
-- ============================================================

CREATE TABLE IF NOT EXISTS payroll_disbursement_funding (
  id             TEXT PRIMARY KEY,
  funder_address TEXT NOT NULL,          -- the employer wallet that funded
  amount         REAL NOT NULL,          -- USDC amount of this top-up
  tx_hash        TEXT,                   -- the funding transfer's on-chain hash
  status         TEXT NOT NULL DEFAULT 'pending',  -- pending | confirmed | failed
  created_at     INTEGER NOT NULL,
  confirmed_at   INTEGER
);

CREATE INDEX IF NOT EXISTS idx_disbursement_funding_funder
  ON payroll_disbursement_funding (funder_address);

CREATE INDEX IF NOT EXISTS idx_disbursement_funding_status
  ON payroll_disbursement_funding (status);

-- ============================================================
-- 0018_ramp_customers.sql
-- Bridge.xyz fiat on/off-ramp: maps a Nexum account to its Bridge customer +
-- KYC-link record. One row per account (lazy-created the first time the user
-- opens /ramp). KYC itself is Bridge-hosted (Persona) via the kyc_link — we
-- store only the link ids and statuses, never any PII / ID documents.
-- ============================================================

CREATE TABLE IF NOT EXISTS ramp_customers (
  id             TEXT PRIMARY KEY,
  account_id     TEXT NOT NULL UNIQUE,          -- Nexum accounts.id
  provider       TEXT NOT NULL DEFAULT 'bridgexyz',
  customer_type  TEXT NOT NULL DEFAULT 'individual',  -- 'individual' | 'business'

  -- Bridge identifiers (customer_id is null until the kyc_link yields one).
  kyc_link_id    TEXT,
  customer_id    TEXT,

  -- Hosted links the user completes (Persona KYC + Bridge ToS).
  kyc_link       TEXT,
  tos_link       TEXT,

  -- Mirrored Bridge statuses.
  kyc_status     TEXT NOT NULL DEFAULT 'not_started',
  tos_status     TEXT NOT NULL DEFAULT 'pending',
  rejection_reasons TEXT,                        -- JSON array, when rejected

  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ramp_customers_account ON ramp_customers (account_id);
CREATE INDEX IF NOT EXISTS idx_ramp_customers_kyc_link ON ramp_customers (kyc_link_id);

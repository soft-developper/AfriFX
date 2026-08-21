-- ============================================================
-- 0024_ramp_offramp.sql
-- Bridge.xyz off-ramp, Phase 5.
--
-- Two tables, mirroring the on-ramp pair (external account is the off-ramp
-- analogue of the deposit rail; liquidation address is the permanent on-chain
-- endpoint the user sends USDC to):
--
--   ramp_external_accounts     — one registered bank account per (account,
--                                currency). We store ONLY Bridge's opaque
--                                external_account id plus display-safe
--                                bank_name + last_4. NO routing/account/IBAN
--                                numbers ever touch our DB — they are sent to
--                                Bridge to register the account and then live
--                                at Bridge, not with us.
--
--   ramp_liquidation_addresses — one Bridge liquidation address per (account,
--                                currency). Stores Bridge's id, the on-chain
--                                `address` the user sends USDC to, the linked
--                                external_account id, and the destination rail/
--                                currency for display. Lazily created the first
--                                time the user sets up off-ramp for a currency
--                                (mirrors the lazy virtual-account create).
--
-- Also adds the six OFFRAMP corridor rows to ramp_corridors (direction =
-- 'offramp'). The table already has a UNIQUE(direction,currency), so on-ramp
-- and off-ramp rows for the same currency coexist. Only usd/eur/mxn are enabled
-- at launch (the rails with a defined external-account shape); gbp/brl/cop are
-- seeded disabled and turned on when their external-account forms are added.
-- ============================================================

CREATE TABLE IF NOT EXISTS ramp_external_accounts (
  id                    TEXT PRIMARY KEY,
  account_id            TEXT NOT NULL,             -- Nexum accounts.id
  provider              TEXT NOT NULL DEFAULT 'bridgexyz',
  currency              TEXT NOT NULL,             -- destination fiat, lower-case ('usd')

  bridge_customer_id    TEXT NOT NULL,             -- Bridge customer this account belongs to
  external_account_id   TEXT NOT NULL,             -- Bridge external_account id (opaque)

  -- Display-safe only. NEVER the full account/routing/IBAN numbers.
  bank_name             TEXT,
  last_4                TEXT,
  account_type          TEXT,                      -- 'us' | 'iban' | 'clabe'

  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,

  -- One external account per account+currency; the lazy-create path relies on this.
  UNIQUE (account_id, currency)
);

CREATE INDEX IF NOT EXISTS idx_ramp_ext_acct_account
  ON ramp_external_accounts (account_id);
CREATE INDEX IF NOT EXISTS idx_ramp_ext_acct_bridge_id
  ON ramp_external_accounts (external_account_id);

CREATE TABLE IF NOT EXISTS ramp_liquidation_addresses (
  id                      TEXT PRIMARY KEY,
  account_id              TEXT NOT NULL,           -- Nexum accounts.id
  provider                TEXT NOT NULL DEFAULT 'bridgexyz',
  currency                TEXT NOT NULL,           -- destination fiat, lower-case

  bridge_customer_id      TEXT NOT NULL,           -- Bridge customer
  liquidation_address_id  TEXT NOT NULL,           -- Bridge liquidation address id
  external_account_id     TEXT NOT NULL,           -- linked ramp_external_accounts' Bridge id

  -- The on-chain address the user sends USDC to (on the source chain).
  address                 TEXT NOT NULL,
  source_chain            TEXT NOT NULL DEFAULT 'base',
  source_currency         TEXT NOT NULL DEFAULT 'usdc',

  -- Destination side (for display + the drain tracker).
  destination_payment_rail TEXT NOT NULL,          -- 'ach' | 'wire' | 'sepa' | 'spei'
  destination_currency    TEXT NOT NULL,           -- 'usd' | 'eur' | 'mxn'

  status                  TEXT NOT NULL DEFAULT 'active',

  created_at              INTEGER NOT NULL,
  updated_at              INTEGER NOT NULL,

  -- One liquidation address per account+currency; lazy-create relies on this.
  UNIQUE (account_id, currency)
);

CREATE INDEX IF NOT EXISTS idx_ramp_liq_addr_account
  ON ramp_liquidation_addresses (account_id);
CREATE INDEX IF NOT EXISTS idx_ramp_liq_addr_bridge_id
  ON ramp_liquidation_addresses (liquidation_address_id);
-- Lookup by on-chain address for webhook drain routing (Phase 5 part 4).
CREATE INDEX IF NOT EXISTS idx_ramp_liq_addr_address
  ON ramp_liquidation_addresses (address);

-- Off-ramp corridors. usd/eur/mxn enabled (rails with a defined external-account
-- shape); gbp/brl/cop seeded disabled until their forms ship. Re-run-safe.
INSERT INTO ramp_corridors
  (id, direction, currency, label, min_amount, enabled, sort_order, created_at, updated_at)
VALUES
  ('cor_offramp_usd', 'offramp', 'usd', 'US Dollar (ACH)',       1,   1, 10, strftime('%s','now'), strftime('%s','now')),
  ('cor_offramp_eur', 'offramp', 'eur', 'Euro (SEPA)',           1,   1, 20, strftime('%s','now'), strftime('%s','now')),
  ('cor_offramp_mxn', 'offramp', 'mxn', 'Mexican Peso (SPEI)',   1,   1, 40, strftime('%s','now'), strftime('%s','now')),
  ('cor_offramp_gbp', 'offramp', 'gbp', 'British Pound (FPS)',   1,   0, 30, strftime('%s','now'), strftime('%s','now')),
  ('cor_offramp_brl', 'offramp', 'brl', 'Brazilian Real (Pix)',  1,   0, 50, strftime('%s','now'), strftime('%s','now')),
  ('cor_offramp_cop', 'offramp', 'cop', 'Colombian Peso (Bre-B)',1,   0, 60, strftime('%s','now'), strftime('%s','now'))
ON CONFLICT (direction, currency) DO NOTHING;

-- ============================================================
-- 0019_ramp_corridors_and_virtual_accounts.sql
-- Bridge.xyz on-ramp, Phase 2.
--
-- Two tables:
--   ramp_corridors        — the supported on-ramp currencies, promoted out of
--                           the static BRIDGE_CORRIDORS array so ops can enable
--                           / disable / add a currency with a row change, no
--                           deploy. One row PER CURRENCY (not per fiat rail):
--                           Bridge's `source` object takes only { currency };
--                           the depositor chooses ACH vs wire at their bank and
--                           Bridge returns the supported rails in the virtual
--                           account's source_deposit_instructions.payment_rails.
--   ramp_virtual_accounts — one Bridge virtual account per (account, currency),
--                           lazily created the first time the user selects that
--                           currency (mirrors the lazy ramp_customers row). We
--                           store Bridge's id + the whole source_deposit_
--                           instructions JSON blob (its shape varies by
--                           currency) so the UI can render deposit details
--                           without another API round-trip. No PII beyond the
--                           user's own deposit instructions.
-- ============================================================

CREATE TABLE IF NOT EXISTS ramp_corridors (
  id            TEXT PRIMARY KEY,
  direction     TEXT NOT NULL DEFAULT 'onramp',   -- 'onramp' | 'offramp'
  currency      TEXT NOT NULL,                     -- ISO-4217, lower-case ('usd')
  label         TEXT NOT NULL,                     -- human label for the picker
  min_amount    REAL,                              -- fiat minimum when Bridge enforces one
  enabled       INTEGER NOT NULL DEFAULT 1,        -- 1 = shown in the picker
  sort_order    INTEGER NOT NULL DEFAULT 0,        -- display order in the picker
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  UNIQUE (direction, currency)
);

CREATE INDEX IF NOT EXISTS idx_ramp_corridors_enabled
  ON ramp_corridors (direction, enabled);

-- Seed the six on-ramp currencies Bridge supports today (Aug 2026). All enabled
-- at launch. ON CONFLICT DO NOTHING keeps this safe to re-run and preserves any
-- later ops edits to enabled / sort_order. NO African fiat yet — add NGN later
-- with a single INSERT, no code change.
INSERT INTO ramp_corridors
  (id, direction, currency, label, min_amount, enabled, sort_order, created_at, updated_at)
VALUES
  ('cor_onramp_usd', 'onramp', 'usd', 'US Dollar (ACH / Wire)', 1,   1, 10, strftime('%s','now'), strftime('%s','now')),
  ('cor_onramp_eur', 'onramp', 'eur', 'Euro (SEPA)',            1,   1, 20, strftime('%s','now'), strftime('%s','now')),
  ('cor_onramp_gbp', 'onramp', 'gbp', 'British Pound (FPS)',    1,   1, 30, strftime('%s','now'), strftime('%s','now')),
  ('cor_onramp_mxn', 'onramp', 'mxn', 'Mexican Peso (SPEI)',    50,  1, 40, strftime('%s','now'), strftime('%s','now')),
  ('cor_onramp_brl', 'onramp', 'brl', 'Brazilian Real (Pix)',   NULL,1, 50, strftime('%s','now'), strftime('%s','now')),
  ('cor_onramp_cop', 'onramp', 'cop', 'Colombian Peso (Bre-B)', 100, 1, 60, strftime('%s','now'), strftime('%s','now'))
ON CONFLICT (direction, currency) DO NOTHING;

CREATE TABLE IF NOT EXISTS ramp_virtual_accounts (
  id                    TEXT PRIMARY KEY,
  account_id            TEXT NOT NULL,             -- Nexum accounts.id
  provider              TEXT NOT NULL DEFAULT 'bridgexyz',
  currency              TEXT NOT NULL,             -- source fiat currency, lower-case

  -- Bridge identifiers.
  bridge_customer_id    TEXT NOT NULL,             -- Bridge customer this VA belongs to
  virtual_account_id    TEXT NOT NULL,             -- Bridge virtual account id

  -- Where the on-ramped USDC is delivered (the user's Circle wallet on Base).
  destination_address   TEXT NOT NULL,
  destination_chain     TEXT NOT NULL DEFAULT 'base',

  -- Bridge's source_deposit_instructions verbatim (shape varies by currency).
  deposit_instructions  TEXT,                      -- JSON

  status                TEXT NOT NULL DEFAULT 'activated',

  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,

  -- One virtual account per account+currency; the lazy-create path relies on this.
  UNIQUE (account_id, currency)
);

CREATE INDEX IF NOT EXISTS idx_ramp_va_account
  ON ramp_virtual_accounts (account_id);
CREATE INDEX IF NOT EXISTS idx_ramp_va_bridge_id
  ON ramp_virtual_accounts (virtual_account_id);

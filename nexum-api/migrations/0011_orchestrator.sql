-- ============================================================
-- Payout orchestrator schema cross-border transfers
--
-- Two tables:
--   transfers      one row per end-to-end transfer (user-facing summary)
--   transfer_legs  one row per leg (the audit trail the orchestrator walks)
--
-- Provider-agnostic: no HoneyCoin/Yellow Card specifics live here.
-- Safe to run more than once (IF NOT EXISTS).
-- Run:  turso db shell <your-db-name> < afrifx-api/orchestrator-schema.sql
-- ============================================================

CREATE TABLE IF NOT EXISTS transfers (
  id                TEXT PRIMARY KEY,           -- 'tr-<uuid>'
  sender_address    TEXT NOT NULL,              -- AfriFX wallet initiating
  sender_mode       TEXT NOT NULL,              -- 'fiat_in' | 'usdc_in'

  -- What the sender is sending
  source_currency   TEXT NOT NULL,              -- 'NGN' (fiat_in) or 'USDC' (usdc_in)
  source_amount     REAL NOT NULL,

  -- What the recipient receives
  dest_currency     TEXT NOT NULL,              -- 'KES'
  dest_amount       REAL,                        -- quoted; may firm up after quote
  usdc_amount       REAL,                        -- settlement amount in USDC (the middle)

  -- Recipient payout details (who gets the money)
  recipient_name    TEXT NOT NULL,
  recipient_method  TEXT NOT NULL,              -- 'bank' | 'mobile_money'
  recipient_account TEXT NOT NULL,              -- account no. OR phone
  recipient_bank    TEXT NOT NULL,              -- bank name/code OR provider
  recipient_country TEXT NOT NULL,              -- ISO-2 'KE'
  recipient_note    TEXT,

  -- Routing
  provider          TEXT NOT NULL,              -- 'honeycoin' | 'yellowcard' | 'mock'
  payout_chain      TEXT,                        -- chain provider wants USDC on, e.g. 'base'
  needs_bridge      INTEGER DEFAULT 0,          -- 1 if source USDC is on Arc and must be bridged

  -- FX quote lock
  quote_id          TEXT,
  quote_rate        REAL,
  quote_expires_at  INTEGER,

  -- Lifecycle
  status            TEXT NOT NULL DEFAULT 'created',
                    -- created | in_progress | completed | failed | refunding | refunded
  current_leg       TEXT,
  failure_reason    TEXT,

  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS transfer_legs (
  id              TEXT PRIMARY KEY,             -- 'lg-<uuid>'
  transfer_id     TEXT NOT NULL,               -- -> transfers.id
  leg_type        TEXT NOT NULL,               -- 'onramp'|'collect'|'bridge'|'offramp'|'payout'|'reconcile'
  leg_index       INTEGER NOT NULL,            -- ordering (0,1,2,...)

  status          TEXT NOT NULL DEFAULT 'pending',
                  -- pending | in_flight | done | failed | skipped
  idempotency_key TEXT NOT NULL,               -- prevents double-submits (== provider externalReference)

  -- Evidence, whichever apply to the leg
  provider_ref    TEXT,                         -- provider transaction id
  tx_hash         TEXT,                         -- on-chain hash (collect/bridge)
  attestation     TEXT,                         -- CCTP attestation (bridge)
  amount          REAL,
  currency        TEXT,

  error           TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

-- Helpful indexes for the tick loop and lookups
CREATE INDEX IF NOT EXISTS idx_transfers_status      ON transfers (status);
CREATE INDEX IF NOT EXISTS idx_transfers_sender      ON transfers (sender_address);
CREATE INDEX IF NOT EXISTS idx_legs_transfer         ON transfer_legs (transfer_id);
CREATE INDEX IF NOT EXISTS idx_legs_status           ON transfer_legs (status);
CREATE INDEX IF NOT EXISTS idx_legs_idem             ON transfer_legs (idempotency_key);

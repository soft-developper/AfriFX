-- ============================================================
-- 0020_ramp_webhook_events.sql
-- Bridge.xyz on-ramp, Phase 3 — webhooks + reconciliation.
--
-- Two purposes:
--   ramp_webhook_events   — an append-only, DEDUPED audit log of every verified
--                           Bridge webhook we accept (keyed on Bridge's
--                           event_id so a redelivery is a no-op). This is the
--                           idempotency guard: INSERT OR IGNORE on event_id.
--   ramp_deposit_events   — a small MIRROR of virtual-account activity, so the
--                           /ramp status tracker can read the latest state
--                           instantly instead of waiting for its 15s poll of
--                           Bridge's /history. The poll REMAINS ground truth
--                           and reconciles anything a webhook missed; this
--                           table is an optimisation, never the sole source.
--
-- No PII: deposit amounts + Bridge ids only, same data the tracker already
-- fetches from /history.
-- ============================================================

CREATE TABLE IF NOT EXISTS ramp_webhook_events (
  event_id         TEXT PRIMARY KEY,          -- Bridge event_id (dedupe key)
  provider         TEXT NOT NULL DEFAULT 'bridgexyz',
  event_category   TEXT,
  event_type       TEXT,
  event_created_at TEXT,                       -- Bridge's ISO timestamp
  received_at      INTEGER NOT NULL,           -- our receipt time (unix seconds)
  raw              TEXT                         -- the raw JSON body, for audit/replay
);

CREATE INDEX IF NOT EXISTS idx_ramp_webhook_events_received
  ON ramp_webhook_events (received_at);

CREATE TABLE IF NOT EXISTS ramp_deposit_events (
  id                 TEXT PRIMARY KEY,         -- our uuid
  provider           TEXT NOT NULL DEFAULT 'bridgexyz',
  virtual_account_id TEXT,                     -- Bridge virtual account id
  deposit_id         TEXT,                     -- Bridge deposit_id (groups a deposit's events)
  event_id           TEXT,                     -- source webhook event_id (nullable if from poll)
  event_type         TEXT,                     -- funds_received | payment_submitted | payment_processed | …
  currency           TEXT,
  amount             TEXT,
  destination_tx_hash TEXT,
  receipt_url        TEXT,
  source             TEXT NOT NULL DEFAULT 'webhook',  -- 'webhook' | 'poll'
  created_at         INTEGER NOT NULL,
  -- One row per (virtual account, deposit, event type): a webhook and a later
  -- poll of the same event collapse instead of duplicating.
  UNIQUE (virtual_account_id, deposit_id, event_type)
);

CREATE INDEX IF NOT EXISTS idx_ramp_deposit_events_va
  ON ramp_deposit_events (virtual_account_id);
CREATE INDEX IF NOT EXISTS idx_ramp_deposit_events_deposit
  ON ramp_deposit_events (deposit_id);

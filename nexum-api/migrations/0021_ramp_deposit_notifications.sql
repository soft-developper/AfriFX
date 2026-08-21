-- ============================================================
-- 0021_ramp_deposit_notifications.sql
-- Bridge.xyz on-ramp, Phase 4 #3 — deposit email notifications.
--
-- Dedup guard so each (deposit, kind) emails at most once, even if Bridge
-- redelivers the webhook or the same terminal event arrives via more than one
-- path. kind ∈ ('landed','returned','returned_failed').
-- ============================================================

CREATE TABLE IF NOT EXISTS ramp_deposit_notifications (
  id                 TEXT PRIMARY KEY,       -- our uuid
  virtual_account_id TEXT,
  deposit_id         TEXT,
  kind               TEXT NOT NULL,          -- landed | returned | returned_failed
  sent_at            INTEGER NOT NULL,
  UNIQUE (virtual_account_id, deposit_id, kind)
);

CREATE INDEX IF NOT EXISTS idx_ramp_deposit_notifications_deposit
  ON ramp_deposit_notifications (deposit_id);

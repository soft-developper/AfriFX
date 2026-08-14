-- ============================================================
-- Core tables.
--
-- These five tables were created by `drizzle-kit push` from
-- src/db/schema.ts and were never written down as SQL, so a fresh
-- database could not be built from this repository at all. Every
-- later migration assumes they exist (0003 alters p2p_offers, the
-- disputes flow reads `disputes`, and so on).
--
-- Transcribed from src/db/schema.ts. Production already has these,
-- so running this there is a no-op.
-- ============================================================

CREATE TABLE IF NOT EXISTS transactions (
  id            TEXT PRIMARY KEY,
  wallet_address TEXT NOT NULL,
  from_currency TEXT NOT NULL,
  to_currency   TEXT NOT NULL,
  from_amount   REAL NOT NULL,
  to_amount     REAL NOT NULL,
  spread_fee    REAL NOT NULL,
  network_fee   REAL NOT NULL DEFAULT 0.001,
  arc_tx_hash   TEXT,
  memo_id       TEXT,
  reference     TEXT,
  corridor_id   TEXT,
  corridor_step INTEGER,
  status        TEXT NOT NULL DEFAULT 'pending',
  settled_at    INTEGER,
  created_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_transactions_wallet
  ON transactions (wallet_address);

CREATE TABLE IF NOT EXISTS p2p_offers (
  id                  TEXT PRIMARY KEY,
  maker_address       TEXT NOT NULL,
  taker_address       TEXT,
  usdc_amount         REAL NOT NULL,
  local_currency      TEXT NOT NULL,
  local_amount        REAL NOT NULL,
  rate_offered        REAL NOT NULL,
  order_type          TEXT NOT NULL DEFAULT 'market',
  limit_rate          REAL,
  maker_timer_seconds INTEGER NOT NULL DEFAULT 1800,
  status              TEXT NOT NULL DEFAULT 'open',
  maker_confirmed     INTEGER NOT NULL DEFAULT 0,
  taker_confirmed     INTEGER NOT NULL DEFAULT 0,
  taker_deadline      INTEGER,
  maker_deadline      INTEGER,
  dispute_raised      INTEGER NOT NULL DEFAULT 0,
  dispute_id          TEXT,
  arc_tx_hash         TEXT,
  release_tx_hash     TEXT,
  created_at          INTEGER NOT NULL,
  updated_at          INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_p2p_offers_status
  ON p2p_offers (status);
CREATE INDEX IF NOT EXISTS idx_p2p_offers_maker
  ON p2p_offers (maker_address);

CREATE TABLE IF NOT EXISTS disputes (
  id             TEXT PRIMARY KEY,
  offer_id       TEXT NOT NULL,
  raised_by      TEXT NOT NULL,
  reason         TEXT,
  status         TEXT NOT NULL DEFAULT 'open',
  auto_settle_at INTEGER NOT NULL,
  settled_at     INTEGER,
  created_at     INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_disputes_offer
  ON disputes (offer_id);
CREATE INDEX IF NOT EXISTS idx_disputes_status
  ON disputes (status);

CREATE TABLE IF NOT EXISTS fx_rates (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  pair       TEXT NOT NULL,
  rate       REAL NOT NULL,
  change_24h REAL NOT NULL DEFAULT 0,
  source     TEXT NOT NULL,
  fetched_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_fx_rates_pair
  ON fx_rates (pair);

CREATE TABLE IF NOT EXISTS users (
  wallet_address   TEXT PRIMARY KEY,
  volume_30d       REAL NOT NULL DEFAULT 0,
  tx_count         INTEGER NOT NULL DEFAULT 0,
  dispute_warnings INTEGER NOT NULL DEFAULT 0,
  created_at       INTEGER NOT NULL
);

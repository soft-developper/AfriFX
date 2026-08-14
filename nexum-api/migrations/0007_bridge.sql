-- ============================================================
-- CCTP bridge transfers.
--
-- WHY THIS TABLE EXISTS AT ALL:
-- CCTP is burn-and-mint. Circle's own docs are blunt about the consequence:
-- "Once USDC is burned, complete the mint on destination or lose funds."
-- There is no rollback. If the browser closes, the user's laptop dies, or our
-- API restarts between the burn and the mint, the money is NOT gone but it IS
-- stranded until someone finishes the mint.
--
-- So every bridge is recorded BEFORE the burn is signed, and each stage is
-- persisted as it completes. That gives us:
--   * a resume path        (user returns, we know exactly where they were)
--   * a reconciler target  (a cron can finish stuck mints)
--   * an audit trail       (what happened, when, on which chain)
--
-- THE TWO FIELDS THAT MAKE RECOVERY POSSIBLE are message_bytes and
-- message_hash. Once we have those from the burn receipt, the mint can be
-- completed by ANYONE at ANY TIME (attestations don't expire) -- so as long as
-- they're saved, funds are recoverable even if everything else fails.
--
-- RUN EACH STATEMENT INDIVIDUALLY in the turso shell (it stops on first error).
-- ============================================================

CREATE TABLE IF NOT EXISTS bridge_transfers (
  id              TEXT PRIMARY KEY,        -- 'br-<uuid>'
  wallet_address  TEXT NOT NULL,           -- who owns this bridge (the signer)

  -- Route
  from_chain      TEXT NOT NULL,           -- our chain key, e.g. 'arc'
  to_chain        TEXT NOT NULL,           -- e.g. 'base'
  from_domain     INTEGER NOT NULL,        -- CCTP domain (NOT the EVM chain id)
  to_domain       INTEGER NOT NULL,
  amount          REAL NOT NULL,           -- USDC, human units
  recipient       TEXT NOT NULL,           -- destination address (usually same wallet)

  -- Stage: created -> approving -> burning -> attesting -> minting -> completed
  --        (or 'failed' at any point; 'stranded' if burned but mint unresolved)
  status          TEXT NOT NULL DEFAULT 'created',

  -- Evidence at each step. These are what make recovery possible.
  approve_tx      TEXT,                    -- ERC-20 approve (not needed on all chains)
  burn_tx         TEXT,                    -- depositForBurn tx hash on source
  message_bytes   TEXT,                    -- the CCTP message emitted by the burn
  message_hash    TEXT,                    -- keccak256(message) -- the attestation key
  attestation     TEXT,                    -- Circle's signature over the message
  mint_tx         TEXT,                    -- receiveMessage tx hash on destination

  error           TEXT,                    -- last error, for support/debugging
  attempts        INTEGER NOT NULL DEFAULT 0,

  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_bridge_wallet ON bridge_transfers (wallet_address, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_bridge_status ON bridge_transfers (status, updated_at);

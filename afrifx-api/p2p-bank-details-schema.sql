-- Adds the maker's payout details to each P2P offer, so a taker who accepts
-- knows exactly where to send the local-currency payment.
-- Safe to run more than once: each ADD COLUMN is guarded.
-- Run:  turso db shell <your-db-name> < afrifx-api/p2p-bank-details-schema.sql
--
-- SQLite/libSQL has no "ADD COLUMN IF NOT EXISTS", so if a column already
-- exists the statement errors harmlessly run them individually if needed.

ALTER TABLE p2p_offers ADD COLUMN payment_method   TEXT DEFAULT 'bank';   -- 'bank' | 'mobile_money'
ALTER TABLE p2p_offers ADD COLUMN account_name     TEXT;                  -- account holder / recipient name
ALTER TABLE p2p_offers ADD COLUMN account_number   TEXT;                  -- bank account no. OR mobile-money phone
ALTER TABLE p2p_offers ADD COLUMN bank_name        TEXT;                  -- bank name OR mobile-money provider
ALTER TABLE p2p_offers ADD COLUMN payment_note     TEXT;                  -- optional instructions / reference

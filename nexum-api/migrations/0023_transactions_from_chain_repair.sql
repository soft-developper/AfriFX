-- ============================================================
-- 0023_transactions_from_chain_repair.sql
-- Repair: 0022 was recorded as applied on the production DB but the
-- from_chain column is NOT present (POST /transactions failed with
-- "table transactions has no column named from_chain"). This re-adds it.
--
-- Safe to run whether or not the column exists: if it is already present the
-- migrate runner treats the "duplicate column name" error as already-applied
-- and skips it. If 0022 genuinely never ran, this adds the column for real.
-- NULL = Arc (historical default), so existing rows are unaffected.
-- ============================================================

ALTER TABLE transactions ADD COLUMN from_chain TEXT;

-- ============================================================
-- 0022_transactions_from_chain.sql
-- Multichain-send cleanup: record which chain a send happened on.
--
-- When Send became multichain, the transactions table still only knew about
-- Arc, so History couldn't pick the right block explorer (it defaulted every
-- send to arcscan) and cross-chain sends had no chain context. This adds a
-- nullable from_chain column; NULL / absent = Arc (the historical default), so
-- existing rows keep working unchanged.
-- ============================================================

ALTER TABLE transactions ADD COLUMN from_chain TEXT;

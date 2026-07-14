-- ============================================================
-- AfriFX Phase D site content tables
-- Run ONCE against your Turso DB:
--   turso db shell <your-db-name> < phaseD-schema.sql
-- (or paste the statements into: turso db shell <your-db-name>)
-- ============================================================

-- Single-row-per-key store for editable page content.
-- key = 'about'   -> value holds a JSON array of { heading, body } sections
-- key = 'contact' -> value holds a JSON object of contact fields
CREATE TABLE IF NOT EXISTS site_content (
  key         TEXT PRIMARY KEY,          -- 'about' | 'contact'
  value       TEXT NOT NULL,             -- JSON payload
  updated_by  TEXT,                      -- admin id who last edited
  updated_at  INTEGER NOT NULL           -- unix seconds
);

-- Messages submitted through the public Contact form.
-- Stored as a record AND emailed to the platform inbox via Resend.
CREATE TABLE IF NOT EXISTS contact_messages (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  email       TEXT NOT NULL,
  subject     TEXT,
  message     TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'new',  -- new | read | archived
  created_at  INTEGER NOT NULL
);

-- Seed sensible defaults so the public pages are never blank before
-- the admin edits them. INSERT OR IGNORE keeps existing rows untouched.
INSERT OR IGNORE INTO site_content (key, value, updated_at) VALUES
  ('about',
   '[{"heading":"About AfriFX","body":"AfriFX is a decentralized foreign-exchange and cross-border payments platform built on the Arc blockchain, making it fast and affordable to move value across Africa using stablecoins."},{"heading":"Our mission","body":"To give everyone access to instant, low-cost currency exchange and cross-border payments without the delays and fees of traditional banking."},{"heading":"How it works","body":"Convert between USDC and local currencies directly, or trade peer-to-peer on our marketplace. Every transaction settles on Arc in under a second, with fees paid in USDC."}]',
   strftime('%s','now')),
  ('contact',
   '{"email":"support@afrifx.xyz","phone":"","address":"","supportHours":"Monday to Friday, 9am – 5pm WAT","twitter":"https://x.com/afrifx","telegram":"","discord":""}',
   strftime('%s','now'));

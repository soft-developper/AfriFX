-- Ensures the contact_messages table exists (safe if Phase D already made it).
-- Run once if you're unsure whether Phase D's schema was applied:
--   turso db shell <your-db-name> < afrifx-api/messages-schema.sql
CREATE TABLE IF NOT EXISTS contact_messages (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  email       TEXT NOT NULL,
  subject     TEXT,
  message     TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'new',  -- new | read | archived
  created_at  INTEGER NOT NULL
);

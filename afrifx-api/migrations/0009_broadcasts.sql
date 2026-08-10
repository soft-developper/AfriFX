-- ============================================================
-- Admin broadcasts mass / targeted email from the general admin
--
-- Two things:
--   1) A broadcast opt-out on profiles. Users opted into TRANSACTIONAL alerts
--      (trades / disputes / invoices) a general broadcast is a different
--      category, so they get an explicit opt-out which we always honour.
--      Defaults to 1 (opted in) so existing users still receive announcements,
--      but every broadcast email carries an unsubscribe link.
--   2) A record of every broadcast sent, for the audit trail + delivery stats.
--
-- SQLite/libSQL has no "ADD COLUMN IF NOT EXISTS": if a column already exists
-- that statement errors harmlessly. Run the ALTERs individually if needed.
-- Run:  turso db shell <your-db-name> < afrifx-api/broadcasts-schema.sql
-- ============================================================

-- 1) Broadcast opt-out (users). 1 = will receive broadcasts, 0 = opted out.
ALTER TABLE profiles ADD COLUMN notify_broadcasts INTEGER DEFAULT 1;

-- An unguessable token so a user can unsubscribe from an email link without
-- being logged in. Generated lazily on first broadcast.
ALTER TABLE profiles ADD COLUMN unsubscribe_token TEXT;

-- 2) Broadcast history
CREATE TABLE IF NOT EXISTS admin_broadcasts (
  id              TEXT PRIMARY KEY,
  sent_by_id      TEXT NOT NULL,          -- admin id
  sent_by_name    TEXT NOT NULL,          -- shown in the email header

  audience        TEXT NOT NULL,          -- 'sub_admins' | 'all_users' | 'selected' | 'filtered'
  audience_detail TEXT,                   -- JSON: filter used, or list of recipients

  subject         TEXT NOT NULL,
  body            TEXT NOT NULL,          -- the admin's message (plain text / light markup)

  recipients      INTEGER DEFAULT 0,      -- how many we attempted
  delivered       INTEGER DEFAULT 0,
  failed          INTEGER DEFAULT 0,
  skipped_optout  INTEGER DEFAULT 0,      -- honoured opt-outs (users, not sub-admins)

  status          TEXT NOT NULL DEFAULT 'sending',  -- sending | sent | failed
  error           TEXT,

  created_at      INTEGER NOT NULL,
  completed_at    INTEGER
);

CREATE INDEX IF NOT EXISTS idx_broadcasts_sender ON admin_broadcasts (sent_by_id);
CREATE INDEX IF NOT EXISTS idx_broadcasts_time   ON admin_broadcasts (created_at);

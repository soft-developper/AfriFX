-- ============================================================
-- Dispute duty sessions — sub-admin working hours + duty tracking
--
-- 1) Working hours live ON the admin record (set by the general admin when
--    inviting them). Max 6 hours, recurring daily, with optional specific dates.
-- 2) admin_duty_sessions records each actual shift: when they clicked
--    "resume duty", when it ended, and what they did — this is the session log
--    the general admin reviews.
--
-- SQLite/libSQL has no "ADD COLUMN IF NOT EXISTS": if a column already exists
-- that line errors harmlessly, the rest still apply. Run individually if needed.
-- Run:  turso db shell <your-db-name> < afrifx-api/duty-sessions-schema.sql
-- ============================================================

-- Working hours on the admin record.
-- duty_start_min / duty_end_min: minutes from midnight UTC (e.g. 540 = 09:00 UTC).
-- Max span enforced in app code (6h = 360 min).
ALTER TABLE admins ADD COLUMN duty_start_min   INTEGER;         -- 0..1439, UTC
ALTER TABLE admins ADD COLUMN duty_end_min     INTEGER;         -- 0..1439, UTC
ALTER TABLE admins ADD COLUMN duty_days        TEXT;            -- CSV of 0..6 (Sun..Sat), e.g. '1,2,3,4,5'
ALTER TABLE admins ADD COLUMN duty_dates       TEXT;            -- optional CSV of 'YYYY-MM-DD' specific dates
ALTER TABLE admins ADD COLUMN duty_notified_at INTEGER;         -- last time we sent the 3-min heads-up

CREATE TABLE IF NOT EXISTS admin_duty_sessions (
  id                TEXT PRIMARY KEY,
  admin_id          TEXT NOT NULL,
  admin_name        TEXT NOT NULL,

  -- The scheduled window this session belongs to (unix seconds)
  window_start      INTEGER NOT NULL,
  window_end        INTEGER NOT NULL,

  -- Actual duty
  resumed_at        INTEGER,                -- when they clicked "resume duty"
  ended_at          INTEGER,                -- when the window elapsed / they clocked off
  status            TEXT NOT NULL DEFAULT 'scheduled',
                    -- scheduled | on_duty | ended | missed

  -- Session log (what they did) — filled when the session ends
  disputes_accepted INTEGER DEFAULT 0,
  disputes_resolved INTEGER DEFAULT 0,
  actions_count     INTEGER DEFAULT 0,
  log_sent          INTEGER DEFAULT 0,      -- 1 once summarised to the admin dashboard

  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_duty_admin   ON admin_duty_sessions (admin_id);
CREATE INDEX IF NOT EXISTS idx_duty_status  ON admin_duty_sessions (status);
CREATE INDEX IF NOT EXISTS idx_duty_window  ON admin_duty_sessions (window_start, window_end);

-- Working hours are chosen by the general admin at INVITE time, so they must
-- ride along on the invitation and be copied onto the admin record when the
-- sub-admin accepts and sets their password.
ALTER TABLE admin_invitations ADD COLUMN duty_start_min INTEGER;
ALTER TABLE admin_invitations ADD COLUMN duty_end_min   INTEGER;
ALTER TABLE admin_invitations ADD COLUMN duty_days      TEXT;
ALTER TABLE admin_invitations ADD COLUMN duty_dates     TEXT;

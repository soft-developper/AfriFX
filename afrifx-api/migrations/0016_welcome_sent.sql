-- ============================================================
-- Track whether the welcome email has been sent.
--
-- The welcome mail is sent the first time an account has an email
-- address, which is not always at creation: a Google sign-in only gives
-- us an address if the OAuth response includes one, and some accounts
-- get theirs later from the profile form.
--
-- Without this column we would either send nothing (the current bug) or
-- re-send on every sign-in until a profile exists.
-- ============================================================

ALTER TABLE accounts ADD COLUMN welcome_sent_at INTEGER;

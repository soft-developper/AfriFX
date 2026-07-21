-- ============================================================
-- AI dispute triage summaries (advisory, admin-facing).
--
-- Caches the generated brief per dispute so we don't re-pay Claude tokens on
-- every page view. Regenerate-on-demand overwrites the row.
--
-- RUN EACH STATEMENT INDIVIDUALLY in the turso shell (it stops on the first
-- error, so a combined file can abort before reaching CREATE TABLE).
-- ============================================================

CREATE TABLE IF NOT EXISTS dispute_ai_summaries (
  dispute_id      TEXT PRIMARY KEY,
  summary_json    TEXT    NOT NULL,   -- the structured brief (JSON)
  generated_by    TEXT,               -- admin id who triggered it
  model           TEXT,               -- which Claude model produced it
  evidence_count  INTEGER DEFAULT 0,  -- how many evidence PDFs were read
  created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ai_summary_dispute ON dispute_ai_summaries (dispute_id);

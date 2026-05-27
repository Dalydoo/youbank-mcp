-- Tracks Anthropic Message Batches submitted by the worker for backfill rescore.
-- Sync drip (new entities) stays on messages.create — this table is only for
-- the pending_rescore drain queue, which is async-acceptable.

CREATE TABLE yb_ai_batches (
  id                text PRIMARY KEY,
  operation         text NOT NULL CHECK (operation IN ('scoring')),
  status            text NOT NULL CHECK (status IN ('in_progress','ended','canceled')),
  entity_ids        jsonb NOT NULL,
  submitted_at      timestamptz NOT NULL DEFAULT now(),
  completed_at      timestamptz,
  results_consumed  boolean NOT NULL DEFAULT false
);

CREATE INDEX idx_yb_ai_batches_open
  ON yb_ai_batches(status)
  WHERE results_consumed = false;

-- Worker uses service_role context (lib/supabase/server.ts) which bypasses RLS.
-- The rls_auto_enable event trigger will enable RLS on this table — explicitly
-- disable it because no user-facing access is intended.
ALTER TABLE yb_ai_batches DISABLE ROW LEVEL SECURITY;

-- Supabase revokes default DML from service_role on new tables — grant back so
-- the worker can read/write batch tracking rows.
GRANT SELECT, INSERT, UPDATE, DELETE ON yb_ai_batches TO service_role;

-- Allow the new in-flight status on entity rows. Existing constraint is dropped
-- and recreated with 'scoring_in_batch' added to the allowed set.
ALTER TABLE yb_research_entities DROP CONSTRAINT IF EXISTS yb_research_entities_scoring_status_check;
ALTER TABLE yb_research_entities ADD CONSTRAINT yb_research_entities_scoring_status_check
  CHECK (scoring_status = ANY (ARRAY['pending','scoring','scored','pending_rescore','scoring_in_batch','failed']));

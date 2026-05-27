-- Audit follow-up on PR 3 code review (I1): prevent double-submit race in submitRescoreBatch.
-- Two simultaneous callers (user-triggered backfill + auto-trigger end-of-tick) could both
-- pass the concurrency guard and both insert. UNIQUE partial index forces at most one open
-- row per operation; race loser catches the constraint violation and exits cleanly.

CREATE UNIQUE INDEX IF NOT EXISTS yb_ai_batches_only_one_open
  ON yb_ai_batches((operation))
  WHERE results_consumed = false;

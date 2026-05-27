-- Week 6 PR 4: extend yb_ai_usage.operation CHECK constraint to allow 'digest'.
-- See spec Open Question 7. Recon (2026-05-21) confirmed the existing CHECK
-- constraint enumerates the allowed operations, so we drop + recreate with
-- 'digest' added.

ALTER TABLE yb_ai_usage DROP CONSTRAINT IF EXISTS yb_ai_usage_operation_check;
ALTER TABLE yb_ai_usage ADD CONSTRAINT yb_ai_usage_operation_check
  CHECK (operation IN (
    'enrichment','extraction','synthesis','scoring','lens','batch_submit_failed','digest'
  ));

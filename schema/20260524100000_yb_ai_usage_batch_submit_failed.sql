-- PR 3 code review M2: spec requires logUsage with operation='batch_submit_failed' on
-- Anthropic submit errors so cost accounting captures wasted attempts.

ALTER TABLE yb_ai_usage DROP CONSTRAINT IF EXISTS yb_ai_usage_operation_check;
ALTER TABLE yb_ai_usage ADD CONSTRAINT yb_ai_usage_operation_check
  CHECK (operation IN ('enrichment', 'extraction', 'synthesis', 'scoring', 'lens', 'batch_submit_failed'));

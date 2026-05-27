-- supabase/migrations/20260527000200_yb_ai_usage_audio_overview_operation.sql
--
-- Audio overviews: extend yb_ai_usage.operation CHECK constraint to allow 'audio_overview'.
-- Mirrors the digest extension (20260626000010_yb_ai_usage_digest_operation.sql).

ALTER TABLE yb_ai_usage DROP CONSTRAINT IF EXISTS yb_ai_usage_operation_check;
ALTER TABLE yb_ai_usage ADD CONSTRAINT yb_ai_usage_operation_check
  CHECK (operation IN (
    'enrichment', 'extraction', 'synthesis', 'scoring',
    'lens', 'batch_submit_failed', 'digest', 'audio_overview'
  ));

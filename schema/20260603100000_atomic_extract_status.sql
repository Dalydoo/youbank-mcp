-- Week 3 PR 3: per-row resumable status for the Phase A2 backfill.
-- Mirrors Week 2 PR 1's embedding_status pattern (Week 1 lesson 4).
-- Lets the backfill script drain 'pending' rows incrementally and
-- resume cleanly after a crash.

ALTER TABLE yb_vault_items
  ADD COLUMN IF NOT EXISTS atomic_extract_status text NOT NULL DEFAULT 'pending'
    CHECK (atomic_extract_status IN ('pending', 'extracting', 'extracted', 'failed')),
  ADD COLUMN IF NOT EXISTS atomic_extracted_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_yb_vault_items_atomic_extract_pending
  ON yb_vault_items (atomic_extract_status)
  WHERE atomic_extract_status = 'pending';

-- No new GRANT — existing yb_vault_items privileges flow through ALTER.

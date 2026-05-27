-- Week 3 PR 2 follow-ups: resolves code-review backlog + cross-PR drift.
--
-- (1) ADD COLUMN relation_type — the original migration's on-disk file
--     declared this column but live DB lacked it (PR 1's mention_relation
--     enum landed after PR 2's table was applied). This realigns live DB
--     with the on-disk schema.
-- (2) FTS converted from expression index to stored generated column,
--     matching the project pattern at yb_vault_items.search_vector
--     (see lib/ai/lens.ts and supabase-transcript-pipeline.sql). Index
--     name is preserved so supabase-js .textSearch() index-uses cleanly.
-- (3) CHECK on atomic_claim length (50-3000 chars) guards against
--     btree-tuple overflow on the UNIQUE constraint and matches spec
--     intent of 50-300 word atomic claims (~3000 chars ≈ 450 words, a
--     generous upper bound clear of the ~2700-byte btree limit).
-- (4) CHECK on chunk bounds defends against PR 3 swapping start/end args.

-- 1. relation_type column + partial index (cross-PR drift fix)
ALTER TABLE yb_atomic_notes
  ADD COLUMN IF NOT EXISTS relation_type mention_relation;

CREATE INDEX IF NOT EXISTS idx_yb_atomic_notes_relation
  ON yb_atomic_notes (relation_type)
  WHERE relation_type IS NOT NULL;

-- 2. FTS: drop expression index, add stored generated tsvector + GIN index.
DROP INDEX IF EXISTS idx_yb_atomic_notes_claim_fts;

ALTER TABLE yb_atomic_notes
  ADD COLUMN IF NOT EXISTS atomic_claim_tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('english', atomic_claim)) STORED;

CREATE INDEX IF NOT EXISTS idx_yb_atomic_notes_claim_fts
  ON yb_atomic_notes USING GIN (atomic_claim_tsv);

-- 3. CHECK on atomic_claim length (idempotent via DO block).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'yb_atomic_notes_claim_length'
      AND conrelid = 'public.yb_atomic_notes'::regclass
  ) THEN
    ALTER TABLE yb_atomic_notes
      ADD CONSTRAINT yb_atomic_notes_claim_length
      CHECK (length(atomic_claim) BETWEEN 50 AND 3000);
  END IF;
END $$;

-- 4. CHECK on chunk timing bounds (idempotent via DO block).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'yb_atomic_notes_chunk_bounds'
      AND conrelid = 'public.yb_atomic_notes'::regclass
  ) THEN
    ALTER TABLE yb_atomic_notes
      ADD CONSTRAINT yb_atomic_notes_chunk_bounds
      CHECK (chunk_start_seconds >= 0 AND chunk_end_seconds >= chunk_start_seconds);
  END IF;
END $$;

-- supabase/migrations/20260703000000_patterns_tier.sql
--
-- Pattern synthesis tier: yb_patterns auto-lifts recurring atomic claims
-- (>=3 occurrences across >=2 distinct vault items) into a higher-confidence
-- layer that LENS and the MCP server prefer over raw atomic notes.
--
-- Three new tables (yb_patterns, yb_config, yb_clustering_runs), one altered
-- (yb_atomic_notes gains embedding columns), two SQL functions
-- (yb_atomic_notes_nn for clustering, yb_patterns_search for retrieval).
--
-- Spec: docs/superpowers/specs/2026-05-27-patterns-tier-design.md

-- Note: applied to prod 2026-05-27 under version 20260527132309 (Supabase
-- assigned its own timestamp on apply; the original filename was
-- 20260528000000_patterns_tier.sql). Renamed to 20260703000000 post-application
-- so a fresh `supabase db reset` or public-repo `schema/` apply sees this
-- AFTER 20260603000000_atomic_notes_table.sql (which creates the dependency
-- tables + atomic_note_type enum). Prod tracking still shows the original
-- version — that's fine because the migration is already applied.

-- ---------- 1. yb_atomic_notes embedding columns -----------------------------

ALTER TABLE yb_atomic_notes
  ADD COLUMN IF NOT EXISTS embedding vector(384),
  ADD COLUMN IF NOT EXISTS embedding_status text NOT NULL DEFAULT 'pending'
    CHECK (embedding_status IN ('pending','embedded','failed')),
  ADD COLUMN IF NOT EXISTS embedded_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_yb_atomic_notes_embedding_hnsw
  ON yb_atomic_notes USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_yb_atomic_notes_embedding_pending
  ON yb_atomic_notes (embedding_status) WHERE embedding_status = 'pending';

-- ---------- 2. yb_config -----------------------------------------------------

CREATE TABLE IF NOT EXISTS yb_config (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  description text,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO yb_config (key, value, description) VALUES
  ('pattern_min_occurrence',            '3',     'Min atomic notes per cluster to promote'),
  ('pattern_min_source_diversity',      '2',     'Min distinct vault items backing a pattern'),
  ('pattern_cosine_threshold_cluster',  '0.85',  'Min cosine to consider two notes same cluster'),
  ('pattern_cosine_threshold_reinforce','0.90',  'Min cosine to merge cluster with existing pattern'),
  ('pattern_cosine_threshold_lens',     '0.55',  'Min cosine for LENS preferred-citation retrieval'),
  ('pattern_lens_top_k',                '10',    'Patterns to inject per LENS turn'),
  ('lens_patterns_enabled',             'false', 'Master switch for LENS pattern injection')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE yb_config DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON yb_config TO service_role;
GRANT SELECT ON yb_config TO authenticated;

-- ---------- 3. yb_patterns ---------------------------------------------------

CREATE TABLE IF NOT EXISTS yb_patterns (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pattern_text        text NOT NULL,
  pattern_type        atomic_note_type NOT NULL DEFAULT 'claim',
  occurrence_count    int  NOT NULL,
  source_diversity    int  NOT NULL,
  avg_confidence      real NOT NULL CHECK (avg_confidence BETWEEN 0 AND 1),
  source_note_ids     uuid[] NOT NULL,
  source_item_ids     uuid[] NOT NULL,
  model               text,
  embedding           vector(384),
  first_observed_at   timestamptz NOT NULL DEFAULT now(),
  last_reinforced_at  timestamptz NOT NULL DEFAULT now(),
  status              text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'stale', 'merged', 'hidden')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_yb_patterns_status
  ON yb_patterns (status);
CREATE INDEX IF NOT EXISTS idx_yb_patterns_last_reinforced
  ON yb_patterns (last_reinforced_at DESC);
CREATE INDEX IF NOT EXISTS idx_yb_patterns_embedding_hnsw
  ON yb_patterns USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

ALTER TABLE yb_patterns DISABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON yb_patterns TO service_role;

-- ---------- 4. yb_clustering_runs --------------------------------------------

CREATE TABLE IF NOT EXISTS yb_clustering_runs (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at           timestamptz NOT NULL DEFAULT now(),
  completed_at         timestamptz,
  notes_embedded       int DEFAULT 0,
  notes_total          int DEFAULT 0,
  clusters_found       int DEFAULT 0,
  patterns_created     int DEFAULT 0,
  patterns_reinforced  int DEFAULT 0,
  patterns_pruned      int DEFAULT 0,
  patterns_staled      int DEFAULT 0,
  duration_ms          int,
  status               text DEFAULT 'running'
    CHECK (status IN ('running','complete','failed')),
  error_message        text
);

ALTER TABLE yb_clustering_runs DISABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON yb_clustering_runs TO service_role;

-- ---------- 5. yb_atomic_notes_nn --------------------------------------------

CREATE OR REPLACE FUNCTION yb_atomic_notes_nn(note_id uuid, k int, min_cosine real)
RETURNS TABLE (id uuid, cosine real)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  WITH anchor AS (SELECT embedding FROM yb_atomic_notes WHERE yb_atomic_notes.id = note_id)
  SELECT n.id, (1 - (n.embedding <=> a.embedding))::real AS cosine
  FROM yb_atomic_notes n, anchor a
  WHERE n.id != note_id
    AND n.embedding IS NOT NULL
    AND (1 - (n.embedding <=> a.embedding)) >= min_cosine
  ORDER BY n.embedding <=> a.embedding
  LIMIT k;
$$;

REVOKE ALL ON FUNCTION yb_atomic_notes_nn(uuid, int, real) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION yb_atomic_notes_nn(uuid, int, real) TO service_role;

-- ---------- 6. yb_patterns_search --------------------------------------------

CREATE OR REPLACE FUNCTION yb_patterns_search(
  query_embedding vector(384),
  min_cosine real DEFAULT 0.55,
  top_n int DEFAULT 10
)
RETURNS TABLE (
  id uuid,
  pattern_text text,
  pattern_type atomic_note_type,
  occurrence_count int,
  source_diversity int,
  avg_confidence real,
  last_reinforced_at timestamptz,
  cosine real
)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT
    p.id,
    p.pattern_text,
    p.pattern_type,
    p.occurrence_count,
    p.source_diversity,
    p.avg_confidence,
    p.last_reinforced_at,
    (1 - (p.embedding <=> query_embedding))::real AS cosine
  FROM yb_patterns p
  WHERE p.status = 'active'
    AND p.embedding IS NOT NULL
    AND (1 - (p.embedding <=> query_embedding)) >= min_cosine
  ORDER BY p.embedding <=> query_embedding
  LIMIT top_n;
$$;

REVOKE ALL ON FUNCTION yb_patterns_search(vector, real, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION yb_patterns_search(vector, real, int) TO service_role;

-- Week 4 PR 1 follow-up: perf fixes for yb_hybrid_search.
-- Forward-only — replaces the function body via CREATE OR REPLACE; signature
-- and return type are unchanged so PR 2/3/4 can branch from this state.
--
-- Two fixes:
--
-- 1. src_vault_cosine: move ORDER BY embedding <=> q + LIMIT into an inner
--    subquery, then apply row_number() OVER () to the LIMITed set in the
--    outer SELECT. The planner can push <=> into the HNSW operator class in
--    a flat subquery, but cannot push it through a window function. The old
--    shape (window over ORDER BY <=>, LIMIT outside) risks a Seq Scan
--    fallback once the table grows past pgvector's planner heuristics.
--    Also adds query_embedding IS NOT NULL guard so a NULL query_embedding
--    can't trigger a seq scan that surfaces unordered rows.
--
-- 2. src_vault_cosine LIMIT: 50 -> 40 to align with pgvector's default
--    hnsw.ef_search=40. With ef_search=40 the HNSW probe returns at most 40
--    candidates regardless of LIMIT, so LIMIT 50 silently capped at 40
--    anyway. Lowering it makes the cap explicit. Callers needing wider
--    recall can `SET LOCAL hnsw.ef_search = 100` before invoking the
--    function. Net candidate pool: 4 sources * 40 = up to 160; top_n=20
--    fusion output is unaffected.

CREATE OR REPLACE FUNCTION yb_hybrid_search(
  query_text        text,
  query_embedding   vector(384),
  k_const           int  DEFAULT 60,
  top_n             int  DEFAULT 20
)
RETURNS TABLE (
  vault_item_id     uuid,
  rrf_score         double precision,
  hit_sources       text[],
  atomic_note_ids   uuid[]
)
LANGUAGE sql STABLE
AS $$
  WITH
  -- Source 1: metadata FTS (yb_vault_items.search_vector).
  src_meta_fts AS (
    SELECT id AS vault_item_id,
           row_number() OVER (ORDER BY ts_rank(search_vector, plainto_tsquery('english', query_text)) DESC) AS rank
    FROM yb_vault_items
    WHERE search_vector @@ plainto_tsquery('english', query_text)
    LIMIT 50
  ),
  -- Source 2: transcript FTS (yb_vault_items.transcript_tsv). Same shape as src_meta_fts.
  src_transcript_fts AS (
    SELECT id AS vault_item_id,
           row_number() OVER (ORDER BY ts_rank(transcript_tsv, plainto_tsquery('english', query_text)) DESC) AS rank
    FROM yb_vault_items
    WHERE transcript_tsv @@ plainto_tsquery('english', query_text)
    LIMIT 50
  ),
  -- Source 3: vault-item cosine (yb_vault_items.embedding via HNSW).
  -- Inner subquery does the HNSW probe (planner can push <=> into the
  -- index here). Outer SELECT applies row_number() to the LIMITed set;
  -- the row order IS the cosine-similarity order from the inner ORDER BY.
  -- LIMIT 40 aligns with default hnsw.ef_search; tunable via
  -- `SET LOCAL hnsw.ef_search = 100` for wider recall.
  src_vault_cosine AS (
    SELECT vault_item_id, row_number() OVER () AS rank FROM (
      SELECT id AS vault_item_id
      FROM yb_vault_items
      WHERE embedding IS NOT NULL AND query_embedding IS NOT NULL
      ORDER BY embedding <=> query_embedding
      LIMIT 40
    ) s
  ),
  -- Source 4: atomic-note FTS rolled up to parent vault item. Surfaces
  -- note IDs so the response builder can cite the specific claim.
  src_atomic_fts AS (
    SELECT vault_item_id,
           row_number() OVER (ORDER BY MAX(ts_rank(atomic_claim_tsv, plainto_tsquery('english', query_text))) DESC) AS rank,
           array_agg(id ORDER BY ts_rank(atomic_claim_tsv, plainto_tsquery('english', query_text)) DESC)
             FILTER (WHERE atomic_claim_tsv @@ plainto_tsquery('english', query_text)) AS note_ids
    FROM yb_atomic_notes
    WHERE atomic_claim_tsv @@ plainto_tsquery('english', query_text)
    GROUP BY vault_item_id
    LIMIT 50
  ),
  -- Union all four sources; sum RRF contributions per vault_item_id.
  fused AS (
    SELECT
      vault_item_id,
      SUM(1.0 / (k_const + rank)) AS rrf_score,
      array_agg(src)              AS hit_sources,
      (SELECT note_ids FROM src_atomic_fts a WHERE a.vault_item_id = u.vault_item_id) AS atomic_note_ids
    FROM (
      SELECT vault_item_id, rank, 'meta_fts'::text         AS src FROM src_meta_fts
      UNION ALL
      SELECT vault_item_id, rank, 'transcript_fts'::text   AS src FROM src_transcript_fts
      UNION ALL
      SELECT vault_item_id, rank, 'vault_cosine'::text     AS src FROM src_vault_cosine
      UNION ALL
      SELECT vault_item_id, rank, 'atomic_fts'::text       AS src FROM src_atomic_fts
    ) u
    GROUP BY vault_item_id
  )
  SELECT vault_item_id, rrf_score, hit_sources, atomic_note_ids
  FROM fused
  ORDER BY rrf_score DESC
  LIMIT top_n;
$$;

-- Privileges re-affirmed (CREATE OR REPLACE preserves grants, but state the
-- invariant explicitly so a future rebase that recreates the function with
-- DROP+CREATE doesn't silently lose service_role access).
REVOKE ALL ON FUNCTION yb_hybrid_search(text, vector, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION yb_hybrid_search(text, vector, int, int) TO service_role;

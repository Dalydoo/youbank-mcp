-- Week 4 PR 1: hybrid retrieval Postgres function.
-- Fuses four candidate sources via Reciprocal Rank Fusion (RRF):
--   1. Metadata FTS (yb_vault_items.search_vector)
--   2. Transcript FTS (yb_vault_items.transcript_tsv)
--   3. Vault-item cosine (yb_vault_items.embedding via HNSW)
--   4. Atomic-note FTS rolled up to parent vault item (yb_atomic_notes.atomic_claim_tsv)
--
-- RRF: SUM(1 / (k_const + rank_in_source)) across sources, ORDER BY sum DESC.
-- k_const default 60 (Cormack et al. 2009). top_n default 20.
--
-- Inputs: query_text (FTS via plainto_tsquery), query_embedding (384-dim,
-- client-side embedded via lib/ai/embeddings.embed()), k_const, top_n.
-- Each sub-source limits to top 50 before fusing; max 200 rows considered.

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
  src_vault_cosine AS (
    SELECT id AS vault_item_id,
           row_number() OVER (ORDER BY embedding <=> query_embedding ASC) AS rank
    FROM yb_vault_items WHERE embedding IS NOT NULL
    LIMIT 50
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

-- Function privileges: service_role only; LENS reads via service_role.
-- (anon/authenticated should never call this directly.)
-- Week 1 lesson 2 about service_role grants applies to functions too:
-- function permissions are NOT inherited from table permissions.
REVOKE ALL ON FUNCTION yb_hybrid_search(text, vector, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION yb_hybrid_search(text, vector, int, int) TO service_role;

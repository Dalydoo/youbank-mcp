-- Week 4 PR 3: edge-gated v2 of yb_hybrid_search.
-- Same signature as v1 (20260609000000_yb_hybrid_search_fn,
-- 20260609100000_yb_hybrid_search_perf_fixes). The new fifth source —
-- src_entity_graph — surfaces items whose entities co-occur with the
-- query's anchor entities, weighted by (evidence_count / hub_size).
-- Bridge entities (low hub_size, high evidence_count) get the biggest
-- weight; hubs (high hub_size) get damped to a small contribution.
--
-- Additive via RRF rather than multiplicative on the base sources (spec
-- §3 — see plan §"Why now"). If the entity_graph source proves noisy, the
-- rollback re-applies 20260609100000 and the four-source fusion is unchanged.
--
-- Pre-populate note: at apply time, yb_entity_relations is empty (the v2
-- populate migration runs post-drain). With zero edges, src_entity_graph
-- returns zero rows and the fused output is byte-identical to v1's top-N.
-- Edge gating activates organically once the populate completes.

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
  -- Source 1: metadata FTS (yb_vault_items.search_vector). Unchanged from v1.
  src_meta_fts AS (
    SELECT id AS vault_item_id,
           row_number() OVER (ORDER BY ts_rank(search_vector, plainto_tsquery('english', query_text)) DESC) AS rank
    FROM yb_vault_items
    WHERE search_vector @@ plainto_tsquery('english', query_text)
    LIMIT 50
  ),
  -- Source 2: transcript FTS. Unchanged from v1.
  src_transcript_fts AS (
    SELECT id AS vault_item_id,
           row_number() OVER (ORDER BY ts_rank(transcript_tsv, plainto_tsquery('english', query_text)) DESC) AS rank
    FROM yb_vault_items
    WHERE transcript_tsv @@ plainto_tsquery('english', query_text)
    LIMIT 50
  ),
  -- Source 3: vault-item cosine. Unchanged from v1 (perf-fixed shape from
  -- 20260609100000: inner subquery for HNSW pushdown, LIMIT 40 to align
  -- with default hnsw.ef_search).
  src_vault_cosine AS (
    SELECT vault_item_id, row_number() OVER () AS rank FROM (
      SELECT id AS vault_item_id
      FROM yb_vault_items
      WHERE embedding IS NOT NULL AND query_embedding IS NOT NULL
      ORDER BY embedding <=> query_embedding
      LIMIT 40
    ) s
  ),
  -- Source 4: atomic-note FTS rolled up to parent vault item. Unchanged from v1.
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

  -- NEW: hub penalty per entity = count of distinct vault items each
  -- entity is mentioned in. Higher count = more hub-like = lower signal.
  entity_hub_size AS (
    SELECT entity_id, COUNT(DISTINCT vault_item_id) AS hub_size
    FROM yb_entity_mentions
    GROUP BY entity_id
  ),
  -- NEW: Anchor entities — any entity whose name matches the query text via FTS.
  -- (Open Question 8 — could later upgrade to cosine on yb_research_entities.embedding.)
  anchor_entities AS (
    SELECT id AS entity_id
    FROM yb_research_entities
    WHERE disposition = 'active'
      AND to_tsvector('english', name) @@ plainto_tsquery('english', query_text)
    LIMIT 5
  ),
  -- NEW: Neighbour entities via yb_entity_relations, weighted by
  -- (evidence_count / hub_size_of_neighbour). Bridge entities (low
  -- hub_size, high evidence_count) get the biggest weight.
  neighbour_entities AS (
    SELECT
      CASE WHEN r.source_entity_id = a.entity_id THEN r.target_entity_id
           ELSE r.source_entity_id END                  AS neighbour_id,
      SUM(r.evidence_count::double precision /
          GREATEST(h.hub_size, 1))                      AS bridge_weight
    FROM yb_entity_relations r
    JOIN anchor_entities a
      ON a.entity_id IN (r.source_entity_id, r.target_entity_id)
    JOIN entity_hub_size h
      ON h.entity_id = (
        CASE WHEN r.source_entity_id = a.entity_id THEN r.target_entity_id
             ELSE r.source_entity_id END
      )
    GROUP BY 1
  ),
  -- NEW: Source 5 — items mentioning a bridge-weighted neighbour entity.
  src_entity_graph AS (
    SELECT m.vault_item_id,
           row_number() OVER (
             ORDER BY SUM(n.bridge_weight) DESC
           ) AS rank
    FROM yb_entity_mentions m
    JOIN neighbour_entities n ON n.neighbour_id = m.entity_id
    GROUP BY m.vault_item_id
    LIMIT 50
  ),

  -- Union all FIVE sources; sum RRF contributions per vault_item_id.
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
      UNION ALL
      SELECT vault_item_id, rank, 'entity_graph'::text     AS src FROM src_entity_graph
    ) u
    GROUP BY vault_item_id
  )
  SELECT vault_item_id, rrf_score, hit_sources, atomic_note_ids
  FROM fused
  ORDER BY rrf_score DESC
  LIMIT top_n;
$$;

-- Re-grant (CREATE OR REPLACE preserves grants per Postgres semantics,
-- but be explicit for safety per Week 1 lesson 2).
REVOKE ALL ON FUNCTION yb_hybrid_search(text, vector, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION yb_hybrid_search(text, vector, int, int) TO service_role;

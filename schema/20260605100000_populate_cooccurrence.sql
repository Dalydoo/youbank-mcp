-- Week 3 PR 4: derive co-occurrence edges from Phase A2 transcript_llm
-- mentions. Idempotent (UPSERT ON CONFLICT). Re-run after PR 3's backfill
-- to roll up new edges; running pre-backfill yields 0 rows (harmless).

WITH pairs AS (
  SELECT
    LEAST(m1.entity_id, m2.entity_id)    AS source_entity_id,
    GREATEST(m1.entity_id, m2.entity_id) AS target_entity_id,
    COUNT(DISTINCT m1.vault_item_id)     AS weight,
    COUNT(*)                             AS evidence_count,
    MAX(m1.created_at)                   AS last_observed_at
  FROM yb_entity_mentions m1
  JOIN yb_entity_mentions m2
    ON m1.vault_item_id = m2.vault_item_id
   AND m1.entity_id < m2.entity_id            -- avoid self-pairs and dup pairs
  WHERE m1.extraction_method = 'transcript_llm'
    AND m2.extraction_method = 'transcript_llm'
  GROUP BY 1, 2
  HAVING COUNT(DISTINCT m1.vault_item_id) >= 1
)
INSERT INTO yb_entity_relations
  (source_entity_id, target_entity_id, relation_type, weight, evidence_count, last_observed_at)
SELECT source_entity_id, target_entity_id, 'co_occurrence',
       weight, evidence_count, last_observed_at
FROM pairs
ON CONFLICT (source_entity_id, target_entity_id, relation_type) DO UPDATE
SET weight           = EXCLUDED.weight,
    evidence_count   = EXCLUDED.evidence_count,
    last_observed_at = EXCLUDED.last_observed_at,
    updated_at       = now();

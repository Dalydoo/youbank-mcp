-- Week 3 PR 4 follow-up: corrected co-occurrence populate.
--
-- Fixes the last_observed_at bug from the original populate migration
-- (20260605100000_populate_cooccurrence.sql). The self-join enforces
-- m1.entity_id < m2.entity_id, which means m1 is always the lower-id
-- side; the original MAX(m1.created_at) therefore never considered
-- m2's timestamp. Empirically diverged on 226/356 simulated pairs in
-- code review. Replaced with MAX(GREATEST(m1.created_at, m2.created_at))
-- so "last observed" is genuinely the most recent observation on
-- either side of the pair.
--
-- Idempotency: ON CONFLICT DO UPDATE overwrites with freshly aggregated
-- values, so this migration safely re-derives all rows from the current
-- yb_entity_mentions state. Apply this AFTER PR 3's Phase A2 backfill
-- has drained transcript_llm mentions; running pre-backfill yields 0
-- rows (harmless).
--
-- If a future re-trigger is needed (e.g. after additional vault items
-- are backfilled), author a new-timestamp copy of this body — Supabase
-- migrations apply once each.

WITH pairs AS (
  SELECT
    LEAST(m1.entity_id, m2.entity_id)                    AS source_entity_id,
    GREATEST(m1.entity_id, m2.entity_id)                 AS target_entity_id,
    COUNT(DISTINCT m1.vault_item_id)                     AS weight,
    COUNT(*)                                             AS evidence_count,
    MAX(GREATEST(m1.created_at, m2.created_at))          AS last_observed_at
  FROM yb_entity_mentions m1
  JOIN yb_entity_mentions m2
    ON m1.vault_item_id = m2.vault_item_id
   AND m1.entity_id < m2.entity_id           -- avoid self-pairs and dup pairs
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

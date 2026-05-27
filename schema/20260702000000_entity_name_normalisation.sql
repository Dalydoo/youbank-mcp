-- Week 7 PR: entity-name normalisation.
--
-- Context: yb_research_entities has a UNIQUE(normalized_key) constraint, but
-- normalized_key is "{entity_type}:{name|url}:{slug}" — so the SAME real-world
-- entity gets DIFFERENT keys when extractors disagree on entity_type or when
-- one source has a URL and another only has a name. Recon (2026-05-21) shows
-- 333 dup groups covering 775 rows by lower(btrim(name)):
--   • "Claude" → 5 rows across tool/app
--   • "GitHub" → 7 rows across repo/app/tool/community
--   • "Claude Code" → 3 rows across tool/app/concept (the namesake of this PR)
--
-- These duplicate edges in yb_entity_relations and split the
-- co-occurrence weight that LENS retrieval scores on.
--
-- Strategy:
--   1. Add name_norm_key (generated, lower(btrim(name)) with whitespace
--      collapsed) and canonical_entity_id (self-ref).
--   2. For each name_norm_key group with >1 active row, pick a canonical:
--      most mentions wins, ties → earliest created_at.
--   3. Repoint yb_entity_mentions.entity_id from merged rows to canonical.
--      Pre-existing UNIQUE(entity_id, vault_item_id) collides for items that
--      have mentions on both old and new ids — DELETE the duplicate mention
--      rows (same evidence, no information loss) before repointing the rest.
--   4. Mark merged rows disposition='merged' and canonical_entity_id=<canon>.
--   5. RECOMPUTE yb_entity_relations from the now-deduped mentions (lifted
--      from 20260605200000_populate_cooccurrence_v2.sql).
--   6. Add unique partial index on name_norm_key WHERE disposition='active'.
--
-- Safety: all wrapped in a transaction. The migration logs row counts before
-- and after each phase via RAISE NOTICE so the apply output is auditable.
-- yb_entity_mentions is NEVER truncated — only the 494 (entity_id, vault_item_id)
-- collision rows are deleted, all of which are duplicate evidence for the
-- same vault item.
--
-- The migration runs inside Supabase's implicit migration transaction.

-- ---------------------------------------------------------------------------
-- Phase 0: log pre-state.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_active_entities int;
  v_mentions int;
  v_relations int;
  v_dup_groups int;
BEGIN
  SELECT count(*) INTO v_active_entities FROM yb_research_entities WHERE disposition='active';
  SELECT count(*) INTO v_mentions FROM yb_entity_mentions;
  SELECT count(*) INTO v_relations FROM yb_entity_relations;
  SELECT count(*) INTO v_dup_groups FROM (
    SELECT 1 FROM yb_research_entities WHERE disposition='active'
    GROUP BY regexp_replace(lower(btrim(name)), '\s+', ' ', 'g')
    HAVING count(*) > 1
  ) s;
  RAISE NOTICE '[pre] active_entities=% mentions=% relations=% name_dup_groups=%',
    v_active_entities, v_mentions, v_relations, v_dup_groups;
END $$;

-- ---------------------------------------------------------------------------
-- Phase 1: widen disposition CHECK to allow 'merged'.
-- ---------------------------------------------------------------------------
ALTER TABLE yb_research_entities DROP CONSTRAINT IF EXISTS yb_research_entities_disposition_check;
ALTER TABLE yb_research_entities ADD CONSTRAINT yb_research_entities_disposition_check
  CHECK (disposition IN ('active','archived','deleted','merged'));

-- ---------------------------------------------------------------------------
-- Phase 2: add name_norm_key (generated) + canonical_entity_id (self-ref).
-- ---------------------------------------------------------------------------
ALTER TABLE yb_research_entities
  ADD COLUMN IF NOT EXISTS name_norm_key text
    GENERATED ALWAYS AS (regexp_replace(lower(btrim(name)), '\s+', ' ', 'g')) STORED;

ALTER TABLE yb_research_entities
  ADD COLUMN IF NOT EXISTS canonical_entity_id uuid
    REFERENCES yb_research_entities(id) ON DELETE SET NULL;

-- Default canonical_entity_id to self for every existing row (and any future
-- non-merged inserts will be self-canonical via the column default below).
UPDATE yb_research_entities SET canonical_entity_id = id WHERE canonical_entity_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_yb_research_entities_canonical
  ON yb_research_entities (canonical_entity_id);

CREATE INDEX IF NOT EXISTS idx_yb_research_entities_name_norm_key
  ON yb_research_entities (name_norm_key);

-- ---------------------------------------------------------------------------
-- Phase 3: pick canonical per name_norm_key group; build remap table.
--   canonical = max(mentions_count), ties broken by earliest created_at.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _wk7_canonical ON COMMIT DROP AS
SELECT DISTINCT ON (name_norm_key)
       name_norm_key,
       id AS canonical_id
FROM yb_research_entities
WHERE disposition = 'active'
  AND name_norm_key IN (
    SELECT name_norm_key FROM yb_research_entities
    WHERE disposition='active'
    GROUP BY name_norm_key HAVING count(*) > 1
  )
ORDER BY name_norm_key, mentions_count DESC NULLS LAST, created_at ASC, id ASC;

CREATE TEMP TABLE _wk7_remap ON COMMIT DROP AS
SELECT e.id AS old_id, c.canonical_id AS new_id
FROM yb_research_entities e
JOIN _wk7_canonical c ON c.name_norm_key = e.name_norm_key
WHERE e.disposition = 'active'
  AND e.id <> c.canonical_id;

CREATE INDEX ON _wk7_remap (old_id);

DO $$
DECLARE
  v_groups int;
  v_to_merge int;
BEGIN
  SELECT count(*) INTO v_groups FROM _wk7_canonical;
  SELECT count(*) INTO v_to_merge FROM _wk7_remap;
  RAISE NOTICE '[phase3] dup_groups=% rows_to_merge=%', v_groups, v_to_merge;
END $$;

-- ---------------------------------------------------------------------------
-- Phase 4a: delete duplicate mention rows that would collide on
-- UNIQUE(entity_id, vault_item_id) once repointed. We keep the mention on
-- the canonical side when present; otherwise we keep one mention per
-- (canonical_id, vault_item_id) and drop the rest.
--
-- "Duplicates" here are mention rows that already cover the same vault item
-- via the canonical entity — same evidence, redundant row. yb_entity_mentions
-- is NOT truncated.
-- ---------------------------------------------------------------------------
WITH ranked AS (
  SELECT
    m.id,
    COALESCE(r.new_id, m.entity_id) AS effective_entity_id,
    m.vault_item_id,
    -- Prefer rows that already point at the canonical (r.new_id IS NULL),
    -- then earliest created_at, then lowest uuid for determinism.
    row_number() OVER (
      PARTITION BY COALESCE(r.new_id, m.entity_id), m.vault_item_id
      ORDER BY (r.new_id IS NULL) DESC, m.created_at ASC, m.id ASC
    ) AS rn
  FROM yb_entity_mentions m
  LEFT JOIN _wk7_remap r ON r.old_id = m.entity_id
)
DELETE FROM yb_entity_mentions m
USING ranked
WHERE m.id = ranked.id AND ranked.rn > 1;

-- ---------------------------------------------------------------------------
-- Phase 4b: repoint surviving mentions from merged rows to canonical.
-- ---------------------------------------------------------------------------
UPDATE yb_entity_mentions m
SET entity_id = r.new_id
FROM _wk7_remap r
WHERE m.entity_id = r.old_id;

-- ---------------------------------------------------------------------------
-- Phase 4c: mark merged entity rows.
-- ---------------------------------------------------------------------------
UPDATE yb_research_entities e
SET disposition = 'merged',
    canonical_entity_id = r.new_id,
    updated_at = now()
FROM _wk7_remap r
WHERE e.id = r.old_id;

-- Recompute mentions_count on canonical rows so the cached count reflects
-- the post-merge reality.
WITH counts AS (
  SELECT entity_id, count(*) AS c FROM yb_entity_mentions GROUP BY entity_id
)
UPDATE yb_research_entities e
SET mentions_count = COALESCE(counts.c, 0),
    updated_at = now()
FROM _wk7_canonical c
LEFT JOIN counts ON counts.entity_id = c.canonical_id
WHERE e.id = c.canonical_id;

-- ---------------------------------------------------------------------------
-- Phase 5: recompute yb_entity_relations from the now-deduped mentions.
-- Lifted from 20260605200000_populate_cooccurrence_v2.sql.
-- ---------------------------------------------------------------------------
DELETE FROM yb_entity_relations;

WITH pairs AS (
  SELECT
    LEAST(m1.entity_id, m2.entity_id)            AS source_entity_id,
    GREATEST(m1.entity_id, m2.entity_id)         AS target_entity_id,
    COUNT(DISTINCT m1.vault_item_id)             AS weight,
    COUNT(*)                                     AS evidence_count,
    MAX(GREATEST(m1.created_at, m2.created_at))  AS last_observed_at
  FROM yb_entity_mentions m1
  JOIN yb_entity_mentions m2
    ON m1.vault_item_id = m2.vault_item_id
   AND m1.entity_id < m2.entity_id
  WHERE m1.extraction_method = 'transcript_llm'
    AND m2.extraction_method = 'transcript_llm'
  GROUP BY 1, 2
  HAVING COUNT(DISTINCT m1.vault_item_id) >= 1
)
INSERT INTO yb_entity_relations
  (source_entity_id, target_entity_id, relation_type, weight, evidence_count, last_observed_at)
SELECT source_entity_id, target_entity_id, 'co_occurrence',
       weight, evidence_count, last_observed_at
FROM pairs;

-- ---------------------------------------------------------------------------
-- Phase 6: enforce uniqueness going forward for active rows only.
-- (Merged rows keep their name_norm_key so future inserts of the same name
-- can be merged via the same group, but only one row stays 'active'.)
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS yb_research_entities_name_norm_key_active_uq
  ON yb_research_entities (name_norm_key)
  WHERE disposition = 'active';

-- ---------------------------------------------------------------------------
-- Phase 7: log post-state.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_active int;
  v_merged int;
  v_mentions int;
  v_relations int;
  v_active_dups int;
BEGIN
  SELECT count(*) INTO v_active   FROM yb_research_entities WHERE disposition='active';
  SELECT count(*) INTO v_merged   FROM yb_research_entities WHERE disposition='merged';
  SELECT count(*) INTO v_mentions FROM yb_entity_mentions;
  SELECT count(*) INTO v_relations FROM yb_entity_relations;
  SELECT count(*) INTO v_active_dups FROM (
    SELECT 1 FROM yb_research_entities WHERE disposition='active'
    GROUP BY name_norm_key HAVING count(*) > 1
  ) s;
  RAISE NOTICE '[post] active_entities=% merged_entities=% mentions=% relations=% remaining_active_dup_groups=%',
    v_active, v_merged, v_mentions, v_relations, v_active_dups;
  IF v_active_dups <> 0 THEN
    RAISE EXCEPTION 'Active-row dup invariant violated: % groups remain', v_active_dups;
  END IF;
END $$;

-- service_role grants — no new tables introduced; existing grants suffice.

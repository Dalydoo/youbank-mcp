-- Week 3 PR 4: typed-edge co-occurrence relations between entities.
-- Auto-Research design listed this table as already-shipped — it isn't.
-- This migration mints it.
--
-- 'co_occurrence' is undirected; we enforce a canonical ordering
-- (source_id < target_id by uuid) so each unordered pair has exactly
-- one row. Typed relations (supports/contradicts/etc) land in a follow-up
-- aggregating per-relation_type from yb_entity_mentions.

CREATE TABLE yb_entity_relations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_entity_id uuid NOT NULL REFERENCES yb_research_entities(id) ON DELETE CASCADE,
  target_entity_id uuid NOT NULL REFERENCES yb_research_entities(id) ON DELETE CASCADE,
  relation_type    text NOT NULL,           -- 'co_occurrence' for PR 4
  weight           int  NOT NULL DEFAULT 1, -- count of distinct vault items backing this edge
  evidence_count   int  NOT NULL DEFAULT 1, -- distinct mention rows backing this edge
  last_observed_at timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT yb_entity_relations_uniq
    UNIQUE (source_entity_id, target_entity_id, relation_type),
  CONSTRAINT yb_entity_relations_ordered_pair
    CHECK (source_entity_id < target_entity_id)
);

CREATE INDEX idx_yb_entity_relations_source ON yb_entity_relations (source_entity_id);
CREATE INDEX idx_yb_entity_relations_target ON yb_entity_relations (target_entity_id);
CREATE INDEX idx_yb_entity_relations_weight ON yb_entity_relations (weight DESC);

ALTER TABLE yb_entity_relations DISABLE ROW LEVEL SECURITY;

-- Week 1 lesson 2: explicit GRANT for service_role on new tables.
GRANT SELECT, INSERT, UPDATE, DELETE ON yb_entity_relations TO service_role;

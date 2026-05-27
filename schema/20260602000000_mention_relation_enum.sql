-- Week 3 PR 1: Infinite Brain typed edges.
-- Add a 10-value enum for the relation a mention represents, plus a
-- nullable column on yb_entity_mentions. Existing 'link_pattern' rows
-- (deterministic URL match) leave the column NULL; Phase A2 'transcript_llm'
-- rows populate it. Partial index speeds the "show everything that contradicts X"
-- query path.

-- 1. Create the enum type
CREATE TYPE mention_relation AS ENUM (
  'supports',
  'contradicts',
  'depends_on',
  'similar_to',
  'inspired_by',
  'refines',
  'replaces',
  'implements',
  'references',
  'extends'
);

-- 2. Add the column to yb_entity_mentions. Nullable — existing rows
--    (extraction_method = 'link_pattern') don't have a relation; only
--    transcript_llm rows do.
ALTER TABLE yb_entity_mentions
  ADD COLUMN IF NOT EXISTS relation_type mention_relation;

-- 3. Index for "show me everything that contradicts X" queries.
--    Partial: only index rows where the relation is set.
CREATE INDEX IF NOT EXISTS idx_yb_entity_mentions_relation_type
  ON yb_entity_mentions (relation_type)
  WHERE relation_type IS NOT NULL;

-- service_role grants flow through from the existing yb_entity_mentions
-- table privileges (ALTER TABLE ... ADD COLUMN does not need a new GRANT).
-- Week 1 lesson 2 about service_role grants applies to *new tables*; this
-- migration only ALTERs an existing table.

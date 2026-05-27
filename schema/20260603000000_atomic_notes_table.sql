-- Week 3 PR 2: atomic notes table (Infinite Brain methodology).
-- Stores 50-300 word atomic claims per transcript chunk. Single table
-- covers multiple node sub-types via the atomic_note_type enum.

CREATE TYPE atomic_note_type AS ENUM (
  'claim',        -- speaker asserts something is true
  'decision',     -- speaker describes a choice they made
  'hypothesis',   -- speaker speculates / hedges
  'fact',         -- speaker cites an external fact (number, date, source)
  'question',     -- speaker poses an open question
  'playbook',     -- speaker prescribes a step / pattern
  'observation',  -- speaker reports something they noticed
  'pattern'       -- speaker identifies a recurring shape
);

CREATE TABLE yb_atomic_notes (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vault_item_id        uuid NOT NULL REFERENCES yb_vault_items(id) ON DELETE CASCADE,
  chunk_start_seconds  int  NOT NULL,
  chunk_end_seconds    int  NOT NULL,
  node_type            atomic_note_type NOT NULL DEFAULT 'claim',
  atomic_claim         text NOT NULL,
  -- Optional link back to a specific entity the claim is about. NULL is fine —
  -- many atomic notes are about ideas the speaker didn't tag as a named entity.
  entity_id            uuid REFERENCES yb_research_entities(id) ON DELETE SET NULL,
  -- Optional typed-edge relation this claim represents toward the entity.
  -- Uses the PR 1 enum.
  relation_type        mention_relation,
  confidence_score     real NOT NULL DEFAULT 0.5
    CHECK (confidence_score >= 0.0 AND confidence_score <= 1.0),
  model                text NOT NULL,            -- e.g. 'claude-haiku-4-5-20251001'
  created_at           timestamptz NOT NULL DEFAULT now(),

  -- A chunk + claim pair should be unique per item so re-running the
  -- extractor (idempotent) doesn't blow up the row count.
  CONSTRAINT yb_atomic_notes_uniq_chunk
    UNIQUE (vault_item_id, chunk_start_seconds, chunk_end_seconds, atomic_claim)
);

-- Indexes for the access patterns LENS will use
CREATE INDEX idx_yb_atomic_notes_vault_item ON yb_atomic_notes (vault_item_id);
CREATE INDEX idx_yb_atomic_notes_entity     ON yb_atomic_notes (entity_id)
  WHERE entity_id IS NOT NULL;
CREATE INDEX idx_yb_atomic_notes_relation   ON yb_atomic_notes (relation_type)
  WHERE relation_type IS NOT NULL;

-- Full-text search over the claim itself (analogue of yb_vault_items.search_vector).
-- english config matches existing tsvectors in the schema.
CREATE INDEX idx_yb_atomic_notes_claim_fts
  ON yb_atomic_notes
  USING GIN (to_tsvector('english', atomic_claim));

-- RLS disabled: this is a service-role-only table per Weeks 1-2 lessons.
-- (The event trigger from Week 1 PR 1 enables RLS by default; we explicitly
--  disable here because no public read path exists for atomic notes yet —
--  LENS reads via service_role.)
ALTER TABLE yb_atomic_notes DISABLE ROW LEVEL SECURITY;

-- Week 1 lesson 2: service_role grants are NOT automatic on new tables.
GRANT SELECT, INSERT, UPDATE, DELETE ON yb_atomic_notes TO service_role;

-- (No GRANT to anon/authenticated — intentional. If a future public read
--  path is needed, add it in a follow-up migration with RLS enabled.)

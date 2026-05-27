-- Research layer tables (originally applied as the
-- "2026-05-19_research_layer" migration via Supabase MCP apply_migration).
-- Not stored as a numbered migration file in the YouBank repo, so it's
-- preserved here for the public schema reproduction.
--
-- Tables created:
--   yb_user_projects      — project roster for fit scoring
--   yb_research_entities  — distinct researchable things (repos, tools, etc.)
--   yb_entity_mentions    — many-to-many between entities and vault items
--   yb_ai_usage           — token / cost tracking
--
-- The MCP server reads from yb_research_entities directly (entity-neighbours
-- tool joins it with yb_entity_relations). yb_entity_mentions is referenced
-- transitively because the mention_relation enum (a later migration) adds a
-- column to it.

-- ============================================================================
-- yb_user_projects: project roster used for fit scoring
-- ============================================================================
CREATE TABLE IF NOT EXISTS yb_user_projects (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL UNIQUE,
  description     text NOT NULL DEFAULT '',
  tech_stack      jsonb NOT NULL DEFAULT '[]'::jsonb,
  current_needs   text NOT NULL DEFAULT '',
  monetization_model text NOT NULL DEFAULT '',
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS yb_user_projects_active_idx
  ON yb_user_projects (is_active) WHERE is_active;

ALTER TABLE yb_user_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE yb_user_projects FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- yb_research_entities: one row per distinct researchable thing
-- ============================================================================
CREATE TABLE IF NOT EXISTS yb_research_entities (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                    text NOT NULL,
  entity_type             text NOT NULL CHECK (entity_type IN (
                            'repo','app','tool','technique','concept','paper','person','community'
                          )),
  canonical_url           text,
  normalized_key          text NOT NULL UNIQUE,

  what_it_does            text,
  research_summary        text,
  alternatives            jsonb NOT NULL DEFAULT '[]'::jsonb,
  strengths               jsonb NOT NULL DEFAULT '[]'::jsonb,
  watch_outs              jsonb NOT NULL DEFAULT '[]'::jsonb,

  github_metadata         jsonb,
  web_metadata            jsonb,

  monetization_score      int CHECK (monetization_score BETWEEN 1 AND 10),
  monetization_reasoning  text,
  fit_per_project         jsonb NOT NULL DEFAULT '{}'::jsonb,
  max_project_fit_score   int CHECK (max_project_fit_score BETWEEN 0 AND 10),
  knowledge_value         int CHECK (knowledge_value BETWEEN 1 AND 10),
  opportunity_score       numeric(4,2) GENERATED ALWAYS AS (
                            COALESCE(0.4 * monetization_score + 0.6 * max_project_fit_score, 0)
                          ) STORED,

  research_status         text NOT NULL DEFAULT 'pending' CHECK (research_status IN (
                            'pending_resolution','resolving','pending','researching','researched','failed'
                          )),
  scoring_status          text NOT NULL DEFAULT 'pending' CHECK (scoring_status IN (
                            'pending','scoring','scored','pending_rescore','failed'
                          )),
  last_researched_at      timestamptz,
  retry_count             int NOT NULL DEFAULT 0,
  last_error              text,

  mentions_count          int NOT NULL DEFAULT 0,
  is_hidden               boolean NOT NULL DEFAULT false,
  -- "disposition" column added by a later normalisation migration; the MCP
  -- server's entity-neighbours tool filters disposition='active'. Default to
  -- active for fresh inserts.
  disposition             text NOT NULL DEFAULT 'active' CHECK (disposition IN (
                            'active','merged','hidden'
                          )),

  search_vector           tsvector GENERATED ALWAYS AS (
                            setweight(to_tsvector('english', coalesce(name,'')), 'A') ||
                            setweight(to_tsvector('english', coalesce(what_it_does,'')), 'B') ||
                            setweight(to_tsvector('english', coalesce(research_summary,'')), 'C')
                          ) STORED,

  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS yb_research_entities_type_idx          ON yb_research_entities (entity_type);
CREATE INDEX IF NOT EXISTS yb_research_entities_research_status_idx ON yb_research_entities (research_status);
CREATE INDEX IF NOT EXISTS yb_research_entities_scoring_status_idx  ON yb_research_entities (scoring_status);
CREATE INDEX IF NOT EXISTS yb_research_entities_opportunity_idx   ON yb_research_entities (opportunity_score DESC);
CREATE INDEX IF NOT EXISTS yb_research_entities_mentions_idx      ON yb_research_entities (mentions_count DESC);
CREATE INDEX IF NOT EXISTS yb_research_entities_search_idx        ON yb_research_entities USING GIN (search_vector);
CREATE INDEX IF NOT EXISTS yb_research_entities_disposition_idx   ON yb_research_entities (disposition);

ALTER TABLE yb_research_entities ENABLE ROW LEVEL SECURITY;
ALTER TABLE yb_research_entities FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- yb_entity_mentions: many-to-many between entities and vault items
-- ============================================================================
CREATE TABLE IF NOT EXISTS yb_entity_mentions (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_id                   uuid NOT NULL REFERENCES yb_research_entities(id) ON DELETE CASCADE,
  vault_item_id               uuid NOT NULL REFERENCES yb_vault_items(id) ON DELETE CASCADE,
  mention_timestamp_seconds   int,
  mention_context             text,
  source_link                 text,
  extraction_method           text NOT NULL CHECK (extraction_method IN ('link_pattern','transcript_llm','merged')),
  confidence                  text NOT NULL DEFAULT 'high' CHECK (confidence IN ('high','medium','low')),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_id, vault_item_id)
);

CREATE INDEX IF NOT EXISTS yb_entity_mentions_entity_idx ON yb_entity_mentions (entity_id);
CREATE INDEX IF NOT EXISTS yb_entity_mentions_item_idx   ON yb_entity_mentions (vault_item_id);

ALTER TABLE yb_entity_mentions ENABLE ROW LEVEL SECURITY;
ALTER TABLE yb_entity_mentions FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- yb_ai_usage: cost / token tracking
-- ============================================================================
CREATE TABLE IF NOT EXISTS yb_ai_usage (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at         timestamptz NOT NULL DEFAULT now(),
  operation           text NOT NULL CHECK (operation IN (
                        'enrichment','extraction','synthesis','scoring','lens'
                      )),
  target_id           uuid,
  model               text NOT NULL,
  input_tokens        int NOT NULL DEFAULT 0,
  cache_read_tokens   int NOT NULL DEFAULT 0,
  cache_write_tokens  int NOT NULL DEFAULT 0,
  output_tokens       int NOT NULL DEFAULT 0,
  usd_cost            numeric(10,6) NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS yb_ai_usage_occurred_idx  ON yb_ai_usage (occurred_at DESC);
CREATE INDEX IF NOT EXISTS yb_ai_usage_operation_idx ON yb_ai_usage (operation);

ALTER TABLE yb_ai_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE yb_ai_usage FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- Trigger: keep yb_research_entities.mentions_count in sync
-- ============================================================================
CREATE OR REPLACE FUNCTION yb_research_entities_mentions_count_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE yb_research_entities
       SET mentions_count = mentions_count + 1,
           updated_at = now()
     WHERE id = NEW.entity_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE yb_research_entities
       SET mentions_count = GREATEST(mentions_count - 1, 0),
           updated_at = now()
     WHERE id = OLD.entity_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS yb_entity_mentions_count_trg ON yb_entity_mentions;
CREATE TRIGGER yb_entity_mentions_count_trg
  AFTER INSERT OR DELETE ON yb_entity_mentions
  FOR EACH ROW EXECUTE FUNCTION yb_research_entities_mentions_count_fn();

-- ============================================================================
-- Trigger: bump updated_at on row update
-- ============================================================================
CREATE OR REPLACE FUNCTION yb_touch_updated_at_fn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS yb_user_projects_touch_trg ON yb_user_projects;
CREATE TRIGGER yb_user_projects_touch_trg
  BEFORE UPDATE ON yb_user_projects
  FOR EACH ROW EXECUTE FUNCTION yb_touch_updated_at_fn();

DROP TRIGGER IF EXISTS yb_research_entities_touch_trg ON yb_research_entities;
CREATE TRIGGER yb_research_entities_touch_trg
  BEFORE UPDATE ON yb_research_entities
  FOR EACH ROW EXECUTE FUNCTION yb_touch_updated_at_fn();

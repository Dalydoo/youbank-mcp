-- YouBank Database Schema
-- Run this in Supabase SQL Editor

-- Core vault items table (source-agnostic)
CREATE TABLE yb_vault_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_type TEXT NOT NULL DEFAULT 'youtube',
  source_id TEXT NOT NULL,
  source_url TEXT NOT NULL,
  title TEXT NOT NULL,
  thumbnail_url TEXT,
  channel_name TEXT,
  channel_credibility TEXT DEFAULT 'unknown',
  duration_seconds INTEGER,
  published_at TIMESTAMPTZ,
  added_to_vault_at TIMESTAMPTZ DEFAULT NOW(),
  last_synced_at TIMESTAMPTZ DEFAULT NOW(),
  status TEXT NOT NULL DEFAULT 'saved',
  ai_category TEXT,
  ai_key_points JSONB DEFAULT '[]',
  ai_summary TEXT,
  ai_action_items JSONB DEFAULT '[]',
  ai_project_tags JSONB DEFAULT '[]',
  ai_relevance_score INTEGER DEFAULT 0,
  ai_channel_credibility TEXT,
  raw_description TEXT,
  raw_transcript TEXT,
  extracted_links JSONB DEFAULT '[]',
  personal_note TEXT,
  duplicate_of UUID REFERENCES yb_vault_items(id),
  enrichment_status TEXT DEFAULT 'pending',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Source connectors registry
CREATE TABLE yb_connectors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  is_active BOOLEAN DEFAULT true,
  last_sync_at TIMESTAMPTZ,
  total_items_synced INTEGER DEFAULT 0,
  config JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sync log
CREATE TABLE yb_sync_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  connector_id UUID REFERENCES yb_connectors(id),
  sync_type TEXT NOT NULL,
  started_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  items_found INTEGER DEFAULT 0,
  items_new INTEGER DEFAULT 0,
  items_skipped INTEGER DEFAULT 0,
  items_failed INTEGER DEFAULT 0,
  date_from TIMESTAMPTZ,
  date_to TIMESTAMPTZ,
  status TEXT DEFAULT 'running',
  error_message TEXT
);

-- LENS AI conversation history
CREATE TABLE yb_lens_conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  cited_item_ids JSONB DEFAULT '[]',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_yb_vault_source_id ON yb_vault_items(source_id);
CREATE INDEX idx_yb_vault_status ON yb_vault_items(status);
CREATE INDEX idx_yb_vault_category ON yb_vault_items(ai_category);
CREATE INDEX idx_yb_vault_added ON yb_vault_items(added_to_vault_at DESC);
CREATE INDEX idx_yb_vault_enrichment ON yb_vault_items(enrichment_status);
CREATE INDEX idx_yb_vault_source_type ON yb_vault_items(source_type);

-- Full text search
ALTER TABLE yb_vault_items ADD COLUMN search_vector TSVECTOR;
CREATE INDEX idx_yb_vault_fts ON yb_vault_items USING GIN(search_vector);

-- Search vector trigger
CREATE OR REPLACE FUNCTION yb_update_search_vector()
RETURNS TRIGGER AS $$
BEGIN
  NEW.search_vector :=
    setweight(to_tsvector('english', COALESCE(NEW.title, '')), 'A') ||
    setweight(to_tsvector('english', COALESCE(NEW.ai_summary, '')), 'B') ||
    setweight(to_tsvector('english', COALESCE(NEW.ai_category, '')), 'C') ||
    setweight(to_tsvector('english', COALESCE(NEW.channel_name, '')), 'D');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER yb_vault_search_update
  BEFORE INSERT OR UPDATE ON yb_vault_items
  FOR EACH ROW EXECUTE FUNCTION yb_update_search_vector();

-- Updated_at trigger
CREATE OR REPLACE FUNCTION yb_update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER yb_vault_updated_at
  BEFORE UPDATE ON yb_vault_items
  FOR EACH ROW EXECUTE FUNCTION yb_update_updated_at();

-- Seed the YouTube connector
INSERT INTO yb_connectors (name, type, config) VALUES
('YouTube Watch Later', 'youtube', '{"playlist_id": "WL"}');

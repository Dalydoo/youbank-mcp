-- Add 384-dim embedding columns to vault items and research entities.
-- Tracking columns let the backfill drain pending rows incrementally.
-- HNSW indexes use cosine ops (default for normalised MiniLM embeddings).
-- Partial pending indexes accelerate the backfill drain query.

ALTER TABLE yb_vault_items
  ADD COLUMN IF NOT EXISTS embedding vector(384),
  ADD COLUMN IF NOT EXISTS embedding_status text NOT NULL DEFAULT 'pending'
    CHECK (embedding_status IN ('pending','embedded','failed')),
  ADD COLUMN IF NOT EXISTS embedding_model text,
  ADD COLUMN IF NOT EXISTS embedded_at timestamptz;

ALTER TABLE yb_research_entities
  ADD COLUMN IF NOT EXISTS embedding vector(384),
  ADD COLUMN IF NOT EXISTS embedding_status text NOT NULL DEFAULT 'pending'
    CHECK (embedding_status IN ('pending','embedded','failed')),
  ADD COLUMN IF NOT EXISTS embedding_model text,
  ADD COLUMN IF NOT EXISTS embedded_at timestamptz;

-- HNSW cosine indexes (m=16, ef_construction=64 are pgvector defaults).
CREATE INDEX IF NOT EXISTS idx_yb_vault_items_embedding_hnsw
  ON yb_vault_items USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

CREATE INDEX IF NOT EXISTS idx_yb_research_entities_embedding_hnsw
  ON yb_research_entities USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- Partial indexes for the backfill drain (pending rows only).
CREATE INDEX IF NOT EXISTS idx_yb_vault_items_embedding_pending
  ON yb_vault_items (embedding_status) WHERE embedding_status = 'pending';
CREATE INDEX IF NOT EXISTS idx_yb_research_entities_embedding_pending
  ON yb_research_entities (embedding_status) WHERE embedding_status = 'pending';

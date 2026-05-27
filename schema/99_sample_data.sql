-- Optional sample data so the youbank-mcp tools return non-empty results
-- against a fresh schema. Apply AFTER all the numbered migrations.
--
-- Idempotent: uses ON CONFLICT DO NOTHING keyed on stable UUIDs.
--
-- Creates:
--   2 vault items   (with raw_transcript so transcript FTS has content)
--   4 atomic notes  (claims tied to each item)
--   3 entities      (one shared between the two items)
--   1 entity relation (the co-occurrence edge)
--   1 user highlight on item 1
--
-- After applying, refresh the materialised view so vault_stats reflects the
-- new rows immediately (the trigger fires on yb_vault_items writes, but
-- safer to force it):
--   SELECT refresh_yb_vault_stats_mv();

-- Stable UUIDs so re-applies are idempotent and cross-references work.
INSERT INTO yb_vault_items (
  id, source_type, source_id, source_url, title, channel_name,
  ai_category, ai_summary, ai_key_points, ai_relevance_score,
  raw_transcript, enrichment_status, status, embedding_status
) VALUES (
  '11111111-1111-1111-1111-111111111111',
  'youtube', 'dQw4w9WgXcQ',
  'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
  'Sample Video 1: Building Agent Memory Systems',
  'Sample Channel',
  'AI & Tech',
  'A primer on persistent memory for autonomous agents, covering vector stores, hybrid retrieval, and the case for per-user knowledge graphs.',
  '["Hybrid retrieval beats pure cosine for long-tail recall", "Per-agent identity matters as much as memory shape", "RRF k=60 is a strong default"]'::jsonb,
  85,
  'Welcome to this video on agent memory systems. Today we are going to talk about how AI agents can maintain persistent state across sessions using vector stores and knowledge graphs. The key insight is that hybrid retrieval combining BM25 and cosine similarity outperforms either approach alone.',
  'complete', 'saved', 'pending'
), (
  '22222222-2222-2222-2222-222222222222',
  'article', 'sample-article-2',
  'https://example.com/articles/knowledge-graphs-101',
  'Sample Article 2: Why Knowledge Graphs Beat Plain Vector Search',
  'Example Blog',
  'AI & Tech',
  'Argues that entity-aware retrieval surfaces context that raw vector similarity loses, with worked examples from a personal-vault use case.',
  '["Entities are the unit of recall", "Co-occurrence edges encode implicit relationships"]'::jsonb,
  78,
  'Vector search is great for semantic similarity but loses structured relationships between entities. When you query for agent memory, you want results connected to relevant tools, papers, and people — not just text that sounds similar.',
  'complete', 'saved', 'pending'
)
ON CONFLICT (id) DO NOTHING;

-- Atomic notes — single-sentence claims with transcript timestamps.
INSERT INTO yb_atomic_notes (
  id, vault_item_id, chunk_start_seconds, chunk_end_seconds,
  node_type, atomic_claim, confidence_score, model
) VALUES (
  '33333333-3333-3333-3333-333333331111',
  '11111111-1111-1111-1111-111111111111',
  0, 30, 'claim',
  'Hybrid retrieval combining BM25 and cosine similarity outperforms either approach alone for agent memory recall.',
  0.9, 'sample-data'
), (
  '33333333-3333-3333-3333-333333331112',
  '11111111-1111-1111-1111-111111111111',
  30, 60, 'fact',
  'Reciprocal Rank Fusion with k=60 is a strong default per Cormack et al. 2009.',
  0.95, 'sample-data'
), (
  '33333333-3333-3333-3333-333333332221',
  '22222222-2222-2222-2222-222222222222',
  0, 30, 'observation',
  'Entity-aware retrieval surfaces context that raw vector similarity loses.',
  0.85, 'sample-data'
), (
  '33333333-3333-3333-3333-333333332222',
  '22222222-2222-2222-2222-222222222222',
  30, 60, 'pattern',
  'Co-occurrence edges between entities encode implicit relationships that humans recognise but vectors miss.',
  0.8, 'sample-data'
)
ON CONFLICT (vault_item_id, chunk_start_seconds, chunk_end_seconds, atomic_claim) DO NOTHING;

-- Entities — one shared between the two vault items so entity_neighbours has data.
INSERT INTO yb_research_entities (
  id, name, entity_type, normalized_key, what_it_does,
  research_status, scoring_status, disposition
) VALUES (
  '44444444-4444-4444-4444-444444444441',
  'Agent Memory',
  'concept',
  'concept:agent-memory',
  'Persistent state for autonomous AI agents across sessions.',
  'researched', 'scored', 'active'
), (
  '44444444-4444-4444-4444-444444444442',
  'Reciprocal Rank Fusion',
  'technique',
  'technique:reciprocal-rank-fusion',
  'Score-fusion algorithm that combines multiple ranked lists by summing 1/(k+rank).',
  'researched', 'scored', 'active'
), (
  '44444444-4444-4444-4444-444444444443',
  'Knowledge Graphs',
  'concept',
  'concept:knowledge-graphs',
  'Entity-relation graph data structures for structured retrieval.',
  'researched', 'scored', 'active'
)
ON CONFLICT (normalized_key) DO NOTHING;

-- Entity mentions — link entities to the vault items they appear in.
-- Both items mention Agent Memory, so it co-occurs with both Knowledge Graphs and RRF.
INSERT INTO yb_entity_mentions (
  id, entity_id, vault_item_id, mention_context, extraction_method, confidence
) VALUES (
  '55555555-5555-5555-5555-555555555551',
  '44444444-4444-4444-4444-444444444441',
  '11111111-1111-1111-1111-111111111111',
  'agent memory systems', 'transcript_llm', 'high'
), (
  '55555555-5555-5555-5555-555555555552',
  '44444444-4444-4444-4444-444444444442',
  '11111111-1111-1111-1111-111111111111',
  'Reciprocal Rank Fusion with k=60', 'transcript_llm', 'high'
), (
  '55555555-5555-5555-5555-555555555553',
  '44444444-4444-4444-4444-444444444441',
  '22222222-2222-2222-2222-222222222222',
  'agent memory', 'transcript_llm', 'high'
), (
  '55555555-5555-5555-5555-555555555554',
  '44444444-4444-4444-4444-444444444443',
  '22222222-2222-2222-2222-222222222222',
  'knowledge graphs', 'transcript_llm', 'high'
)
ON CONFLICT (entity_id, vault_item_id) DO NOTHING;

-- Entity relations — canonical-ordered pair (uuid sort).
-- Agent Memory (4441) co-occurs with Knowledge Graphs (4443) because both
-- entities are mentioned in vault item 2222. Source must be the lexicographically
-- smaller UUID (4441 < 4443).
INSERT INTO yb_entity_relations (
  id, source_entity_id, target_entity_id, relation_type, weight, evidence_count
) VALUES (
  '66666666-6666-6666-6666-666666666661',
  '44444444-4444-4444-4444-444444444441',
  '44444444-4444-4444-4444-444444444442',
  'co_occurrence', 1, 1
), (
  '66666666-6666-6666-6666-666666666662',
  '44444444-4444-4444-4444-444444444441',
  '44444444-4444-4444-4444-444444444443',
  'co_occurrence', 1, 1
)
ON CONFLICT (source_entity_id, target_entity_id, relation_type) DO NOTHING;

-- One user highlight on item 1.
INSERT INTO yb_highlights (
  id, item_id, segment_index, segment_start_s, segment_end_s, segment_text, note
) VALUES (
  '77777777-7777-7777-7777-777777777771',
  '11111111-1111-1111-1111-111111111111',
  0, 0.000, 30.000,
  'Hybrid retrieval combining BM25 and cosine similarity outperforms either approach alone.',
  'Anchor the design around this finding.'
)
ON CONFLICT (item_id, segment_index) DO NOTHING;

-- Refresh the materialised view so vault_stats reflects the seeded rows.
SELECT refresh_yb_vault_stats_mv();

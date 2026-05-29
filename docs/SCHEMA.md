# Schema Reference

This document describes the tables and functions that the youbank-mcp tools
read. Apply the SQL files in [`../schema`](../schema) to a Postgres 15+
database with `vector` and `pgcrypto` extensions to reproduce.

## Tables read by MCP tools

### `yb_vault_items`

The core artefact table. One row per saved video, article, podcast, or other
source. Read by `youbank_get_vault_item`, `youbank_hybrid_search`,
`youbank_vault_stats`, and joined by `youbank_get_highlights`.

Key columns: `id` (uuid PK), `source_type`, `source_id`, `source_url`,
`title`, `channel_name`, `published_at`, `status`, `ai_category`,
`ai_summary`, `ai_key_points` (jsonb), `ai_relevance_score`, `raw_transcript`,
`extracted_links` (jsonb), `enrichment_status`, `embedding` (vector(384),
HNSW-indexed), `embedding_status`, `search_vector` (tsvector, metadata FTS),
`transcript_tsv` (tsvector, transcript FTS — generated column).

### `yb_atomic_notes`

Atomic single-sentence claims extracted per transcript chunk. One row per
(item, chunk-range, claim) triple. Read by `youbank_get_atomic_notes` and
fed into `youbank_hybrid_search` as one of four retrieval sources.

Key columns: `id`, `vault_item_id` (FK → yb_vault_items), `chunk_start_seconds`,
`chunk_end_seconds`, `node_type` (atomic_note_type enum: claim/decision/
hypothesis/fact/question/playbook/observation/pattern), `atomic_claim`,
`entity_id` (optional FK → yb_research_entities), `relation_type` (optional
mention_relation enum), `confidence_score` (real 0.0–1.0), `model`,
`atomic_claim_tsv` (tsvector, generated column).

### `yb_research_entities`

One row per distinct researchable thing (repo, tool, technique, paper, person,
etc.). Read by `youbank_entity_neighbours`.

Key columns: `id`, `name`, `entity_type`, `normalized_key` (unique),
`research_summary`, `disposition` (`active` / `merged` / `hidden`).

### `yb_entity_relations`

Undirected co-occurrence edges between entity pairs. Pairs are stored in
canonical order (`source_entity_id < target_entity_id`). Read by
`youbank_entity_neighbours`.

Columns: `source_entity_id` (lexicographically smaller), `target_entity_id`
(larger), `relation_type` (`co_occurrence` in v1), `weight` (count of distinct
vault items backing the edge), `evidence_count` (count of distinct mention
rows).

### `yb_highlights`

User-curated transcript segments — the passages the human explicitly flagged
as important. Read by `youbank_get_highlights`.

Columns: `id`, `item_id` (FK → yb_vault_items), `segment_index` (unique per
item), `segment_start_s` / `segment_end_s` (numeric seconds), `segment_text`,
`note` (optional annotation).

### `yb_patterns`

Auto-synthesised patterns lifted from clusters of atomic notes (≥3 occurrences across ≥2 distinct vault items). Read by `youbank_get_patterns`. Populated by the YouBank-side clustering job (`scripts/cluster-patterns.mjs`).

Columns: `id` (uuid PK), `pattern_text` (canonical statement — v1 is the centroid note's verbatim text), `pattern_type` (atomic_note_type enum), `occurrence_count` (cluster size), `source_diversity` (distinct items), `avg_confidence` (mean of source notes' confidence_score), `source_note_ids` (uuid[] — provenance), `source_item_ids` (uuid[] — denorm), `model` (v2 synthesiser, NULL in v1), `embedding` (384-dim MiniLM), `first_observed_at`, `last_reinforced_at`, `status` (`active`/`stale`/`merged`/`hidden`).

The `yb_patterns_search(query_embedding, min_cosine, top_n)` function exposes cosine retrieval for the MCP tool.

## Materialised view

### `yb_vault_stats_mv`

Singleton row (`id = 1`) holding precomputed vault stats. Read by
`youbank_vault_stats`. Refreshed by a statement-level trigger on every
`yb_vault_items` write, plus a `refresh_yb_vault_stats_mv()` function for
manual refreshes.

Exposed columns: `total_items`, `enriched_items`, `atomic_notes`,
`active_entities` (plus YouBank-internal columns the MCP server doesn't read).

## Functions

### `yb_hybrid_search(query_text, query_embedding, k_const, top_n)`

Returns `setof (vault_item_id, rrf_score, hit_sources, atomic_note_ids)`.

Reciprocal Rank Fusion across four sources:

1. Metadata FTS over `yb_vault_items.search_vector`
2. Transcript FTS over `yb_vault_items.transcript_tsv`
3. Vector kNN over `yb_vault_items.embedding` via HNSW (cosine)
4. Atomic-note FTS over `yb_atomic_notes.atomic_claim_tsv`, rolled up to
   parent vault item

Each sub-source caps at top-50; RRF sums `1 / (k_const + rank)`; returns
`top_n` rows ordered by `rrf_score DESC`.

- `query_text` — `plainto_tsquery('english', …)`-compatible string
- `query_embedding` — 384-dim vector matching the HNSW index
- `k_const` — RRF constant (default 60 per Cormack et al. 2009)
- `top_n` — result cap (default 20)

Grant: `service_role` only.

### `refresh_yb_vault_stats_mv()`

`SECURITY DEFINER` function that does `REFRESH MATERIALIZED VIEW
yb_vault_stats_mv`. Called by the trigger above and available for manual
invocation after bulk inserts that bypass triggers.

## Schema dependency map

```
yb_vault_items ◀─┬─ yb_atomic_notes
                 ├─ yb_entity_mentions
                 ├─ yb_highlights
                 └─ yb_vault_stats_mv (materialised)

yb_research_entities ◀─┬─ yb_atomic_notes (entity_id, optional)
                       ├─ yb_entity_mentions (entity_id)
                       └─ yb_entity_relations (source_entity_id, target_entity_id)

yb_hybrid_search()  ─reads─▶  yb_vault_items, yb_atomic_notes
```

## What's NOT in this MCP

The companion YouBank app populates these tables but this MCP server doesn't
expose write paths for them. If you want to drive data into the schema, you'll
need your own ingest layer that:

1. Inserts source rows into `yb_vault_items`
2. Generates 384-dim embeddings (MiniLM-L6-v2) and populates `embedding`
3. Chunks transcripts and asks an LLM to extract atomic claims into
   `yb_atomic_notes`
4. Resolves named entities into `yb_research_entities` and creates
   `yb_entity_mentions` rows
5. Periodically rebuilds `yb_entity_relations` from co-occurrence
6. Lets users flag transcript segments into `yb_highlights`

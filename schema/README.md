# Schema

Apply these files **in numeric order** to a fresh Postgres 15+ project with
the `vector` and `pgcrypto` extensions available. Tested against Supabase.

| File | What it creates |
|---|---|
| `00_base_tables.sql` | `yb_vault_items` + supporting tables (connectors, sync log, lens conversations), FTS triggers |
| `01_research_layer.sql` | `yb_research_entities`, `yb_entity_mentions`, `yb_user_projects`, `yb_ai_usage`, trigger functions |
| `20260521000000_*` … `20260702000000_*` | Numbered Supabase migrations — pgvector + embeddings, atomic notes, entity relations, highlights, hybrid-search RPC, vault-stats MV, entity normalisation |
| `99_sample_data.sql` | Two sample vault items + atomic notes + entities + a highlight, so the MCP server tools return non-empty results for smoke testing |

## Quickest path (Supabase)

1. Open the Supabase SQL Editor for a fresh project
2. Paste each file (in order) into a new query, run
3. Optionally run `99_sample_data.sql` to seed sample rows

## Quickest path (psql)

```bash
# Set DATABASE_URL to your Postgres connection string first
for f in $(ls *.sql | sort); do
  echo "▶ Applying $f"
  psql "$DATABASE_URL" -f "$f" || break
done
```

## Caveats

- `00_base_tables.sql` is the original schema from before YouBank's migrations
  were tracked. A handful of columns are added later by numbered migrations
  (`embedding`, `transcript_tsv`, etc.) — that's expected and idempotent.
- `01_research_layer.sql` reconstructs the schema from the original plan doc
  for `2026-05-19_research_layer`, which was applied via Supabase MCP and not
  checked into the YouBank repo as a numbered migration. Idempotent
  (`CREATE TABLE IF NOT EXISTS`, `DROP TRIGGER IF EXISTS … CREATE TRIGGER`).
- A few numbered migrations create tables the MCP server doesn't read
  (`yb_ai_batches`, `yb_social_cookies`, `yb_digest_runs`, `yb_audio_overviews`).
  They're included so the schema is internally consistent — feel free to skip
  them.
- The `populate_cooccurrence_*` migrations populate `yb_entity_relations`
  from `yb_entity_mentions`. On an empty database they are no-ops; safe to
  apply.

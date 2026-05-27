# youbank-mcp

A read-only [Model Context Protocol](https://modelcontextprotocol.io) server
that exposes a personal knowledge vault to AI agents — hybrid search, atomic
claims, entity graph, user-curated highlights, and vault stats — over a
documented Supabase/Postgres schema.

This is the MCP layer from **YouBank**, Daz Alderson's personal AI vault for
YouTube + article + Reddit + podcast ingestion. The vault itself (Next.js
app, enrichment pipeline, sync jobs) lives in a private repo. This MCP server
is published as:

1. The **interface** any MCP client (Claude Desktop, Cursor, Cline, Claude
   Code, etc.) uses to read Daz's vault, and
2. An **open-source reference** for anyone building their own personal-vault
   MCP — the schema, retrieval function, and tool surface are documented in
   full.

> **Heads-up:** this server reads from a populated Postgres schema. The write
> path (ingestion, enrichment, embedding, atomic-note generation, entity
> extraction, co-occurrence) lives in the companion YouBank app, which is not
> open-source. If you want a working install with non-empty results, you'll
> need to either (a) point this server at a Supabase project where you've
> applied [`schema/`](./schema) and populated rows yourself, or (b) seed it
> with [`schema/99_sample_data.sql`](./schema/99_sample_data.sql) to verify
> the tools work end-to-end. See [docs/DEPLOY.md](./docs/DEPLOY.md).

## Tools

| Name | Purpose | Inputs |
|---|---|---|
| `youbank_hybrid_search` | BM25 + cosine + RRF fusion over vault items + atomic notes. The primary "find stuff" tool. | `query`, optional `top_n` (max 25) |
| `youbank_get_vault_item` | Full row for one vault item by UUID. Transcript, key points, enrichment metadata. | `item_id` (UUID) |
| `youbank_get_atomic_notes` | All atomic claims extracted from one item — single-sentence factual statements with `[@<seconds>s]` source-timestamp pointers. | `vault_item_id` (UUID) |
| `youbank_entity_neighbours` | Top co-occurring entities for a named entity, ranked by co-occurrence weight. | `entity_name`, optional `top_n` (max 25) |
| `youbank_get_highlights` | User-curated transcript-segment highlights — the passages the human explicitly flagged as important. | optional `item_id`, `category`, `since` (ISO), `limit` (max 200) |
| `youbank_vault_stats` | Singleton stats row from a materialised view — total items, enriched count, atomic-note count, active-entity count. | (none) |

All tools are read-only. There are no write tools.

## Install (for use with Claude Desktop / Cursor / Cline)

### 1. Provision Postgres

Apply the schema from [`schema/`](./schema) to a Supabase project (or any
Postgres 15+ with the `vector` and `pgcrypto` extensions available):

```bash
# Concat the schema files and run them in order:
cat schema/*.sql | psql "$DATABASE_URL"
```

Or via the Supabase SQL Editor: paste each file in order, execute.

To verify the tools return non-empty results before pointing an MCP client at
the server, also run [`schema/99_sample_data.sql`](./schema/99_sample_data.sql)
to seed two sample vault items, atomic notes, entities, and a highlight.

### 2. Build the server

```bash
git clone https://github.com/Dalydoo/youbank-mcp.git
cd youbank-mcp
npm install
npm run build
```

This produces `dist/index.js` — the stdio MCP binary.

### 3. Smoke-test

```bash
export YOUBANK_SUPABASE_URL="https://<project-ref>.supabase.co"
export YOUBANK_SUPABASE_SERVICE_ROLE_KEY="<service-role-key>"
npm run smoke
```

Expected output:

```
smoke: initialize OK
smoke: tools/list OK (6 tools: youbank_hybrid_search, youbank_get_vault_item, ...)
smoke: tools/call youbank_hybrid_search OK
smoke: tools/call youbank_vault_stats OK
smoke: OK
```

If you applied `99_sample_data.sql`, `youbank_hybrid_search` will return the
two seed items; `youbank_vault_stats` will report non-zero counts.

### 4. Wire into your MCP client

**Claude Desktop** — edit `claude_desktop_config.json`:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`

```jsonc
{
  "mcpServers": {
    "youbank": {
      "command": "node",
      "args": ["/absolute/path/to/youbank-mcp/dist/index.js"],
      "env": {
        "YOUBANK_SUPABASE_URL": "https://<project-ref>.supabase.co",
        "YOUBANK_SUPABASE_SERVICE_ROLE_KEY": "<service-role-key>"
      }
    }
  }
}
```

Restart Claude Desktop. In a new chat, ask **"what youbank tools do you
have?"** — Claude should list all six `youbank_*` tools.

**Cursor / Cline / Claude Code** — same shape, written to the host's MCP
config (`.cursor/mcp.json`, `.cline/mcp_settings.json`, or `.mcp.json`).

## Environment variables

| Var | Required | Fallback | Purpose |
|---|---|---|---|
| `YOUBANK_SUPABASE_URL` | yes | `NEXT_PUBLIC_SUPABASE_URL` | Project URL of the Supabase/Postgres backend |
| `YOUBANK_SUPABASE_SERVICE_ROLE_KEY` | yes | `SUPABASE_SERVICE_ROLE_KEY` | Service-role key — required because `yb_atomic_notes` / `yb_entity_relations` are service-role-only by design |

The server has no API keys of its own and makes no outbound HTTP calls beyond
the configured Supabase project. The hybrid-search RPC uses a local 384-dim
embedder ([`@xenova/transformers`](https://www.npmjs.com/package/@xenova/transformers)
running MiniLM-L6-v2) — first call downloads ~46MB to `~/.cache/transformers`,
subsequent calls inference in ~50-100ms.

## Architecture

```
┌────────────────────┐    stdio JSON-RPC    ┌────────────────────┐
│  MCP client        │  ───────────────▶    │  youbank-mcp       │
│  (Claude Desktop,  │                      │  ─ index.ts        │
│   Cursor, Cline,   │  ◀───────────────    │  ─ tools/*.ts      │
│   Claude Code)     │   tools, results     │  ─ db/*.ts         │
└────────────────────┘                      └──────────┬─────────┘
                                                       │
                                                       │ supabase-js
                                                       ▼
                                            ┌─────────────────────┐
                                            │  Supabase / Postgres│
                                            │  ─ yb_vault_items   │
                                            │  ─ yb_atomic_notes  │
                                            │  ─ yb_entity_*      │
                                            │  ─ yb_highlights    │
                                            │  ─ yb_vault_stats_mv│
                                            │  ─ yb_hybrid_search │
                                            └─────────────────────┘
```

Hybrid search fuses four candidate sources via Reciprocal Rank Fusion (RRF,
k=60 per Cormack et al. 2009):

1. **Metadata FTS** — `yb_vault_items.search_vector` (title + summary +
   category + channel)
2. **Transcript FTS** — `yb_vault_items.transcript_tsv`
3. **Vault-item cosine** — `yb_vault_items.embedding` via pgvector HNSW
4. **Atomic-note FTS** — `yb_atomic_notes.atomic_claim_tsv`, rolled up to
   parent vault item

Each sub-source caps at top-50; RRF fuses, returns top-N.

## Schema overview

See [`docs/SCHEMA.md`](./docs/SCHEMA.md) for the full table reference. Quick
map of what each tool reads:

| Tool | Tables / Functions |
|---|---|
| `youbank_hybrid_search` | `yb_hybrid_search()` RPC → `yb_vault_items` |
| `youbank_get_vault_item` | `yb_vault_items` (full row) |
| `youbank_get_atomic_notes` | `yb_atomic_notes` |
| `youbank_entity_neighbours` | `yb_research_entities`, `yb_entity_relations` |
| `youbank_get_highlights` | `yb_highlights` joined to `yb_vault_items` |
| `youbank_vault_stats` | `yb_vault_stats_mv` (materialised view) |

## Cost model

MCP-spawned Claude Desktop / Cursor / Cline calls bill against the host
client's plan, not against this server. **This server has zero marginal API
spend** — it issues no outbound LLM calls. The only outbound network traffic
is Supabase REST calls plus the one-time `~46MB` MiniLM model download to
`~/.cache/transformers`.

## Status

- **v0.1.0** — six read-only tools, stdio transport.
- Companion app (YouBank vault) is private; the schema and tool interface
  are open.
- No write tools planned for v0.x — write paths belong in the companion app
  where enrichment and validation happens.

## License

[MIT](./LICENSE) © Daz Alderson

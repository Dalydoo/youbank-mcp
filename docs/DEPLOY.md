# Deployment Guide

This walks through the full path from "I have nothing" to "Claude Desktop is
calling youbank tools and getting real results."

## Prerequisites

- **Node.js 20+**, with `npm` available
- A **Postgres 15+** database with the `vector` extension enabled.
  [Supabase](https://supabase.com) is the path of least resistance — the free
  tier covers a single-user MCP comfortably. Self-hosted Postgres works too;
  just install pgvector.
- An **MCP client** to test against. Free-tier options:
  - [Claude Desktop](https://claude.ai/download)
  - [Cursor](https://cursor.sh)
  - [Cline](https://cline.bot) (VS Code extension)
  - [Claude Code](https://claude.com/claude-code)

## Step 1 — Provision the database

### Option A: Supabase (recommended)

1. Sign in at [supabase.com](https://supabase.com), create a new project. Wait
   for it to spin up (~2 min).
2. Open the **SQL Editor** in the Supabase dashboard.
3. In your repo clone, schema files live in [`../schema`](../schema). Open
   each `.sql` file in numeric order:
   - `00_base_tables.sql`
   - `01_research_layer.sql`
   - `20260521000000_revoke_rls_auto_enable.sql` (through 2026070...)
   - Optionally: `99_sample_data.sql` (seed data so tools return non-empty
     results)
4. For each file: copy contents → paste into SQL Editor → "Run".
5. Grab your project credentials from **Project Settings → API**:
   - `URL` (looks like `https://abc123xyz.supabase.co`)
   - `service_role` key (NOT the anon key — service-role is required because
     several tables are service-role-only by design)

### Option B: Self-hosted Postgres

```bash
# 1. Ensure pgvector + pgcrypto are installed (most modern distros include both)
# 2. Apply schema in order:
cd schema
for f in $(ls *.sql | sort); do
  echo "▶ $f"
  psql "$DATABASE_URL" -f "$f" || break
done
```

## Step 2 — Build the MCP server

```bash
git clone https://github.com/Dalydoo/youbank-mcp.git
cd youbank-mcp
npm install
npm run build
```

You should see `dist/index.js` after the build.

## Step 3 — Smoke test

```bash
export YOUBANK_SUPABASE_URL="https://<your-project-ref>.supabase.co"
export YOUBANK_SUPABASE_SERVICE_ROLE_KEY="<your-service-role-key>"
npm run smoke
```

Expected:

```
smoke: initialize OK
smoke: tools/list OK (6 tools: youbank_hybrid_search, youbank_get_vault_item, ...)
smoke: tools/call youbank_hybrid_search OK
smoke: tools/call youbank_vault_stats OK
smoke: OK
```

If you applied `99_sample_data.sql`, hybrid_search returns two seeded items
and vault_stats reports non-zero counts. If you didn't, the tools still
respond OK but return "No matches" / zero counts — which is correct
behaviour for an empty database.

### First-run latency

The embedder downloads ~46MB of MiniLM-L6-v2 weights on first call, cached to
`~/.cache/transformers`. Cold start ~3-5s; subsequent calls ~50-100ms. The
server is a long-lived child process — the cold-start happens once per MCP
client session.

## Step 4 — Wire into Claude Desktop

Edit your `claude_desktop_config.json`:

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

Restart Claude Desktop. In a new chat:

> What YouBank tools do you have?

Claude should respond with the six `youbank_*` tools. Then try:

> Search youbank for "agent memory" and show me the top result.

Claude will invoke `youbank_hybrid_search`, then `youbank_get_vault_item` on
the top hit.

## Step 5 — Wire into other clients

### Cursor

`~/.cursor/mcp.json` (or per-project `.mcp.json`):

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

### Cline (VS Code extension)

In Cline settings, **MCP Servers** → **Edit MCP Settings** → paste:

```jsonc
{
  "mcpServers": {
    "youbank": {
      "command": "node",
      "args": ["/absolute/path/to/youbank-mcp/dist/index.js"],
      "env": {
        "YOUBANK_SUPABASE_URL": "https://<project-ref>.supabase.co",
        "YOUBANK_SUPABASE_SERVICE_ROLE_KEY": "<service-role-key>"
      },
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

### Claude Code

```bash
claude mcp add youbank node /absolute/path/to/youbank-mcp/dist/index.js \
  --env YOUBANK_SUPABASE_URL=https://<project-ref>.supabase.co \
  --env YOUBANK_SUPABASE_SERVICE_ROLE_KEY=<service-role-key>
```

## Troubleshooting

### "permission denied for table yb_atomic_notes"

You're connecting with the anon key, not the service-role key. The MCP server
needs service-role because `yb_atomic_notes` and `yb_entity_relations` are
service-role-only by design (no public read path).

### "Empty vault_stats" but data exists

The materialised view refreshes on `yb_vault_items` writes. After bulk
inserts that bypass triggers (e.g. seed data via `INSERT … ON CONFLICT`), run:

```sql
SELECT refresh_yb_vault_stats_mv();
```

### "tools/list returned 5 tools" (or wrong number)

You probably built against a stale checkout. Re-clone and `npm run build`.

### Hybrid search returns nothing on a populated DB

`yb_hybrid_search()` requires that `yb_vault_items.transcript_tsv` and
`yb_atomic_notes.atomic_claim_tsv` exist as generated columns. These are
added by the `yb_hybrid_search_perf_fixes` migration — verify it was applied:

```sql
SELECT column_name FROM information_schema.columns
WHERE table_name = 'yb_vault_items' AND column_name = 'transcript_tsv';
```

Should return one row. If not, re-apply that migration.

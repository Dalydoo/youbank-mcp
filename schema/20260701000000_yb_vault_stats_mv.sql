-- Week 7 Tier-A backlog: materialised vault stats view.
--
-- Replaces the 3 round-trips per LENS turn inside lib/ai/lens.ts::getVaultStats()
-- with a single SELECT from a singleton MV. Also serves the MCP server's
-- youbank_vault_stats tool (mcp-server/src/db/vault-stats.ts) — single source of truth.
--
-- Refresh strategy:
--   pg_cron is NOT installed on this project (checked via list_extensions).
--   We use an AFTER INSERT/UPDATE/DELETE statement-level trigger on yb_vault_items
--   (the primary write source). The trigger performs a non-concurrent REFRESH —
--   for ~225 vault items this completes in milliseconds. CONCURRENTLY cannot run
--   inside a trigger because it requires its own transaction.
--
--   Trade-off: enriched_items/atomic_notes/active_entities lag until the next
--   vault_items write, which happens on every enrichment, save, or status update
--   (sufficient for an internal stats surface). Manual refresh:
--     SELECT refresh_yb_vault_stats_mv();
--   When write volume grows or pg_cron is enabled, swap the trigger for a
--   5-minute pg_cron job using REFRESH ... CONCURRENTLY.

-- ---------- 1. The materialised view -----------------------------------------

CREATE MATERIALIZED VIEW yb_vault_stats_mv AS
SELECT
  1::int AS id,
  (SELECT COUNT(*)::int FROM yb_vault_items) AS total_items,
  -- Distinct non-null ai_category values, sorted for stable output.
  COALESCE(
    (SELECT array_agg(DISTINCT ai_category ORDER BY ai_category)
       FROM yb_vault_items
       WHERE ai_category IS NOT NULL),
    ARRAY[]::text[]
  ) AS categories,
  -- {tagname: count} aggregated across all ai_project_tags arrays (stored as jsonb).
  COALESCE(
    (SELECT jsonb_object_agg(tag, cnt)
       FROM (
         SELECT t.tag::text AS tag, COUNT(*)::int AS cnt
           FROM yb_vault_items v,
                jsonb_array_elements_text(v.ai_project_tags) AS t(tag)
           WHERE jsonb_typeof(v.ai_project_tags) = 'array'
           GROUP BY t.tag
       ) sub),
    '{}'::jsonb
  ) AS project_distribution,
  -- {status: count} from yb_vault_items.status.
  COALESCE(
    (SELECT jsonb_object_agg(status, cnt)
       FROM (
         SELECT status, COUNT(*)::int AS cnt
           FROM yb_vault_items
           WHERE status IS NOT NULL
           GROUP BY status
       ) sub),
    '{}'::jsonb
  ) AS status_counts,
  -- Extra columns serve the MCP tool (mcp-server/src/db/vault-stats.ts).
  -- NOTE: enrichment_status value in DB is 'complete' (NOT 'completed' as the
  -- old MCP code checked — that bug returned 0). MV uses the actual value.
  (SELECT COUNT(*)::int FROM yb_vault_items WHERE enrichment_status = 'complete') AS enriched_items,
  (SELECT COUNT(*)::int FROM yb_atomic_notes) AS atomic_notes,
  (SELECT COUNT(*)::int FROM yb_research_entities WHERE disposition = 'active') AS active_entities,
  now() AS refreshed_at;

-- UNIQUE index on the singleton id — required for REFRESH MATERIALIZED VIEW
-- CONCURRENTLY (left available for future cron use even though triggers
-- below use non-concurrent refresh).
CREATE UNIQUE INDEX yb_vault_stats_mv_pkey ON yb_vault_stats_mv (id);

-- Explicit service_role grant (Week 1-3 lesson: NOT automatic).
GRANT SELECT ON yb_vault_stats_mv TO service_role;

-- ---------- 2. Refresh function ----------------------------------------------

CREATE OR REPLACE FUNCTION refresh_yb_vault_stats_mv()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Non-concurrent — fast for current size, runs inside trigger txn.
  -- When MV grows or pg_cron lands, switch caller to CONCURRENTLY.
  REFRESH MATERIALIZED VIEW yb_vault_stats_mv;
END;
$$;

GRANT EXECUTE ON FUNCTION refresh_yb_vault_stats_mv() TO service_role;

-- ---------- 3. Trigger on yb_vault_items -------------------------------------

CREATE OR REPLACE FUNCTION trg_refresh_yb_vault_stats_mv()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM refresh_yb_vault_stats_mv();
  RETURN NULL; -- statement-level AFTER trigger; return value ignored
END;
$$;

CREATE TRIGGER yb_vault_items_refresh_stats
AFTER INSERT OR UPDATE OR DELETE ON yb_vault_items
FOR EACH STATEMENT
EXECUTE FUNCTION trg_refresh_yb_vault_stats_mv();

-- ---------- 4. Initial population --------------------------------------------
-- The MV was populated by the CREATE statement above (it computed from a
-- SELECT), so the singleton row already exists. No explicit REFRESH needed
-- here — confirmed by SELECT below in verification.

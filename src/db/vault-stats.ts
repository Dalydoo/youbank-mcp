import { getSupabase } from "../supabase.js";

/**
 * Vault counts surfaced by the youbank_vault_stats MCP tool.
 *
 * Single SELECT from the yb_vault_stats_mv materialised view (singleton id=1)
 * — same source of truth as lib/ai/lens.ts::getVaultStats(). See
 * supabase/migrations/20260701000000_yb_vault_stats_mv.sql.
 *
 * Pre-MV this made 4 parallel COUNT queries. The MV trigger on yb_vault_items
 * keeps it warm.
 *
 * NOTE: the legacy code filtered enrichment_status='completed' which never
 * matched (DB value is 'complete'), so enriched_items always returned 0. The
 * MV uses the correct value — call-sites should expect a non-zero number now.
 */
export async function getVaultStats() {
  const supabase = getSupabase();
  const { data, error } = await supabase
    .from("yb_vault_stats_mv")
    .select("total_items, enriched_items, atomic_notes, active_entities")
    .eq("id", 1)
    .maybeSingle();

  if (error || !data) {
    return { total_items: 0, enriched_items: 0, atomic_notes: 0, active_entities: 0 };
  }

  const row = data as {
    total_items: number | null;
    enriched_items: number | null;
    atomic_notes: number | null;
    active_entities: number | null;
  };

  return {
    total_items: row.total_items ?? 0,
    enriched_items: row.enriched_items ?? 0,
    atomic_notes: row.atomic_notes ?? 0,
    active_entities: row.active_entities ?? 0,
  };
}

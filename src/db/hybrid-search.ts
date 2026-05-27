import { getSupabase } from "../supabase.js";
import { embed } from "../embed.js";

export interface VaultItemSlim {
  id: string;
  title: string | null;
  channel_name: string | null;
  ai_summary: string | null;
  ai_category: string | null;
  ai_relevance_score: number | null;
  source_url: string | null;
  source_id: string | null;
  created_at: string;
}

export interface HybridHit extends VaultItemSlim {
  rrf_score: number;
  hit_sources: string[];
  atomic_note_ids: string[];
}

export async function hybridSearch(
  query: string,
  topN: number,
): Promise<HybridHit[]> {
  const supabase = getSupabase();
  const queryEmbedding = await embed(query);

  const { data: rpcRows, error: rpcErr } = await supabase.rpc("yb_hybrid_search", {
    query_text: query,
    query_embedding: queryEmbedding,
    k_const: 60,
    top_n: topN,
  });
  if (rpcErr) throw new Error(`yb_hybrid_search RPC failed: ${rpcErr.message}`);
  if (!rpcRows || rpcRows.length === 0) return [];

  const ids = rpcRows.map((r: any) => r.vault_item_id);
  const { data: items, error: itemErr } = await supabase
    .from("yb_vault_items")
    .select("id, title, channel_name, ai_summary, ai_category, ai_relevance_score, source_url, source_id, created_at")
    .in("id", ids);
  if (itemErr) throw new Error(`yb_vault_items fetch failed: ${itemErr.message}`);
  if (!items) return [];

  // Preserve RPC order (RRF rank), join the full row, attach RPC fields.
  const byId = new Map(items.map((it: VaultItemSlim) => [it.id, it]));
  return rpcRows
    .map((r: any) => {
      const full = byId.get(r.vault_item_id);
      if (!full) return null;
      return {
        ...full,
        rrf_score: r.rrf_score,
        hit_sources: r.hit_sources ?? [],
        atomic_note_ids: r.atomic_note_ids ?? [],
      };
    })
    .filter((x: HybridHit | null): x is HybridHit => x !== null);
}

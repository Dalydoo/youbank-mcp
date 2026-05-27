import { getSupabase } from "../supabase.js";

/**
 * Read-only highlights queries for the MCP server.
 *
 * Mirrors lib/highlights/queries.ts::listHighlights but lives in the mcp-server
 * sub-package so it stays independent of the Next.js app (mcp-server has its
 * own tsconfig and its own supabase client). The shape here is intentionally
 * flatter — MCP clients prefer item_title joined in over a nested object.
 */

export interface McpHighlight {
  id: string;
  item_id: string;
  item_title: string;
  item_category: string | null;
  segment_index: number;
  segment_start_s: number;
  segment_end_s: number;
  segment_text: string;
  note: string | null;
  created_at: string;
}

export interface ListHighlightsOptions {
  item_id?: string;
  category?: string;
  since?: string;
  limit?: number;
}

export async function listHighlights(
  opts: ListHighlightsOptions,
): Promise<{ highlights: McpHighlight[]; total: number }> {
  const supabase = getSupabase();
  let query = supabase
    .from("yb_highlights")
    .select(`
      id, item_id, segment_index, segment_start_s, segment_end_s,
      segment_text, note, created_at,
      yb_vault_items!inner ( title, ai_category )
    `)
    .order("created_at", { ascending: false })
    .limit(Math.min(opts.limit ?? 50, 200));

  if (opts.item_id) query = query.eq("item_id", opts.item_id);
  if (opts.since) query = query.gte("created_at", opts.since);
  if (opts.category) query = query.eq("yb_vault_items.ai_category", opts.category);

  const { data, error } = await query;
  if (error) throw new Error(`listHighlights: ${error.message}`);

  const highlights = (data ?? []).map((row: any) => {
    const item = Array.isArray(row.yb_vault_items)
      ? row.yb_vault_items[0]
      : row.yb_vault_items;
    return {
      id: row.id,
      item_id: row.item_id,
      item_title: item?.title ?? "(unknown)",
      item_category: item?.ai_category ?? null,
      segment_index: row.segment_index,
      segment_start_s: Number(row.segment_start_s),
      segment_end_s: Number(row.segment_end_s),
      segment_text: row.segment_text,
      note: row.note,
      created_at: row.created_at,
    } satisfies McpHighlight;
  });

  return { highlights, total: highlights.length };
}

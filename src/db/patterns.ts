// mcp-server/src/db/patterns.ts
//
// Read-only pattern queries for the MCP server. Mirrors lib/patterns/queries
// shape but lives in the mcp-server sub-package so it stays independent of
// the Next.js app (own tsconfig, own supabase client).

import { getSupabase } from "../supabase.js";
import { embed } from "../embed.js";

export interface McpPattern {
  id: string;
  pattern_text: string;
  pattern_type: string;
  occurrence_count: number;
  source_diversity: number;
  avg_confidence: number;
  last_reinforced_at: string;
  cosine?: number;
}

export interface ListPatternsOptions {
  query?: string;
  min_occurrence?: number;
  since?: string;
  limit?: number;
}

export async function listPatterns(
  opts: ListPatternsOptions,
): Promise<{ patterns: McpPattern[]; total: number }> {
  const supabase = getSupabase();
  const limit = Math.min(opts.limit ?? 20, 100);

  // Query mode — cosine match via the same RPC LENS calls.
  if (opts.query) {
    const queryEmbedding = await embed(opts.query);
    const { data, error } = await supabase.rpc("yb_patterns_search", {
      query_embedding: queryEmbedding,
      min_cosine: 0.55,
      top_n: limit,
    });
    if (error) throw new Error(`yb_patterns_search: ${error.message}`);
    let rows = (data ?? []) as McpPattern[];
    if (opts.min_occurrence) {
      rows = rows.filter((p) => p.occurrence_count >= opts.min_occurrence!);
    }
    if (opts.since) {
      rows = rows.filter((p) => p.last_reinforced_at >= opts.since!);
    }
    return { patterns: rows, total: rows.length };
  }

  // Filter mode — straight table query by recency.
  let q = supabase
    .from("yb_patterns")
    .select(
      "id, pattern_text, pattern_type, occurrence_count, source_diversity, avg_confidence, last_reinforced_at",
    )
    .eq("status", "active")
    .order("last_reinforced_at", { ascending: false })
    .limit(limit);
  if (opts.min_occurrence) q = q.gte("occurrence_count", opts.min_occurrence);
  if (opts.since) q = q.gte("last_reinforced_at", opts.since);
  const { data, error } = await q;
  if (error) throw new Error(`yb_patterns fetch failed: ${error.message}`);
  const rows = (data ?? []) as McpPattern[];
  return { patterns: rows, total: rows.length };
}

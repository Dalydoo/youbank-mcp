import { hybridSearch } from "../db/hybrid-search.js";

export const tool = {
  name: "youbank_hybrid_search",
  description:
    "Search Daz's YouBank vault using hybrid retrieval (BM25 + cosine + RRF over vault items + atomic notes). " +
    "Returns the top N candidate items ranked by relevance. Each result includes the item ID, title, " +
    "channel, AI summary, AI category, source URL. Use this whenever the user asks about something they " +
    "have or might have saved in YouBank.",
  inputSchema: {
    type: "object",
    properties: {
      query: { type: "string", description: "Natural-language query. Compound queries OK." },
      top_n: { type: "integer", description: "How many candidates (default 10, max 25).", minimum: 1, maximum: 25 },
    },
    required: ["query"],
  },
  async handler(input: { query: string; top_n?: number }) {
    const items = await hybridSearch(input.query, Math.min(input.top_n ?? 10, 25));
    if (items.length === 0) {
      return { content: [{ type: "text", text: `No matches for "${input.query}".` }] };
    }
    const lines = items.map((it, i) =>
      `${i + 1}. [${it.id}] "${it.title ?? "(no title)"}" — ${it.ai_category ?? "uncategorised"}\n` +
      `   ${(it.ai_summary ?? "(no summary)").slice(0, 240)}\n` +
      `   Source: ${it.source_url ?? "(no URL)"}`,
    );
    return {
      content: [{
        type: "text",
        text: `Found ${items.length} candidates for "${input.query}":\n\n` + lines.join("\n\n"),
      }],
    };
  },
};

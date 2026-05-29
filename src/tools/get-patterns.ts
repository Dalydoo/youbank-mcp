// mcp-server/src/tools/get-patterns.ts
import { listPatterns } from "../db/patterns.js";

export const tool = {
  name: "youbank_get_patterns",
  description:
    "Return synthesised patterns from Daz's YouBank vault. Patterns are claims " +
    "observed across multiple sources, lifted into a higher-confidence layer above " +
    "raw atomic notes. Each pattern reports occurrence_count, source_diversity, and " +
    "avg_confidence. Use this whenever the user asks 'what do you know about X', " +
    "'what patterns have emerged in my reading', or wants canonical cross-source " +
    "knowledge — patterns are stronger evidence than individual atomic notes.",
  inputSchema: {
    type: "object",
    properties: {
      query: {
        type: "string",
        description:
          "Natural-language query. When provided, cosine-matches against pattern " +
          "embeddings (threshold 0.55). When omitted, returns most-recently-reinforced.",
      },
      min_occurrence: {
        type: "integer",
        description: "Min occurrence_count filter. All patterns already have >=3; use this to raise the floor.",
        minimum: 3,
      },
      since: {
        type: "string",
        description: "ISO timestamp — only patterns reinforced on/after this time.",
      },
      limit: {
        type: "integer",
        description: "Max patterns to return (default 20, max 100).",
        minimum: 1,
        maximum: 100,
      },
    },
    required: [],
  },
  async handler(input: {
    query?: string;
    min_occurrence?: number;
    since?: string;
    limit?: number;
  }) {
    const { patterns, total } = await listPatterns(input);

    if (total === 0) {
      const filters = [
        input.query && `query="${input.query}"`,
        input.min_occurrence && `min_occurrence=${input.min_occurrence}`,
        input.since && `since=${input.since}`,
      ].filter(Boolean).join(", ");
      const filterDesc = filters ? ` matching ${filters}` : "";
      return {
        content: [{ type: "text", text: `No patterns found${filterDesc}.` }],
      };
    }

    const lines = patterns.map((p, i) =>
      `${i + 1}. [${p.id}] "${p.pattern_text}"\n` +
      `   ${p.occurrence_count} occurrences across ${p.source_diversity} sources, ` +
      `avg confidence ${p.avg_confidence.toFixed(2)}\n` +
      `   Type: ${p.pattern_type}, last reinforced ${p.last_reinforced_at.slice(0, 10)}`,
    );

    return {
      content: [
        {
          type: "text",
          text: `${total} pattern${total === 1 ? "" : "s"}:\n\n` + lines.join("\n\n"),
        },
      ],
    };
  },
};

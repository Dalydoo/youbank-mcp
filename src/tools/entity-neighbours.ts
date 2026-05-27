import { getEntityNeighbours } from "../db/entity-neighbours.js";

export const tool = {
  name: "youbank_entity_neighbours",
  description:
    "List the top N co-occurring entities for a named entity. Co-occurrence weight is derived from " +
    "how often the two entities are mentioned in the same vault items. Useful for entity exploration " +
    "and bridge discovery.",
  inputSchema: {
    type: "object",
    properties: {
      entity_name: { type: "string", description: "Exact name of the entity (case-sensitive)." },
      top_n: { type: "integer", description: "How many neighbours (default 10, max 25).", minimum: 1, maximum: 25 },
    },
    required: ["entity_name"],
  },
  async handler(input: { entity_name: string; top_n?: number }) {
    const ns = await getEntityNeighbours(input.entity_name, Math.min(input.top_n ?? 10, 25));
    if (ns.length === 0) {
      return { content: [{ type: "text", text: `No neighbours for entity "${input.entity_name}".` }] };
    }
    const lines = ns.map((n) => `- ${n.name} (weight ${n.weight}, ${n.co_mentions} co-mentions)`);
    return { content: [{ type: "text", text: lines.join("\n") }] };
  },
};

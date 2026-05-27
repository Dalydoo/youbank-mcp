import { getAtomicNotes } from "../db/atomic-notes.js";

export const tool = {
  name: "youbank_get_atomic_notes",
  description:
    "List the atomic claims extracted from a vault item by its UUID. Each claim is a single-sentence " +
    "factual statement with an optional [@<seconds>s] source-timestamp pointer (for transcript-bearing " +
    "items). Useful for citing specific moments in a video.",
  inputSchema: {
    type: "object",
    properties: {
      vault_item_id: { type: "string", description: "UUID of the parent vault item." },
    },
    required: ["vault_item_id"],
  },
  async handler(input: { vault_item_id: string }) {
    const notes = await getAtomicNotes(input.vault_item_id);
    if (notes.length === 0) {
      return { content: [{ type: "text", text: `No atomic notes for vault item ${input.vault_item_id}.` }] };
    }
    const lines = notes.map((n) => {
      const ts = n.chunk_start_seconds !== null ? ` [@${n.chunk_start_seconds}s]` : "";
      return `- ${n.atomic_claim}${ts}`;
    });
    return { content: [{ type: "text", text: lines.join("\n") }] };
  },
};

import { getVaultItem } from "../db/vault-item.js";

export const tool = {
  name: "youbank_get_vault_item",
  description:
    "Fetch the full row of a single YouBank vault item by its UUID. Use when you have an item ID " +
    "(e.g. from youbank_hybrid_search) and want the complete record — transcript, key points, " +
    "enrichment metadata.",
  inputSchema: {
    type: "object",
    properties: {
      item_id: { type: "string", description: "UUID of the vault item." },
    },
    required: ["item_id"],
  },
  async handler(input: { item_id: string }) {
    const item = await getVaultItem(input.item_id);
    if (!item) {
      return { content: [{ type: "text", text: `No vault item with id ${input.item_id}.` }] };
    }
    return { content: [{ type: "text", text: JSON.stringify(item, null, 2) }] };
  },
};

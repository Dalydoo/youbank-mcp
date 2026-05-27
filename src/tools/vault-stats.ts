import { getVaultStats } from "../db/vault-stats.js";

export const tool = {
  name: "youbank_vault_stats",
  description:
    "Get a summary of the YouBank vault: total items, enriched items, atomic-note count, " +
    "active-entity count. No arguments. Useful for orientation when the user asks 'what's in " +
    "my vault'.",
  inputSchema: { type: "object", properties: {}, required: [] },
  async handler() {
    const stats = await getVaultStats();
    return { content: [{ type: "text", text: JSON.stringify(stats, null, 2) }] };
  },
};

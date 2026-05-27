#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { tool as hybridSearch }     from "./tools/hybrid-search.js";
import { tool as getVaultItem }     from "./tools/vault-item.js";
import { tool as getAtomicNotes }   from "./tools/atomic-notes.js";
import { tool as entityNeighbours } from "./tools/entity-neighbours.js";
import { tool as vaultStats }       from "./tools/vault-stats.js";
import { tool as getHighlights }    from "./tools/get-highlights.js";

const ALL_TOOLS = [
  hybridSearch, getVaultItem, getAtomicNotes, entityNeighbours, vaultStats, getHighlights,
] as const;

const server = new Server(
  { name: "youbank", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: ALL_TOOLS.map((t) => ({
    name: t.name,
    description: t.description,
    inputSchema: t.inputSchema,
  })),
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const target = ALL_TOOLS.find((t) => t.name === req.params.name);
  if (!target) {
    return {
      isError: true,
      content: [{ type: "text", text: `unknown tool: ${req.params.name}` }],
    };
  }
  try {
    return await target.handler(req.params.arguments as any);
  } catch (err) {
    const msg = err instanceof Error ? err.message : "unknown error";
    return {
      isError: true,
      content: [{ type: "text", text: `error executing ${req.params.name}: ${msg}` }],
    };
  }
});

await server.connect(new StdioServerTransport());
// Process stays alive on stdio; client disconnect closes stdin → process exits.

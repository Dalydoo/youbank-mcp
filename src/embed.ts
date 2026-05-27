// Local embedder for hybrid-search RPC. Mirrors lib/ai/embeddings.ts but lives
// in the mcp-server package so the server has no main-repo dependencies.
//
// Cold-start: first call downloads the 384-dim model (~46MB) and caches it to
// ~/.cache/transformers. Subsequent calls re-use the cache (~50ms inference).
// MCP server is a long-lived child process — cold-start happens once per
// Claude Desktop session. Acceptable per spec Open Question 5.
import { pipeline, env } from "@xenova/transformers";

// Pin model ID to match the main app exactly.
const MODEL_ID = "Xenova/all-MiniLM-L6-v2"; // 384-dim, matches lib/ai/embeddings.ts

env.allowLocalModels = false;
env.useBrowserCache = false;

let _pipe: any = null;

async function getPipe() {
  if (_pipe) return _pipe;
  _pipe = await pipeline("feature-extraction", MODEL_ID);
  return _pipe;
}

export async function embed(text: string): Promise<number[]> {
  const p = await getPipe();
  const out = await p(text, { pooling: "mean", normalize: true });
  // out.data is a Float32Array of length 384.
  return Array.from(out.data as Float32Array);
}

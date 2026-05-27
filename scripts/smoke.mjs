// mcp-server/scripts/smoke.mjs
// Spawn dist/index.js as a child, send tools/list + tools/call, assert replies.
// Exits 0 on success, non-zero on failure.
import { spawn } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BIN = resolve(__dirname, "../dist/index.js");

const env = { ...process.env };
// Load .env.local if present (caller may set explicitly).
if (!env.YOUBANK_SUPABASE_URL && !env.NEXT_PUBLIC_SUPABASE_URL) {
  console.error("smoke: no Supabase env vars set — export YOUBANK_SUPABASE_URL and " +
                "YOUBANK_SUPABASE_SERVICE_ROLE_KEY first.");
  process.exit(2);
}

const child = spawn("node", [BIN], { env, stdio: ["pipe", "pipe", "inherit"] });

let buf = "";
const replies = [];
child.stdout.on("data", (chunk) => {
  buf += chunk.toString();
  // MCP framing: each message is a length-prefixed JSON-RPC blob. The SDK
  // newline-delimits by default in stdio mode.
  for (;;) {
    const nl = buf.indexOf("\n");
    if (nl < 0) break;
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    if (!line.trim()) continue;
    try { replies.push(JSON.parse(line)); } catch { /* ignore non-JSON noise */ }
  }
});

function send(req) {
  child.stdin.write(JSON.stringify(req) + "\n");
}

function waitForReply(id, timeoutMs = 30_000) {
  return new Promise((resolveReply, reject) => {
    const start = Date.now();
    const tick = setInterval(() => {
      const r = replies.find((x) => x.id === id);
      if (r) { clearInterval(tick); resolveReply(r); }
      else if (Date.now() - start > timeoutMs) { clearInterval(tick); reject(new Error(`timeout waiting for id=${id}`)); }
    }, 100);
  });
}

(async () => {
  // 0. MCP handshake — initialize must precede other requests.
  send({
    jsonrpc: "2.0", id: 0, method: "initialize",
    params: {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "smoke", version: "0.0.0" },
    },
  });
  const init = await waitForReply(0);
  if (!init.result) {
    console.error("smoke FAIL: initialize did not return result:", JSON.stringify(init));
    child.kill(); process.exit(1);
  }
  // Required notification per MCP spec.
  send({ jsonrpc: "2.0", method: "notifications/initialized" });
  console.log("smoke: initialize OK");

  // 1. tools/list
  send({ jsonrpc: "2.0", id: 1, method: "tools/list" });
  const list = await waitForReply(1);
  if (!list.result || !Array.isArray(list.result.tools) || list.result.tools.length !== 6) {
    console.error("smoke FAIL: tools/list did not return 6 tools:", JSON.stringify(list));
    child.kill(); process.exit(1);
  }
  console.log(`smoke: tools/list OK (${list.result.tools.length} tools: ${list.result.tools.map((t) => t.name).join(", ")})`);

  // 2. tools/call youbank_hybrid_search
  send({
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: { name: "youbank_hybrid_search", arguments: { query: "agent memory", top_n: 3 } },
  });
  const call = await waitForReply(2, 60_000);   // cold-start headroom
  const txt = call.result?.content?.[0]?.text ?? "";
  if (!txt.includes("candidates for") && !txt.includes("No matches")) {
    console.error("smoke FAIL: hybrid_search call did not return expected text:", JSON.stringify(call));
    child.kill(); process.exit(1);
  }
  console.log("smoke: tools/call youbank_hybrid_search OK");

  // 3. tools/call youbank_vault_stats
  send({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: { name: "youbank_vault_stats", arguments: {} },
  });
  const stats = await waitForReply(3);
  const statsTxt = stats.result?.content?.[0]?.text ?? "";
  if (!statsTxt.includes("total_items")) {
    console.error("smoke FAIL: vault_stats call did not return expected JSON:", JSON.stringify(stats));
    child.kill(); process.exit(1);
  }
  console.log("smoke: tools/call youbank_vault_stats OK");
  console.log("  vault_stats:", statsTxt.replace(/\s+/g, " ").slice(0, 200));

  console.log("smoke: OK");
  child.kill();
  process.exit(0);
})().catch((err) => {
  console.error("smoke FAIL:", err);
  child.kill();
  process.exit(1);
});

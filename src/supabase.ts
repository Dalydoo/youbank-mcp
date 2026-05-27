import { createClient, type SupabaseClient } from "@supabase/supabase-js";

let _client: SupabaseClient | null = null;

export function getSupabase(): SupabaseClient {
  if (_client) return _client;
  const url =
    process.env.YOUBANK_SUPABASE_URL ??
    process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key =
    process.env.YOUBANK_SUPABASE_SERVICE_ROLE_KEY ??
    process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new Error(
      "MCP server env: YOUBANK_SUPABASE_URL and YOUBANK_SUPABASE_SERVICE_ROLE_KEY required " +
      "(or NEXT_PUBLIC_SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY fallback)",
    );
  }
  _client = createClient(url, key, { auth: { persistSession: false } });
  return _client;
}

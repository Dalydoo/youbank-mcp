import { getSupabase } from "../supabase.js";

export async function getVaultItem(id: string) {
  const supabase = getSupabase();
  const { data, error } = await supabase
    .from("yb_vault_items")
    .select("*")
    .eq("id", id)
    .maybeSingle();
  if (error) throw new Error(`yb_vault_items fetch failed: ${error.message}`);
  return data;
}

import { getSupabase } from "../supabase.js";

export interface AtomicNoteSlim {
  id: string;
  vault_item_id: string;
  atomic_claim: string;
  chunk_start_seconds: number | null;
  chunk_end_seconds: number | null;
  confidence_score: number | null;
}

export async function getAtomicNotes(vaultItemId: string): Promise<AtomicNoteSlim[]> {
  const supabase = getSupabase();
  const { data, error } = await supabase
    .from("yb_atomic_notes")
    .select("id, vault_item_id, atomic_claim, chunk_start_seconds, chunk_end_seconds, confidence_score")
    .eq("vault_item_id", vaultItemId)
    .order("chunk_start_seconds", { ascending: true, nullsFirst: false });
  if (error) throw new Error(`yb_atomic_notes fetch failed: ${error.message}`);
  return (data ?? []) as AtomicNoteSlim[];
}

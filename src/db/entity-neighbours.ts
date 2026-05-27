import { getSupabase } from "../supabase.js";

export interface EntityNeighbour {
  name: string;
  weight: number;
  co_mentions: number;
}

export async function getEntityNeighbours(
  entityName: string,
  topN: number,
): Promise<EntityNeighbour[]> {
  const supabase = getSupabase();
  // Find the entity by name → fetch top-N neighbours from yb_entity_relations
  // (which lists co-occurrence weights between entity pairs).
  const { data: entity, error: entErr } = await supabase
    .from("yb_research_entities")
    .select("id")
    .eq("name", entityName)
    .eq("disposition", "active")
    .maybeSingle();
  if (entErr) throw new Error(`yb_research_entities lookup failed: ${entErr.message}`);
  if (!entity) return [];

  // yb_entity_relations stores pairs in canonical (id-sorted) order, so the
  // anchor entity may appear as either source_entity_id OR target_entity_id.
  // Query both columns and resolve the "other" side per row.
  const { data: rels, error: relErr } = await supabase
    .from("yb_entity_relations")
    .select("source_entity_id, target_entity_id, weight, evidence_count")
    .or(`source_entity_id.eq.${entity.id},target_entity_id.eq.${entity.id}`)
    .order("weight", { ascending: false })
    .limit(topN);
  if (relErr) throw new Error(`yb_entity_relations fetch failed: ${relErr.message}`);
  if (!rels || rels.length === 0) return [];

  const otherIds = rels.map((r: any) =>
    r.source_entity_id === entity.id ? r.target_entity_id : r.source_entity_id,
  );
  const { data: others, error: othErr } = await supabase
    .from("yb_research_entities")
    .select("id, name")
    .in("id", otherIds);
  if (othErr) throw new Error(`other entities fetch failed: ${othErr.message}`);

  const byId = new Map((others ?? []).map((e: any) => [e.id, e.name]));
  return rels
    .map((r: any) => {
      const otherId =
        r.source_entity_id === entity.id ? r.target_entity_id : r.source_entity_id;
      return {
        name: byId.get(otherId) ?? "(unknown)",
        weight: Number(r.weight),
        co_mentions: Number(r.evidence_count),
      };
    })
    .filter((n) => n.name !== "(unknown)");
}

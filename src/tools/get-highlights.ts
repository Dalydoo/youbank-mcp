import { listHighlights } from "../db/highlights.js";

function formatTimestamp(seconds: number): string {
  const s = Math.floor(seconds);
  const hrs = Math.floor(s / 3600);
  const mins = Math.floor((s % 3600) / 60);
  const secs = s % 60;
  if (hrs > 0) {
    return `${hrs}:${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
  }
  return `${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
}

export const tool = {
  name: "youbank_get_highlights",
  description:
    "Return user-curated highlights from the YouBank vault. Highlights are passages Daz has " +
    "explicitly marked as important on a YouTube transcript. Filter by item_id, category, or " +
    "since (ISO datetime). Use this when the user asks 'what have I highlighted', 'show me my " +
    "highlights on X', or when you need the canonical quotes Daz has flagged.",
  inputSchema: {
    type: "object",
    properties: {
      item_id: {
        type: "string",
        description: "Filter to highlights on one specific vault item (UUID).",
      },
      category: {
        type: "string",
        description: "Filter to highlights whose parent item's ai_category matches.",
      },
      since: {
        type: "string",
        description: "ISO timestamp — only highlights created on/after this time.",
      },
      limit: {
        type: "integer",
        description: "Max highlights to return (default 50, max 200).",
        minimum: 1,
        maximum: 200,
      },
    },
    required: [],
  },
  async handler(input: {
    item_id?: string;
    category?: string;
    since?: string;
    limit?: number;
  }) {
    const { highlights, total } = await listHighlights({
      item_id: input.item_id,
      category: input.category,
      since: input.since,
      limit: input.limit,
    });

    if (total === 0) {
      const filters = [
        input.item_id && `item_id=${input.item_id}`,
        input.category && `category="${input.category}"`,
        input.since && `since=${input.since}`,
      ].filter(Boolean).join(", ");
      const filterDesc = filters ? ` matching ${filters}` : "";
      return {
        content: [{ type: "text", text: `No highlights found${filterDesc}.` }],
      };
    }

    const lines = highlights.map((h, i) => {
      const ts = formatTimestamp(h.segment_start_s);
      const cat = h.item_category ? ` (${h.item_category})` : "";
      const note = h.note ? `\n   Note: ${h.note}` : "";
      return (
        `${i + 1}. [${h.item_id}] "${h.item_title}"${cat}\n` +
        `   [${ts}] ${h.segment_text}${note}`
      );
    });

    return {
      content: [
        {
          type: "text",
          text: `${total} highlight${total === 1 ? "" : "s"}:\n\n` + lines.join("\n\n"),
        },
      ],
    };
  },
};

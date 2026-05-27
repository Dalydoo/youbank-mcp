-- supabase/migrations/20260526000200_highlights.sql
--
-- yb_highlights — user-curated transcript-segment highlights.
-- Single-tenant for v1 (no user_id column). When multi-tenant lands the
-- column is added in the same migration that introduces orgs/workspaces.

CREATE TABLE IF NOT EXISTS yb_highlights (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id         uuid NOT NULL REFERENCES yb_vault_items(id) ON DELETE CASCADE,
  segment_index   integer NOT NULL,
  segment_start_s numeric(10,3) NOT NULL,
  segment_end_s   numeric(10,3) NOT NULL,
  segment_text    text NOT NULL,
  note            text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (item_id, segment_index)
);

CREATE INDEX IF NOT EXISTS idx_yb_highlights_item_id ON yb_highlights (item_id);
CREATE INDEX IF NOT EXISTS idx_yb_highlights_created_at ON yb_highlights (created_at DESC);

COMMENT ON TABLE yb_highlights IS
  'User-curated highlights of yb_vault_items.transcript_segments. UNIQUE(item_id, segment_index) makes the toggle idempotent.';

-- Permissions. Without these, service_role and authenticated queries fail with
-- "permission denied for table yb_highlights" — Supabase's default-deny for
-- newly created tables. RLS is enabled by Supabase automatically but blocks
-- everything until policies exist; service_role bypasses RLS but still needs
-- the explicit grants on the table itself.
GRANT SELECT, INSERT, UPDATE, DELETE ON yb_highlights TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON yb_highlights TO authenticated;

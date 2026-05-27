-- supabase/migrations/20260527000100_audio_overviews.sql
--
-- yb_audio_overviews — NotebookLM-style two-host audio overviews.
-- One row per vault item (UNIQUE item_id). script_md is the dialogue
-- source-of-truth; audio_url points at Supabase Storage.

CREATE TABLE IF NOT EXISTS yb_audio_overviews (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id         uuid NOT NULL UNIQUE REFERENCES yb_vault_items(id) ON DELETE CASCADE,
  script_md       text NOT NULL,
  audio_url       text NOT NULL,
  duration_s      numeric(6,2),
  voice_a         text NOT NULL,
  voice_b         text NOT NULL,
  char_count      integer NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  regenerated_at  timestamptz
);

CREATE INDEX IF NOT EXISTS idx_yb_audio_overviews_created_at
  ON yb_audio_overviews (created_at DESC);

COMMENT ON TABLE yb_audio_overviews IS
  'NotebookLM-style two-host audio overviews. One row per vault item. script_md is the dialogue source-of-truth; audio_url is the rendered MP3 in Supabase Storage bucket audio-overviews. voice_a (host) and voice_b (analyst) are ElevenLabs voice IDs.';

GRANT SELECT, INSERT, UPDATE, DELETE ON yb_audio_overviews TO service_role;
GRANT SELECT ON yb_audio_overviews TO authenticated;

-- Storage bucket — public read, service-role write.
-- Idempotent: ON CONFLICT DO NOTHING so re-applies are safe.
INSERT INTO storage.buckets (id, name, public)
VALUES ('audio-overviews', 'audio-overviews', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies. Service role bypasses RLS but explicit policies make
-- the access model auditable. Public SELECT lets the <audio> tag work
-- without signed URLs.
DROP POLICY IF EXISTS "audio-overviews public read" ON storage.objects;
CREATE POLICY "audio-overviews public read" ON storage.objects
  FOR SELECT
  USING (bucket_id = 'audio-overviews');

DROP POLICY IF EXISTS "audio-overviews service role write" ON storage.objects;
CREATE POLICY "audio-overviews service role write" ON storage.objects
  FOR INSERT TO service_role
  WITH CHECK (bucket_id = 'audio-overviews');

DROP POLICY IF EXISTS "audio-overviews service role update" ON storage.objects;
CREATE POLICY "audio-overviews service role update" ON storage.objects
  FOR UPDATE TO service_role
  USING (bucket_id = 'audio-overviews');

DROP POLICY IF EXISTS "audio-overviews service role delete" ON storage.objects;
CREATE POLICY "audio-overviews service role delete" ON storage.objects
  FOR DELETE TO service_role
  USING (bucket_id = 'audio-overviews');

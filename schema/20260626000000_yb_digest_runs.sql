-- Week 6 PR 4: yb_digest_runs — one row per daily digest run.
-- Idempotency via UNIQUE (digest_date). delivery JSON keyed by channel.

CREATE TABLE yb_digest_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Date the digest covers (UTC). UNIQUE — one digest per calendar day max.
  digest_date     date        NOT NULL UNIQUE,
  -- Inclusive lower bound of the items considered (typically digest_date - 1 day at 00:00 UTC).
  window_start    timestamptz NOT NULL,
  -- Exclusive upper bound (typically digest_date at 00:00 UTC, but matches window_start + 24h).
  window_end      timestamptz NOT NULL,
  -- Counts captured at compose time.
  items_count     int         NOT NULL,
  notes_count     int         NOT NULL,
  -- Composed body (markdown).
  body            text        NOT NULL,
  -- Per-channel delivery status — JSON for flexibility.
  -- e.g. {"email":{"status":"sent","provider":"resend","message_id":"..."},
  --       "discord":{"status":"sent","webhook":"<redacted>"}}
  delivery        jsonb       NOT NULL DEFAULT '{}'::jsonb,
  status          text        NOT NULL CHECK (status IN ('composed','sending','sent','failed')),
  error           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  sent_at         timestamptz
);

CREATE INDEX idx_yb_digest_runs_date ON yb_digest_runs (digest_date DESC);

-- Explicit service_role grants (Week 1-3 lesson: NOT automatic).
GRANT SELECT, INSERT, UPDATE ON yb_digest_runs TO service_role;

COMMENT ON TABLE yb_digest_runs IS
  'Audit + idempotency trail for the daily YouBank vault digest. One row per calendar UTC date.';

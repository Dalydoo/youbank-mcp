-- Week 5 PR 1: per-platform Playwright session cookie storage.
-- One row = the serialised BrowserContext storageState (cookies + localStorage)
-- for one platform. Read by the sync route at boot; written back after each
-- successful run so Playwright's refreshed session cookies persist.
--
-- service_role-only — the worker is the only writer. Cookie payloads contain
-- auth credentials and must never be exposed via anon/authenticated reads.

CREATE TABLE IF NOT EXISTS yb_social_cookies (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  platform      TEXT NOT NULL UNIQUE,
                -- one of: 'instagram' | 'x' | 'facebook' | 'linkedin'
  storage_state JSONB NOT NULL,
                -- shape: { cookies: [...], origins: [...] } — Playwright's
                -- BrowserContext.storageState() output verbatim.
  last_used_at  TIMESTAMPTZ,
  last_error    TEXT,
  last_error_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON yb_social_cookies TO service_role;
ALTER TABLE yb_social_cookies DISABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_yb_social_cookies_platform
  ON yb_social_cookies (platform);

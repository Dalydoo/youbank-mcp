-- Audit §2.8: 2 unindexed FKs. Tables are tiny (<300 rows total) so no
-- CONCURRENTLY needed; CREATE INDEX completes in ms.

CREATE INDEX IF NOT EXISTS idx_yb_sync_log_connector_id
  ON yb_sync_log(connector_id);

CREATE INDEX IF NOT EXISTS idx_yb_vault_items_duplicate_of
  ON yb_vault_items(duplicate_of);

-- GoodAnalytics v07 — Add host and path columns to ga_events
-- Normalized URL components populated at insert time by UrlNormalizer.
-- Indexes support path-only and host-aware analytics queries.
--
-- DEPLOY RUNBOOK: Before running this migration in production, create
-- indexes concurrently out-of-band to avoid ACCESS EXCLUSIVE locks:
--
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ga_events_workspace_path
--     ON $SCHEMA$.ga_events (workspace_id, path, inserted_at DESC);
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ga_events_workspace_host_path
--     ON $SCHEMA$.ga_events (workspace_id, host, path, inserted_at DESC);
--
-- Once the concurrent indexes exist, the CREATE INDEX IF NOT EXISTS
-- statements below become no-ops.

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN host text;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN path text;

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_path
  ON $SCHEMA$.ga_events (workspace_id, path, inserted_at DESC);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_host_path
  ON $SCHEMA$.ga_events (workspace_id, host, path, inserted_at DESC);

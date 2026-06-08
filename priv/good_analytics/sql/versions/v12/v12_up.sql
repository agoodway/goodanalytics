-- GoodAnalytics V12 — per-session path aggregation index.
--
-- Supports the per-session sequence scan:
--
--   WHERE workspace_id = $1
--     AND inserted_at >= $2 AND inserted_at < $3
--     AND session_id IS NOT NULL
--     AND event_type IN ('pageview','lead','sale')
--   GROUP BY session_id
--
-- Workspace-leading + partial (only node-eligible rows), so the planner reads
-- one contiguous workspace+time range instead of falling back to the global
-- (event_type, inserted_at) index with workspace_id as a heap filter. session_id
-- trails as the group key.
--
-- ga_events is PARTITIONED BY RANGE(inserted_at). The CREATE INDEX on the parent
-- below propagates to all existing and future partitions, but takes a
-- write-blocking lock per partition for the duration of the build — fine for
-- dev/test; for a large production table prebuild out-of-band using the v04/v10
-- runbook (Postgres forbids CREATE INDEX CONCURRENTLY on a partitioned parent):
--
--   CREATE INDEX IF NOT EXISTS idx_ga_events_journey
--     ON ONLY $SCHEMA$.ga_events (workspace_id, inserted_at DESC, session_id)
--     WHERE event_type IN ('pageview','lead','sale') AND session_id IS NOT NULL;
--
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_<partition>_journey
--     ON $SCHEMA$.<partition> (workspace_id, inserted_at DESC, session_id)
--     WHERE event_type IN ('pageview','lead','sale') AND session_id IS NOT NULL;
--
--   ALTER INDEX $SCHEMA$.idx_ga_events_journey
--     ATTACH PARTITION $SCHEMA$.idx_<partition>_journey;
--
-- Once the attached partitioned index exists, the statement below is a no-op.

CREATE INDEX IF NOT EXISTS idx_ga_events_journey
  ON $SCHEMA$.ga_events (workspace_id, inserted_at DESC, session_id)
  WHERE event_type IN ('pageview', 'lead', 'sale') AND session_id IS NOT NULL;

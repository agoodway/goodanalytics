-- GoodAnalytics v09 — Event-grain device dimensions on ga_events
-- Device/browser/OS is parsed from the user_agent already stored on every
-- event and promoted to scalar columns so breakdowns group by event context
-- rather than the visitor's single first-touch device.
--
-- ga_events is PARTITION BY RANGE (inserted_at); ALTER TABLE ADD COLUMN and
-- CREATE INDEX on the parent propagate to all existing and future partitions
-- (Postgres 11+), matching v07/v08.
--
-- DEPLOY RUNBOOK: Postgres does not support CREATE INDEX CONCURRENTLY on
-- partitioned parent tables. Before running this migration in production on a
-- large table, use the V04 pattern: create the parent partitioned index
-- metadata, create child partition indexes concurrently, then attach each child
-- index to the parent index. The simplified shape for each dimension is:
--
--   CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_device_type
--     ON ONLY $SCHEMA$.ga_events (workspace_id, device_type, inserted_at DESC);
--
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_<partition>_device_type
--     ON $SCHEMA$.<partition> (workspace_id, device_type, inserted_at DESC);
--
--   ALTER INDEX $SCHEMA$.idx_ga_events_workspace_device_type
--     ATTACH PARTITION $SCHEMA$.idx_<partition>_device_type;
--
-- Once the attached partitioned index exists, the CREATE INDEX IF NOT EXISTS
-- statement below becomes a no-op. Repeat for browser and os.

-- Indexed dimensions (low cardinality)
ALTER TABLE $SCHEMA$.ga_events ADD COLUMN device_type text;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN browser text;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN os text;

--SPLIT--

-- Stored-only drilldown dimensions (high cardinality)
ALTER TABLE $SCHEMA$.ga_events ADD COLUMN browser_version text;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN os_version text;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN device_brand text;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN device_model text;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN bot_name text;

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_device_type
  ON $SCHEMA$.ga_events (workspace_id, device_type, inserted_at DESC);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_browser
  ON $SCHEMA$.ga_events (workspace_id, browser, inserted_at DESC);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_os
  ON $SCHEMA$.ga_events (workspace_id, os, inserted_at DESC);

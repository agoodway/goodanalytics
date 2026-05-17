-- GoodAnalytics v07 — Rollback: drop host and path columns

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_host_path;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_path;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN path;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN host;

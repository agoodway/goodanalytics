-- GoodAnalytics v09 — Rollback: remove event-grain device columns and indexes.
-- Reverse order of v09_up.sql to respect dependencies.

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_os;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_browser;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_device_type;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN bot_name;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN device_model;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN device_brand;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN os_version;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN browser_version;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN os;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN browser;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN device_type;

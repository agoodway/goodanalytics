-- GoodAnalytics v02 — Rollback: remove connector dispatch table and signal columns

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN IF EXISTS connector_source_context;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors DROP COLUMN IF EXISTS connector_identifiers;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_connector_dispatches;

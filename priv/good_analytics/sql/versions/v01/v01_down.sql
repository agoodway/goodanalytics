-- GoodAnalytics v01 — Rollback: drop all tables and schema

DROP TABLE IF EXISTS $SCHEMA$.ga_settings;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_api_keys;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_domains;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_events_default;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_events;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_links;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_visitors;

--SPLIT--

DROP VIEW IF EXISTS $SCHEMA$.ga_version;

--SPLIT--

DROP SCHEMA IF EXISTS $SCHEMA$;

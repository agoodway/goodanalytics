-- GoodAnalytics v05 — Rollback: drop funnel definitions table and indexes

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_funnels_workspace;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_funnels_workspace_name;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_funnels;

-- GoodAnalytics v10 — Rollback: remove ga_events.session_id and ga_sessions.
-- Reverse order of v10_up.sql to respect dependencies.

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_session;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN session_id;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_sessions_workspace_started;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_sessions_visitor;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_sessions_anonymous_live;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_sessions_visitor_live;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_sessions;

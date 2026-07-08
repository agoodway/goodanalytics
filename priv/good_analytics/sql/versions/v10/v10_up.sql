-- GoodAnalytics v10 — Sessions
-- Adds ga_sessions (server-derived per-visitor visits) and ga_events.session_id.
--
-- ga_sessions is a plain, NON-partitioned table (like ga_visitors): the row is
-- mutable and UPDATEd in place on every event (started_at/last_event_at/
-- pageviews/duration/...). UUIDv7 ids are generated Elixir-side, not PG-native.
--
-- ga_events.session_id is added to the PARTITIONED parent; on Postgres 11+
-- ALTER TABLE ADD COLUMN and CREATE INDEX on the parent propagate to all
-- existing and future partitions automatically, matching v07/v08/v09.
--
-- DEPLOY RUNBOOK: Postgres does not support CREATE INDEX CONCURRENTLY on
-- partitioned parent tables. Before running this migration in production on a
-- large table, use the V04 pattern: create the parent partitioned index
-- metadata, create child partition indexes concurrently, then attach each child
-- index to the parent index. The simplified shape is:
--
--   CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_session
--     ON ONLY $SCHEMA$.ga_events (workspace_id, session_id, inserted_at DESC)
--     WHERE session_id IS NOT NULL;
--
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_<partition>_session
--     ON $SCHEMA$.<partition> (workspace_id, session_id, inserted_at DESC)
--     WHERE session_id IS NOT NULL;
--
--   ALTER INDEX $SCHEMA$.idx_ga_events_workspace_session
--     ATTACH PARTITION $SCHEMA$.idx_<partition>_session;
--
-- Once the attached partitioned index exists, the CREATE INDEX IF NOT EXISTS
-- statement below becomes a no-op.

-- ============================================================
-- GA_SESSIONS — Server-derived per-visitor visits (mutable OLTP row)
-- ============================================================
CREATE TABLE $SCHEMA$.ga_sessions (
  id UUID PRIMARY KEY,

  -- Scope & identity (a session belongs to a visitor; anonymous_id is the
  -- pre-identity fallback key used before identity resolution attaches a
  -- visitor_id).
  workspace_id UUID NOT NULL,
  visitor_id UUID NOT NULL,
  anonymous_id TEXT,

  -- Lifecycle window (sliding 30-min inactivity boundary).
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_event_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Entry/exit pages.
  entry_url TEXT,
  entry_page TEXT,
  exit_page TEXT,

  -- Counters.
  pageviews INT NOT NULL DEFAULT 0,
  events INT NOT NULL DEFAULT 0,

  -- Derived metrics.
  duration_seconds INT NOT NULL DEFAULT 0,
  engaged_seconds INT NOT NULL DEFAULT 0,
  is_bounce BOOLEAN NOT NULL DEFAULT TRUE,
  is_engaged BOOLEAN NOT NULL DEFAULT FALSE,

  -- First-touch acquisition within the session (the boundary signal).
  source_platform TEXT,
  source_medium TEXT,
  source_campaign TEXT,
  click_id UUID,

  -- Device context from the session's first event (event-grain, from v09).
  device_type TEXT,
  browser TEXT,
  os TEXT,

  -- Timestamps.
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

--SPLIT--

-- Live-session lookup: newest open session for a visitor in a workspace.
CREATE INDEX idx_ga_sessions_visitor_live
  ON $SCHEMA$.ga_sessions (workspace_id, visitor_id, last_event_at DESC);

--SPLIT--

-- Pre-identity fallback lookup by anonymous_id.
CREATE INDEX idx_ga_sessions_anonymous_live
  ON $SCHEMA$.ga_sessions (workspace_id, anonymous_id, last_event_at DESC)
  WHERE anonymous_id IS NOT NULL;

--SPLIT--

-- Reassignment on identity merge filters by visitor_id.
CREATE INDEX idx_ga_sessions_visitor
  ON $SCHEMA$.ga_sessions (visitor_id);

--SPLIT--

-- Time-range session reporting.
CREATE INDEX idx_ga_sessions_workspace_started
  ON $SCHEMA$.ga_sessions (workspace_id, started_at DESC);

--SPLIT--

-- ============================================================
-- GA_EVENTS — Add session_id (propagates to all partitions)
-- ============================================================
ALTER TABLE $SCHEMA$.ga_events ADD COLUMN session_id UUID;

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_session
  ON $SCHEMA$.ga_events (workspace_id, session_id, inserted_at DESC)
  WHERE session_id IS NOT NULL;

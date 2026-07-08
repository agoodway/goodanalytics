-- GoodAnalytics V11 — session-grain audience breakdown indexes.
--
-- ga_sessions is a plain, non-partitioned table. On large production tables,
-- prebuild these out-of-band first with CREATE INDEX CONCURRENTLY IF NOT EXISTS;
-- the IF NOT EXISTS statements below then become no-ops. If you do NOT prebuild,
-- the in-transaction (non-concurrent) builds below take a write-blocking lock on
-- ga_sessions for the duration of each build.
-- Mirrors the ga_events dimension indexes from v04/v09.
--
-- Current usage note: Core.Audience's session breakdown groups by the coalesced
-- value `coalesce(<dim>, '(not set)')`, so today these indexes accelerate the
-- workspace_id + started_at range scan but do NOT feed the GROUP BY directly
-- (the aggregate still hashes/sorts the evaluated expression). They fully pay
-- off once the breakdown GROUP BY is rewritten to group by the raw column
-- (deferred — see the plan's "Future Considerations").
--
-- Write-amplification note: these are non-partial (null dims bucket as
-- '(not set)', which the unfiltered breakdown must count). They index only
-- columns set at session creation (device/source/started_at) and never
-- mutated, so they do not by themselves break HOT updates — but per-event
-- UPDATEs to ga_sessions are ALREADY non-HOT because v10's *_live indexes
-- include last_event_at. So the added cost here is index maintenance per
-- session *creation*, not per subsequent event update. Benchmark write
-- throughput on a representative workspace before prod rollout.

CREATE INDEX IF NOT EXISTS idx_ga_sessions_workspace_device_type_started
  ON $SCHEMA$.ga_sessions (workspace_id, device_type, started_at DESC);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_sessions_workspace_browser_started
  ON $SCHEMA$.ga_sessions (workspace_id, browser, started_at DESC);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_sessions_workspace_os_started
  ON $SCHEMA$.ga_sessions (workspace_id, os, started_at DESC);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_sessions_workspace_source_platform_started
  ON $SCHEMA$.ga_sessions (workspace_id, source_platform, started_at DESC);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_sessions_workspace_source_medium_started
  ON $SCHEMA$.ga_sessions (workspace_id, source_medium, started_at DESC);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_sessions_workspace_source_campaign_started
  ON $SCHEMA$.ga_sessions (workspace_id, source_campaign, started_at DESC);

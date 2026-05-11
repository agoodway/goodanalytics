-- GoodAnalytics v04 — Add composite performance indexes
--
-- Note: ga_events is a partitioned table. Postgres does NOT support
-- CREATE INDEX CONCURRENTLY on partitioned tables; building these
-- indexes acquires a SHARE lock on each partition while the partition's
-- index is built (writes to that partition block during the build,
-- though other partitions remain writable).
--
-- For production deploys against very large partitions, consider:
--   1. CREATE INDEX ON ONLY parent (metadata-only, fast)
--   2. CREATE INDEX CONCURRENTLY on each child partition individually
--   3. ALTER INDEX parent ATTACH PARTITION child_index
-- That sequence keeps each partition writable during its build.

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_link_type
  ON $SCHEMA$.ga_events (workspace_id, link_id, event_type, inserted_at DESC)
  WHERE link_id IS NOT NULL;

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_visitors_workspace_first_click_id
  ON $SCHEMA$.ga_visitors (workspace_id, first_click_id)
  WHERE first_click_id IS NOT NULL;

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_inserted_visitor
  ON $SCHEMA$.ga_events (workspace_id, inserted_at DESC, visitor_id);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_type_inserted
  ON $SCHEMA$.ga_events (workspace_id, event_type, inserted_at DESC);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_source_inserted_pageview
  ON $SCHEMA$.ga_events (workspace_id, source_platform, source_medium, inserted_at DESC)
  WHERE event_type = 'pageview';

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_campaign_inserted
  ON $SCHEMA$.ga_events (workspace_id, source_campaign, inserted_at DESC)
  WHERE source_campaign IS NOT NULL;

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_url_inserted_pageview
  ON $SCHEMA$.ga_events (workspace_id, url, inserted_at DESC)
  WHERE event_type = 'pageview' AND url IS NOT NULL;

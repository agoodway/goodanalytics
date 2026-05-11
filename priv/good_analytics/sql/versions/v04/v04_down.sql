-- GoodAnalytics v04 — Rollback: remove composite performance indexes
-- DROP is non-CONCURRENT because Postgres does not support
-- DROP INDEX CONCURRENTLY on partitioned indexes (ga_events is partitioned).

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_url_inserted_pageview;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_campaign_inserted;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_source_inserted_pageview;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_type_inserted;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_inserted_visitor;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_visitors_workspace_first_click_id;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_link_type;

-- GoodAnalytics V13 — custom event connector mappings.

CREATE TABLE $SCHEMA$.ga_connector_event_mappings (
  id UUID PRIMARY KEY,
  workspace_id UUID NOT NULL,
  event_name TEXT NOT NULL,
  connector_type TEXT NOT NULL,
  connector_event_name TEXT,
  config JSONB NOT NULL DEFAULT '{}',
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_ga_connector_event_mappings_event_name_nonblank
    CHECK (btrim(event_name) <> ''),
  CONSTRAINT chk_ga_connector_event_mappings_connector_type_nonblank
    CHECK (btrim(connector_type) <> ''),
  CONSTRAINT chk_ga_connector_event_mappings_connector_event_name_nonblank
    CHECK (connector_event_name IS NULL OR btrim(connector_event_name) <> '')
);

--SPLIT--

CREATE UNIQUE INDEX IF NOT EXISTS idx_ga_connector_event_mappings_workspace_event_connector
  ON $SCHEMA$.ga_connector_event_mappings (workspace_id, event_name, connector_type);

--SPLIT--

-- Serves list_mappings/2 (workspace_id + connector_type, including disabled rows).
-- `enabled` is intentionally NOT trailing here: enabled-only reads use the partial
-- index below, which is smaller and covering for event_name.
CREATE INDEX IF NOT EXISTS idx_ga_connector_event_mappings_workspace_connector
  ON $SCHEMA$.ga_connector_event_mappings (workspace_id, connector_type);

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_connector_event_mappings_enabled_events
  ON $SCHEMA$.ga_connector_event_mappings (workspace_id, connector_type, event_name)
  WHERE enabled = TRUE;

--SPLIT--

-- Bounds reconciliation lookups of mapped custom events by workspace, event name,
-- and event time.
--
-- ga_events is PARTITIONED BY RANGE(inserted_at). The CREATE INDEX on the parent
-- below propagates to all existing and future partitions, but takes a
-- write-blocking lock per partition for the duration of the build — fine for
-- dev/test; for a large production table prebuild out-of-band using the v04/v10/v12
-- runbook (Postgres forbids CREATE INDEX CONCURRENTLY on a partitioned parent):
--
--   CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_custom_event_name_inserted
--     ON ONLY $SCHEMA$.ga_events (workspace_id, event_name, inserted_at DESC)
--     WHERE event_type = 'custom';
--
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_<partition>_custom_event_name_inserted
--     ON $SCHEMA$.<partition> (workspace_id, event_name, inserted_at DESC)
--     WHERE event_type = 'custom';
--
--   ALTER INDEX $SCHEMA$.idx_ga_events_workspace_custom_event_name_inserted
--     ATTACH PARTITION $SCHEMA$.idx_<partition>_custom_event_name_inserted;
--
-- Once the attached partitioned index exists, the statement below is a no-op.
CREATE INDEX IF NOT EXISTS idx_ga_events_workspace_custom_event_name_inserted
  ON $SCHEMA$.ga_events (workspace_id, event_name, inserted_at DESC)
  WHERE event_type = 'custom';

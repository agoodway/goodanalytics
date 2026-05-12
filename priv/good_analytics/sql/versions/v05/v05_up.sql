-- GoodAnalytics v05 — Funnel definitions table
-- Stores workspace-scoped funnel definitions with ordered step matchers,
-- conversion window, and optional cohort-level source filter.
-- Soft-archived via archived_at; no hard deletes.

CREATE TABLE $SCHEMA$.ga_funnels (
  id UUID PRIMARY KEY,
  workspace_id UUID NOT NULL,

  -- Funnel definition
  name TEXT NOT NULL,
  description TEXT,
  steps JSONB NOT NULL,
  conversion_window_days INT NOT NULL DEFAULT 7,
  cohort_source_filter JSONB,

  -- Lifecycle
  archived_at TIMESTAMPTZ,

  -- Timestamps
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

--SPLIT--

-- Unique name per workspace among non-archived funnels; archived names are reusable
CREATE UNIQUE INDEX idx_ga_funnels_workspace_name
  ON $SCHEMA$.ga_funnels (workspace_id, name)
  WHERE archived_at IS NULL;

--SPLIT--

-- List queries: all funnels for a workspace
CREATE INDEX idx_ga_funnels_workspace
  ON $SCHEMA$.ga_funnels (workspace_id);

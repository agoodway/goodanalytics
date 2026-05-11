-- GoodAnalytics v02 — Connector dispatch persistence and signal columns
-- Adds: ga_connector_dispatches table, visitor connector identifier columns,
-- event connector source context column.

-- ============================================================
-- CONNECTOR DISPATCHES — Durable outbound delivery records
-- ============================================================
CREATE TABLE $SCHEMA$.ga_connector_dispatches (
  id UUID PRIMARY KEY,
  workspace_id UUID NOT NULL,

  -- Connector identity
  connector_type TEXT NOT NULL,
  connector_event_id TEXT NOT NULL,

  -- Source event reference
  event_id UUID NOT NULL,
  event_inserted_at TIMESTAMPTZ NOT NULL,

  -- Visitor reference
  visitor_id UUID NOT NULL,

  -- Payload and rebuild context
  payload_snapshot JSONB NOT NULL DEFAULT '{}',
  source_context JSONB NOT NULL DEFAULT '{}',

  -- Delivery status
  status TEXT NOT NULL DEFAULT 'pending',
  CONSTRAINT chk_dispatch_status CHECK (
    status IN ('pending', 'delivering', 'delivered', 'failed', 'credential_error', 'rate_limited', 'skipped_disabled', 'permanently_failed')
  ),

  -- Attempt tracking
  attempts INT NOT NULL DEFAULT 0,
  max_attempts INT NOT NULL DEFAULT 5,
  last_attempted_at TIMESTAMPTZ,
  next_retry_at TIMESTAMPTZ,

  -- Response metadata
  response_status INT,
  response_body JSONB,
  error_type TEXT,
  error_message TEXT,

  -- Replay metadata
  replayed_from_id UUID,
  replayed_at TIMESTAMPTZ,

  -- Timestamps
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

--SPLIT--

-- Stable connector event id must be unique per connector type
CREATE UNIQUE INDEX idx_ga_connector_dispatches_event_id
  ON $SCHEMA$.ga_connector_dispatches (connector_type, connector_event_id);

--SPLIT--

-- Lookup by source event (for reconciliation and audit)
CREATE INDEX idx_ga_connector_dispatches_source_event
  ON $SCHEMA$.ga_connector_dispatches (event_id, event_inserted_at);

--SPLIT--

-- Workspace + connector type for per-workspace queries
CREATE INDEX idx_ga_connector_dispatches_workspace
  ON $SCHEMA$.ga_connector_dispatches (workspace_id, connector_type, inserted_at DESC);

--SPLIT--

-- Delivery queue: pending/retryable dispatches ordered by next retry
CREATE INDEX idx_ga_connector_dispatches_pending
  ON $SCHEMA$.ga_connector_dispatches (connector_type, next_retry_at)
  WHERE status IN ('pending', 'failed', 'rate_limited');

--SPLIT--

-- Credential errors per workspace+connector for pause logic
CREATE INDEX idx_ga_connector_dispatches_credential_errors
  ON $SCHEMA$.ga_connector_dispatches (workspace_id, connector_type)
  WHERE status = 'credential_error';

--SPLIT--

-- ============================================================
-- VISITOR COLUMNS — Connector browser identifiers
-- ============================================================
-- Meta browser identifiers
ALTER TABLE $SCHEMA$.ga_visitors ADD COLUMN connector_identifiers JSONB DEFAULT '{}';

--SPLIT--

-- ============================================================
-- EVENT COLUMNS — Connector source context snapshot
-- ============================================================
-- Preserved at event time for deterministic connector payload rebuilds
ALTER TABLE $SCHEMA$.ga_events ADD COLUMN connector_source_context JSONB;

-- GoodAnalytics v01 — Initial schema
-- All objects live in the $SCHEMA$ schema with ga_ prefix.
-- UUIDv7 primary keys are generated Elixir-side (not PG-native).

CREATE SCHEMA IF NOT EXISTS $SCHEMA$;

--SPLIT--

-- Tracking view for ecto_evolver version management
CREATE OR REPLACE VIEW $SCHEMA$.ga_version AS SELECT 1 AS placeholder;

--SPLIT--

-- ============================================================
-- VISITORS — The central identity graph
-- ============================================================
CREATE TABLE $SCHEMA$.ga_visitors (
  id UUID PRIMARY KEY,

  -- Scope (multi-tenant via workspace_id, sentinel UUID for single-tenant)
  workspace_id UUID NOT NULL,

  -- Identity Signals (arrays — visitor can have multiple)
  fingerprints TEXT[] DEFAULT '{}',
  anonymous_ids TEXT[] DEFAULT '{}',
  click_ids UUID[] DEFAULT '{}',

  -- Current active ga_id cookie value
  ga_id TEXT,

  -- Resolved Identity (post-signup)
  customer_external_id TEXT,
  customer_email TEXT,
  customer_name TEXT,
  customer_metadata JSONB DEFAULT '{}',

  -- First-Touch Attribution
  first_source JSONB,
  first_click_id UUID,
  first_partner_id UUID,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Last-Touch Attribution
  last_source JSONB,
  last_click_id UUID,
  last_partner_id UUID,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Multi-Touch Attribution Path (capped at 50 touchpoints)
  attribution_path JSONB DEFAULT '[]',

  -- Ad Platform Click IDs (captured from URL params)
  click_id_params JSONB DEFAULT '{}',

  -- Geo & Device Profile (enriched over time, latest values)
  geo JSONB DEFAULT '{}',
  device JSONB DEFAULT '{}',

  -- Behavioral Summary (rolled up from events periodically)
  total_sessions INT NOT NULL DEFAULT 0,
  total_pageviews INT NOT NULL DEFAULT 0,
  total_events INT NOT NULL DEFAULT 0,
  total_time_seconds INT NOT NULL DEFAULT 0,
  avg_scroll_depth NUMERIC,
  top_pages JSONB DEFAULT '[]',

  -- Scores
  lead_quality_score NUMERIC,
  fraud_risk_score NUMERIC,

  -- Lifecycle
  status TEXT NOT NULL DEFAULT 'anonymous',
  CONSTRAINT chk_visitor_status CHECK (status IN ('anonymous','identified','lead','customer','churned','merged')),
  merged_into_id UUID,
  identified_at TIMESTAMPTZ,
  converted_at TIMESTAMPTZ,
  ltv_cents BIGINT NOT NULL DEFAULT 0,

  -- Timestamps
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

--SPLIT--

-- Identity resolution indexes (HOT PATH)
CREATE INDEX idx_ga_visitors_fingerprints ON $SCHEMA$.ga_visitors USING GIN (fingerprints);

--SPLIT--

CREATE INDEX idx_ga_visitors_anonymous_ids ON $SCHEMA$.ga_visitors USING GIN (anonymous_ids);

--SPLIT--

CREATE INDEX idx_ga_visitors_click_ids ON $SCHEMA$.ga_visitors USING GIN (click_ids);

--SPLIT--

CREATE INDEX idx_ga_visitors_ga_id ON $SCHEMA$.ga_visitors (workspace_id, ga_id) WHERE ga_id IS NOT NULL;

--SPLIT--

CREATE UNIQUE INDEX idx_ga_visitors_customer
  ON $SCHEMA$.ga_visitors (workspace_id, customer_external_id)
  WHERE customer_external_id IS NOT NULL;

--SPLIT--

CREATE INDEX idx_ga_visitors_workspace ON $SCHEMA$.ga_visitors (workspace_id);

--SPLIT--

CREATE INDEX idx_ga_visitors_status ON $SCHEMA$.ga_visitors (workspace_id, status);

--SPLIT--

CREATE INDEX idx_ga_visitors_first_seen ON $SCHEMA$.ga_visitors (workspace_id, first_seen_at DESC);

--SPLIT--

CREATE INDEX idx_ga_visitors_merged_into ON $SCHEMA$.ga_visitors (merged_into_id) WHERE merged_into_id IS NOT NULL;

--SPLIT--

CREATE INDEX idx_ga_visitors_last_seen ON $SCHEMA$.ga_visitors (workspace_id, last_seen_at DESC);

--SPLIT--

CREATE INDEX idx_ga_visitors_email ON $SCHEMA$.ga_visitors (workspace_id, customer_email) WHERE customer_email IS NOT NULL;

--SPLIT--

-- ============================================================
-- LINKS — Short links, referral links, campaign links
-- ============================================================
CREATE TABLE $SCHEMA$.ga_links (
  id UUID PRIMARY KEY,
  workspace_id UUID NOT NULL,

  -- Link definition
  domain TEXT NOT NULL,
  key TEXT NOT NULL,
  url TEXT NOT NULL,

  -- Link type
  link_type TEXT NOT NULL DEFAULT 'short',
  CONSTRAINT chk_link_type CHECK (link_type IN ('short','referral','campaign')),

  -- Campaign tracking
  utm_source TEXT,
  utm_medium TEXT,
  utm_campaign TEXT,
  utm_content TEXT,
  utm_term TEXT,

  -- Configuration
  password_hash TEXT,
  expires_at TIMESTAMPTZ,
  ios_url TEXT,
  android_url TEXT,
  geo_targeting JSONB DEFAULT '{}',
  og_title TEXT,
  og_description TEXT,
  og_image TEXT,

  -- Analytics rollups (updated async)
  total_clicks INT NOT NULL DEFAULT 0,
  unique_clicks INT NOT NULL DEFAULT 0,
  total_leads INT NOT NULL DEFAULT 0,
  total_sales INT NOT NULL DEFAULT 0,
  total_revenue_cents BIGINT NOT NULL DEFAULT 0,

  -- Metadata
  tags TEXT[] DEFAULT '{}',
  external_id TEXT,
  metadata JSONB DEFAULT '{}',

  -- Timestamps
  archived_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

--SPLIT--

-- Partial unique: only enforced on non-archived links
CREATE UNIQUE INDEX idx_ga_links_domain_key ON $SCHEMA$.ga_links (domain, key) WHERE archived_at IS NULL;

--SPLIT--

CREATE INDEX idx_ga_links_workspace ON $SCHEMA$.ga_links (workspace_id);

--SPLIT--

CREATE INDEX idx_ga_links_type ON $SCHEMA$.ga_links (workspace_id, link_type);

--SPLIT--

CREATE INDEX idx_ga_links_metadata ON $SCHEMA$.ga_links USING GIN (metadata);

--SPLIT--

CREATE UNIQUE INDEX idx_ga_links_external_id
  ON $SCHEMA$.ga_links (workspace_id, external_id)
  WHERE external_id IS NOT NULL AND archived_at IS NULL;

--SPLIT--

-- ============================================================
-- EVENTS — Unified event stream (partitioned by month)
-- ============================================================
CREATE TABLE $SCHEMA$.ga_events (
  id UUID NOT NULL,
  workspace_id UUID NOT NULL,
  visitor_id UUID NOT NULL,

  -- Event classification
  event_type TEXT NOT NULL,
  event_name TEXT,

  -- Link context
  link_id UUID,
  click_id UUID,

  -- Page context
  url TEXT,
  referrer TEXT,
  referrer_url TEXT,

  -- Source classification (computed at ingest, promoted for OLAP readiness)
  source_platform TEXT,
  source_medium TEXT,
  source_campaign TEXT,
  source JSONB DEFAULT '{}',

  -- Raw capture data
  fingerprint TEXT,
  ip_address INET,
  user_agent TEXT,

  -- Promoted properties (OLAP readiness)
  amount_cents BIGINT,
  currency TEXT,

  -- Flexible properties (schema varies by event_type)
  properties JSONB DEFAULT '{}',

  -- Timestamps
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (id, inserted_at)
) PARTITION BY RANGE (inserted_at);

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD CONSTRAINT chk_event_type
  CHECK (event_type IN ('link_click','pageview','session_start','identify','lead','sale','share','engagement','custom'));

--SPLIT--

-- Safety-net partition: catches rows that don't match any monthly partition
CREATE TABLE $SCHEMA$.ga_events_default PARTITION OF $SCHEMA$.ga_events DEFAULT;

--SPLIT--

CREATE INDEX idx_ga_events_visitor ON $SCHEMA$.ga_events (visitor_id, inserted_at DESC);

--SPLIT--

CREATE INDEX idx_ga_events_type ON $SCHEMA$.ga_events (event_type, inserted_at DESC);

--SPLIT--

CREATE INDEX idx_ga_events_link ON $SCHEMA$.ga_events (link_id, inserted_at DESC) WHERE link_id IS NOT NULL;

--SPLIT--

CREATE INDEX idx_ga_events_workspace ON $SCHEMA$.ga_events (workspace_id, inserted_at DESC);

--SPLIT--

CREATE INDEX idx_ga_events_click_id ON $SCHEMA$.ga_events (click_id) WHERE click_id IS NOT NULL;

--SPLIT--

CREATE INDEX idx_ga_events_source ON $SCHEMA$.ga_events (source_platform, source_medium, inserted_at DESC);

--SPLIT--

-- ============================================================
-- DOMAINS — Custom short link domains
-- ============================================================
CREATE TABLE $SCHEMA$.ga_domains (
  id UUID PRIMARY KEY,
  workspace_id UUID NOT NULL,
  domain TEXT NOT NULL UNIQUE,
  verified BOOLEAN NOT NULL DEFAULT false,
  verified_at TIMESTAMPTZ,
  default_url TEXT,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

--SPLIT--

-- ============================================================
-- API_KEYS — Two-tier auth
-- ============================================================
CREATE TABLE $SCHEMA$.ga_api_keys (
  id UUID PRIMARY KEY,
  workspace_id UUID NOT NULL,
  key_type TEXT NOT NULL,
  CONSTRAINT chk_key_type CHECK (key_type IN ('secret','publishable')),
  key_hash TEXT NOT NULL,
  key_prefix TEXT NOT NULL,
  allowed_hostnames TEXT[] DEFAULT '{}',
  name TEXT,
  last_used_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ
);

--SPLIT--

CREATE UNIQUE INDEX idx_ga_api_keys_hash ON $SCHEMA$.ga_api_keys (key_hash) WHERE revoked_at IS NULL;

--SPLIT--

CREATE INDEX idx_ga_api_keys_workspace ON $SCHEMA$.ga_api_keys (workspace_id);

--SPLIT--

-- ============================================================
-- SETTINGS — Per-workspace runtime settings
-- ============================================================
CREATE TABLE $SCHEMA$.ga_settings (
  id UUID PRIMARY KEY,
  workspace_id UUID NOT NULL,
  key TEXT NOT NULL,
  value JSONB NOT NULL,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(workspace_id, key)
);

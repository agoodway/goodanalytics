-- GoodAnalytics v08 — Core referral partners and partner attribution
-- Adds ga_partners table, partner_id on ga_links, referral context
-- columns on ga_visitors, and partner attribution snapshots on ga_events.
--
-- DEPLOY RUNBOOK: Before running in production, create indexes
-- concurrently out-of-band to avoid ACCESS EXCLUSIVE locks:
--
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ga_links_partner
--     ON $SCHEMA$.ga_links (workspace_id, partner_id)
--     WHERE partner_id IS NOT NULL;
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ga_events_partner
--     ON $SCHEMA$.ga_events (workspace_id, partner_id, inserted_at DESC)
--     WHERE partner_id IS NOT NULL;
--
-- Once the concurrent indexes exist, the CREATE INDEX IF NOT EXISTS
-- statements below become no-ops.
--
-- After creating concurrent indexes on the parent, verify ALL existing
-- partitions have the index. For each partition:
--
--   SELECT relname FROM pg_class c
--     JOIN pg_inherits i ON c.oid = i.inhrelid
--     JOIN pg_class p ON i.inhparent = p.oid
--     WHERE p.relname = 'ga_events';
--
-- Then for each partition:
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_<partition>_partner
--     ON $SCHEMA$.<partition> (workspace_id, partner_id, inserted_at DESC)
--     WHERE partner_id IS NOT NULL;

-- ============================================================
-- GA_PARTNERS — Core-owned referral partner identity
-- ============================================================
CREATE TABLE $SCHEMA$.ga_partners (
  id UUID PRIMARY KEY,
  workspace_id UUID NOT NULL,

  -- Partner identity
  key TEXT NOT NULL,
  name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  CONSTRAINT chk_partner_status CHECK (status IN ('active','disabled','archived')),

  -- Optional external reference
  external_id TEXT,
  metadata JSONB DEFAULT '{}',

  -- Timestamps
  archived_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

--SPLIT--

-- Active partner key must be unique per workspace (archived partners free their key)
CREATE UNIQUE INDEX idx_ga_partners_workspace_key
  ON $SCHEMA$.ga_partners (workspace_id, key)
  WHERE status = 'active' OR status = 'disabled';

--SPLIT--

-- Active external_id must be unique per workspace
CREATE UNIQUE INDEX idx_ga_partners_workspace_external_id
  ON $SCHEMA$.ga_partners (workspace_id, external_id)
  WHERE external_id IS NOT NULL AND (status = 'active' OR status = 'disabled');

--SPLIT--

CREATE INDEX idx_ga_partners_status
  ON $SCHEMA$.ga_partners (workspace_id, status);

--SPLIT--

-- ============================================================
-- GA_VISITORS — Add missing person_phone column (pre-existing schema gap)
-- ============================================================
-- NOTE: person_phone was defined in the Ecto schema since v01 but never
-- added to the database. This column is owned by v08 for rollback purposes.
ALTER TABLE $SCHEMA$.ga_visitors ADD COLUMN IF NOT EXISTS person_phone TEXT;

--SPLIT--

-- ============================================================
-- GA_LINKS — Add partner_id for referral link association
-- ============================================================
ALTER TABLE $SCHEMA$.ga_links ADD COLUMN partner_id UUID;

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_links_partner
  ON $SCHEMA$.ga_links (workspace_id, partner_id)
  WHERE partner_id IS NOT NULL;

--SPLIT--

-- ============================================================
-- GA_VISITORS — Add referral link/click context columns
-- ============================================================
-- first/last_partner_id already exist from v01.
-- Add referral link and click context for attribution reporting.
ALTER TABLE $SCHEMA$.ga_visitors ADD COLUMN first_referral_link_id UUID;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors ADD COLUMN first_referral_click_id UUID;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors ADD COLUMN last_referral_link_id UUID;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors ADD COLUMN last_referral_click_id UUID;

--SPLIT--

-- ============================================================
-- GA_EVENTS — Add partner attribution snapshot columns
-- ============================================================
ALTER TABLE $SCHEMA$.ga_events ADD COLUMN partner_id UUID;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN referral_link_id UUID;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD COLUMN referral_click_id UUID;

--SPLIT--

CREATE INDEX IF NOT EXISTS idx_ga_events_partner
  ON $SCHEMA$.ga_events (workspace_id, partner_id, inserted_at DESC)
  WHERE partner_id IS NOT NULL;

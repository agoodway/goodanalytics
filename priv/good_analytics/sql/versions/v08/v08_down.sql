-- GoodAnalytics v08 — Rollback: remove partner attribution columns and ga_partners table
-- Reverse order of v08_up.sql to respect dependencies.

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_partner;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN referral_click_id;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN referral_link_id;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events DROP COLUMN partner_id;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors DROP COLUMN last_referral_click_id;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors DROP COLUMN last_referral_link_id;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors DROP COLUMN first_referral_click_id;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors DROP COLUMN first_referral_link_id;

--SPLIT--

-- person_phone was first added by v08 (despite being in the Ecto schema since v01)
ALTER TABLE $SCHEMA$.ga_visitors DROP COLUMN IF EXISTS person_phone;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_links_partner;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_links DROP COLUMN partner_id;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_partners_status;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_partners_workspace_external_id;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_partners_workspace_key;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_partners;

-- GoodAnalytics v06 — Rollback: remove api_request from event type constraint

ALTER TABLE $SCHEMA$.ga_events DROP CONSTRAINT chk_event_type;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD CONSTRAINT chk_event_type
  CHECK (event_type IN ('link_click','pageview','session_start','identify','lead','sale','share','engagement','custom'));

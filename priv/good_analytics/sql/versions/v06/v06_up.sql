-- GoodAnalytics v06 — Add api_request to event type constraint
-- The RequestLoggerPlug records api_request events; the existing
-- chk_event_type constraint on ga_events must include this value
-- or INSERTs will be rejected by the DB.

ALTER TABLE $SCHEMA$.ga_events DROP CONSTRAINT chk_event_type;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_events ADD CONSTRAINT chk_event_type
  CHECK (event_type IN ('link_click','pageview','session_start','identify','lead','sale','share','engagement','custom','api_request'));

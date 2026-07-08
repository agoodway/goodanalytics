DROP INDEX IF EXISTS $SCHEMA$.idx_ga_events_workspace_custom_event_name_inserted;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_connector_event_mappings_enabled_events;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_connector_event_mappings_workspace_connector;

--SPLIT--

DROP INDEX IF EXISTS $SCHEMA$.idx_ga_connector_event_mappings_workspace_event_connector;

--SPLIT--

DROP TABLE IF EXISTS $SCHEMA$.ga_connector_event_mappings;

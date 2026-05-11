-- GoodAnalytics v03 — Rollback: restore customer_* column and index names

ALTER INDEX $SCHEMA$.idx_ga_visitors_person_email RENAME TO idx_ga_visitors_email;

--SPLIT--

ALTER INDEX $SCHEMA$.idx_ga_visitors_person_external_id RENAME TO idx_ga_visitors_customer;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors RENAME COLUMN person_metadata TO customer_metadata;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors RENAME COLUMN person_name TO customer_name;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors RENAME COLUMN person_email TO customer_email;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors RENAME COLUMN person_external_id TO customer_external_id;

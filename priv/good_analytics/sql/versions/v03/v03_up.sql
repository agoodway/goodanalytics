-- GoodAnalytics v03 — Rename customer_* columns to person_* on ga_visitors
--
-- The customer_ prefix was overloaded with the `customer` value in the
-- `status` enum and prejudged the host application's relationship type.
-- The neutral `person_` prefix names these for what they are: the host
-- app's projection of who the visitor is, populated whether or not the
-- visitor has reached `customer` lifecycle status.
--
-- All renames preserve data and indexes; ALTER ... RENAME COLUMN /
-- RENAME TO are atomic in PostgreSQL.

ALTER TABLE $SCHEMA$.ga_visitors RENAME COLUMN customer_external_id TO person_external_id;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors RENAME COLUMN customer_email TO person_email;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors RENAME COLUMN customer_name TO person_name;

--SPLIT--

ALTER TABLE $SCHEMA$.ga_visitors RENAME COLUMN customer_metadata TO person_metadata;

--SPLIT--

ALTER INDEX $SCHEMA$.idx_ga_visitors_customer RENAME TO idx_ga_visitors_person_external_id;

--SPLIT--

ALTER INDEX $SCHEMA$.idx_ga_visitors_email RENAME TO idx_ga_visitors_person_email;

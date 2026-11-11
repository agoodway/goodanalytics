-- Data repair is intentionally irreversible: the 'nil' strings were a bug, and
-- restoring them would reintroduce a fake source value.
SELECT 1;

-- NOTE: this migration scans ga_events and ga_sessions in full. The workspace-
-- leading indexes on source_campaign exist (partial on ga_events), but they
-- cannot serve this lookup: the WHERE clause is an OR across three columns with
-- no workspace_id predicate. The UPDATE also maintains those indexes as it
-- rewrites rows. On large partitioned installs that is a long sequential scan
-- and rewrites every affected row once; run it in a quiet window or repair
-- partitions individually (UPDATE each child table) if that is too slow.

-- Repair the literal string 'nil' that older recorders wrote into the source
-- columns when an event or session had no source (nil is an atom, so it was
-- stringified). Real sources are untouched; only the exact value 'nil' becomes
-- NULL. Idempotent. One UPDATE per table rewrites each affected row once.
UPDATE $SCHEMA$.ga_events
SET source_platform = NULLIF(source_platform, 'nil'),
    source_medium = NULLIF(source_medium, 'nil'),
    source_campaign = NULLIF(source_campaign, 'nil')
WHERE source_platform = 'nil'
   OR source_medium = 'nil'
   OR source_campaign = 'nil';

--SPLIT--

UPDATE $SCHEMA$.ga_sessions
SET source_platform = NULLIF(source_platform, 'nil'),
    source_medium = NULLIF(source_medium, 'nil'),
    source_campaign = NULLIF(source_campaign, 'nil')
WHERE source_platform = 'nil'
   OR source_medium = 'nil'
   OR source_campaign = 'nil';

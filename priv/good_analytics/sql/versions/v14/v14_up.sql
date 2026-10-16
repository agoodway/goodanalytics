-- Recover identifier memberships lost by pre-V14 visitor merges. Only follow
-- recorded merge edges within one workspace; never infer a new person match.
-- Serialize with writes AND row-locking reads used by merges, avoiding a lock
-- upgrade deadlock between a merge and the repair. Ordinary reads can continue.
-- Run in a transaction so the lock covers the snapshot and survivor update.
LOCK TABLE $SCHEMA$.ga_visitors IN EXCLUSIVE MODE;

--SPLIT--

WITH RECURSIVE families(survivor_id, workspace_id, member_id) AS (
  SELECT survivor.id, survivor.workspace_id, survivor.id
  FROM $SCHEMA$.ga_visitors survivor
  WHERE survivor.status <> 'merged'
    AND EXISTS (
      SELECT 1 FROM $SCHEMA$.ga_visitors child
      WHERE child.merged_into_id = survivor.id
        AND child.workspace_id = survivor.workspace_id
        AND child.status = 'merged'
    )
  UNION
  SELECT family.survivor_id, family.workspace_id, child.id
  FROM families family
  JOIN $SCHEMA$.ga_visitors child
    ON child.merged_into_id = family.member_id
   AND child.workspace_id = family.workspace_id
   AND child.status = 'merged'
), members AS MATERIALIZED (
  SELECT family.survivor_id, family.workspace_id,
         visitor.anonymous_ids, visitor.fingerprints, visitor.click_ids
  FROM families family
  JOIN $SCHEMA$.ga_visitors visitor ON visitor.id = family.member_id
), anonymous_ids AS (
  SELECT survivor_id, workspace_id, array_agg(DISTINCT value ORDER BY value) AS identifiers
  FROM members CROSS JOIN LATERAL unnest(anonymous_ids) AS identifier(value)
  WHERE value IS NOT NULL
  GROUP BY survivor_id, workspace_id
), fingerprints AS (
  SELECT survivor_id, workspace_id, array_agg(DISTINCT value ORDER BY value) AS identifiers
  FROM members CROSS JOIN LATERAL unnest(fingerprints) AS identifier(value)
  WHERE value IS NOT NULL
  GROUP BY survivor_id, workspace_id
), click_ids AS (
  SELECT survivor_id, workspace_id, array_agg(DISTINCT value ORDER BY value) AS identifiers
  FROM members CROSS JOIN LATERAL unnest(click_ids) AS identifier(value)
  WHERE value IS NOT NULL
  GROUP BY survivor_id, workspace_id
), recovered AS (
  SELECT target.survivor_id, target.workspace_id,
         COALESCE(anon.identifiers, '{}'::text[]) AS anonymous_ids,
         COALESCE(fp.identifiers, '{}'::text[]) AS fingerprints,
         COALESCE(click.identifiers, '{}'::uuid[]) AS click_ids
  FROM (SELECT DISTINCT survivor_id, workspace_id FROM families) target
  LEFT JOIN anonymous_ids anon USING (survivor_id, workspace_id)
  LEFT JOIN fingerprints fp USING (survivor_id, workspace_id)
  LEFT JOIN click_ids click USING (survivor_id, workspace_id)
)
UPDATE $SCHEMA$.ga_visitors survivor
SET anonymous_ids = recovered.anonymous_ids,
    fingerprints = recovered.fingerprints,
    click_ids = recovered.click_ids,
    updated_at = CURRENT_TIMESTAMP
FROM recovered
WHERE survivor.id = recovered.survivor_id
  AND survivor.workspace_id = recovered.workspace_id
  AND (survivor.anonymous_ids, survivor.fingerprints, survivor.click_ids)
      IS DISTINCT FROM
      (recovered.anonymous_ids, recovered.fingerprints, recovered.click_ids);

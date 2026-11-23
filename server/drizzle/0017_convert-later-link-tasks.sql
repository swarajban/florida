WITH targets(title, url, site) AS (VALUES
  ('Agent Readiness Reports | Factory', 'https://factory.com/agent-readiness', 'factory.com'),
  ('A new shape for work', 'https://www.notion.com/a-new-shape-for-work', 'www.notion.com')
), candidates AS MATERIALIZED (
  SELECT t.id, t.title, targets.url, targets.site, t.created_at
  FROM tasks t
  JOIN targets ON t.title = targets.title AND t.source->>'url' = targets.url
  WHERE t.deleted_at IS NULL AND t.completed_at IS NULL
    AND t.recurrence IS NULL AND t.recurrence_series_id IS NULL AND coalesce(trim(t.notes), '') = ''
  FOR UPDATE OF t
), inserted AS (
  INSERT INTO later_items (id, url, canonical_url, title, site, kind, saved_at, source, updated_at)
  SELECT 'later:task:' || c.id, c.url, c.url, c.title, c.site, 'article', c.created_at, 'manual',
    date_trunc('milliseconds', statement_timestamp())
  FROM candidates c
  WHERE NOT EXISTS (SELECT 1 FROM later_items l WHERE l.canonical_url = c.url AND l.deleted_at IS NULL)
  ON CONFLICT (id) DO NOTHING
  RETURNING id
)
UPDATE tasks t
SET deleted_at = date_trunc('milliseconds', statement_timestamp()),
    updated_at = date_trunc('milliseconds', statement_timestamp())
FROM candidates c
WHERE t.id = c.id AND (
  EXISTS (SELECT 1 FROM inserted WHERE id = 'later:task:' || c.id)
  OR EXISTS (SELECT 1 FROM later_items l WHERE l.canonical_url = c.url AND l.deleted_at IS NULL)
);

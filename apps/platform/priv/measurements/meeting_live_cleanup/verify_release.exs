# Read-only bounded output: source counts and a digest of protected identities
# and deletion state. Compare protected_digest before/after the one-off.
result =
  Platform.Repo.query!("""
  SELECT count(*) AS protected_count,
   md5(coalesce(string_agg(id::text || ':' || coalesce(deleted_at::text, 'null'), ',' ORDER BY id), '')) AS protected_digest
  FROM tasks WHERE metadata->>'source' = 'meetings.triage' OR metadata->>'source_canvas_id' IS NOT NULL
  """)

sources =
  Platform.Repo.query!("""
  SELECT metadata->>'source' AS source, count(*) AS total,
   count(*) FILTER (WHERE deleted_at IS NULL) AS not_deleted,
   count(*) FILTER (WHERE metadata->>'completed_via' = 'meeting_intent_ack') AS ack
  FROM tasks WHERE metadata->>'source' IN ('meetings.candidate','meetings.triage') GROUP BY 1 ORDER BY 1
  """)

survivors =
  Platform.Repo.query!("""
  SELECT count(*) FROM tasks t WHERE deleted_at IS NULL AND
   (metadata->>'source' = 'meetings.candidate' OR EXISTS
    (SELECT 1 FROM meeting_candidates c WHERE c.task_id = t.id))
  """)

IO.puts(
  "MEETING_CLEANUP_VERIFY " <>
    Jason.encode!(%{
      protected: %{columns: result.columns, rows: result.rows},
      sources: %{columns: sources.columns, rows: sources.rows},
      live_selector_survivors: hd(hd(survivors.rows))
    })
)

changed =
  Platform.Repo.query!("""
  WITH changed AS (
   SELECT DISTINCT jsonb_array_elements_text(metadata->'task_ids') AS id
   FROM audit_events WHERE event_type = 'meetings.live_tasks.junked'
   AND resource_id = '01a17f00-live-task-cleanup-20261028'
  )
  SELECT (SELECT coalesce(jsonb_agg(id ORDER BY id), '[]') FROM audit_events
   WHERE event_type = 'meetings.live_tasks.junked'
   AND resource_id = '01a17f00-live-task-cleanup-20261028') AS audit_ids,
   count(*) AS audited_tasks,
   count(*) FILTER (WHERE t.deleted_at IS NOT NULL) AS deleted_tasks,
   count(*) FILTER (WHERE t.metadata->>'source' = 'meetings.triage' OR t.metadata->>'source_canvas_id' IS NOT NULL) AS protected_tasks_in_audit,
   (SELECT count(*) FROM meeting_candidates c JOIN changed x ON c.task_id::text = x.id) AS retained_candidate_backlinks,
   (SELECT count(*) FROM meeting_briefings b, jsonb_each(b.items) e
    WHERE e.value->>'ref' IN (SELECT 'task:' || id FROM changed)) AS remaining_briefing_refs
  FROM changed x JOIN tasks t ON t.id::text = x.id
  """)

IO.puts(
  "MEETING_CLEANUP_AUDIT_VERIFY " <>
    Jason.encode!(%{columns: changed.columns, rows: changed.rows})
)

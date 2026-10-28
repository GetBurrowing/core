# Read-only bounded output: source counts and a digest of protected identities
# and deletion state. Compare protected_digest before/after the one-off.
result = Platform.Repo.query!("""
SELECT count(*) AS protected_count,
 md5(coalesce(string_agg(id::text || ':' || coalesce(deleted_at::text, 'null'), ',' ORDER BY id), '')) AS protected_digest
FROM tasks WHERE metadata->>'source' = 'meetings.triage' OR metadata->>'source_canvas_id' IS NOT NULL
""")
sources = Platform.Repo.query!("""
SELECT metadata->>'source' AS source, count(*) AS total,
 count(*) FILTER (WHERE deleted_at IS NULL) AS not_deleted,
 count(*) FILTER (WHERE metadata->>'completed_via' = 'meeting_intent_ack') AS ack
FROM tasks WHERE metadata->>'source' IN ('meetings.candidate','meetings.triage') GROUP BY 1 ORDER BY 1
""")
survivors = Platform.Repo.query!("""
SELECT count(*) FROM tasks t WHERE deleted_at IS NULL AND
 (metadata->>'source' = 'meetings.candidate' OR EXISTS
  (SELECT 1 FROM meeting_candidates c WHERE c.task_id = t.id))
""")
IO.puts("MEETING_CLEANUP_VERIFY " <> Jason.encode!(%{
  protected: %{columns: result.columns, rows: result.rows},
  sources: %{columns: sources.columns, rows: sources.rows},
  live_selector_survivors: hd(hd(survivors.rows))}))

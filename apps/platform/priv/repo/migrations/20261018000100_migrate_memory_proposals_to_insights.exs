defmodule Platform.Repo.Migrations.MigrateMemoryProposalsToInsights do
  use Ecto.Migration

  @moduledoc """
  Task `01a13867-3213-7001-a128-6b4c6b34283f` (Insights), stage 1: carry
  what is still worth keeping out of `memory_proposals` into the insight
  tables. REVERSIBLE, and `memory_proposals` itself is read only: it is not
  modified or dropped here (the drop is a deferred follow-up).

  ## What is copied

    * Every `rejected` proposal becomes a `memory_insight_verdicts` row
      (`kind` `rejected`, `origin` `legacy_proposal`), so past rejections
      keep calibrating the dreaming prompt and keep their blocks from
      re-ingesting. `reason` is the proposal's `feedback`, or
      `'legacy rejection; no reason recorded'` when it has none (a verdict
      always carries a reason).
    * Every `pending` proposal whose `expires_at` is still in the future
      becomes an open `memory_insights` row (`origin` `legacy_proposal`,
      `disseminable` false, `expires_at` preserved, no addressee).
      `unresolved-question` and `emerging-risk` become `question`; every
      other category becomes `briefing`. The old category is kept in
      `action["legacy_category"]`.

  ## What is not copied

  Pending proposals already past `expires_at` and approved proposals. They
  were never going to be acted on again, so they simply expire. (Measured
  read-only on two production installs 2026-10-17: 81 and 15 rows sat
  `pending` past `expires_at`, because `Proposals.expire_stale/0` never had
  a caller.)

  ## Idempotency

  Re-running `up/0` copies nothing twice: each insert skips a block whose
  `(workspace_id, block_hash)` already has a row, with
  `IS NOT DISTINCT FROM` so a NULL workspace matches too.

  ## down/0

  Deletes only `origin = 'legacy_proposal'` rows from both tables.

  `up/0` and `down/0` call `Ecto.Adapters.SQL.query!/3` directly, so tests
  can run them without a migration runner.
  """

  @verdicts_sql """
  INSERT INTO memory_insight_verdicts
    (id, block_hash, kind, reason, body, action_type, evidence, actor_id, workspace_id, origin, inserted_at)
  SELECT
    gen_random_uuid(),
    p.block_hash,
    'rejected',
    COALESCE(NULLIF(btrim(p.feedback), ''), 'legacy rejection; no reason recorded'),
    p.body,
    CASE WHEN p.category IN ('unresolved-question', 'emerging-risk') THEN 'question' ELSE 'briefing' END,
    p.evidence,
    NULL,
    p.workspace_id,
    'legacy_proposal',
    p.updated_at
  FROM memory_proposals p
  WHERE p.status = 'rejected'
    AND NOT EXISTS (
      SELECT 1 FROM memory_insight_verdicts v
      WHERE v.block_hash = p.block_hash
        AND v.workspace_id IS NOT DISTINCT FROM p.workspace_id
    )
  """

  @insights_sql """
  INSERT INTO memory_insights
    (id, workspace_id, journal_path, block_hash, run_id, action_type, confidence, evidence,
     body, action, state, disseminable, origin, expires_at, inserted_at, updated_at)
  SELECT
    gen_random_uuid(),
    p.workspace_id,
    p.journal_path,
    p.block_hash,
    md5('memory_insight_legacy:' || p.id::text)::uuid,
    CASE WHEN p.category IN ('unresolved-question', 'emerging-risk') THEN 'question' ELSE 'briefing' END,
    p.confidence,
    p.evidence,
    p.body,
    jsonb_build_object('legacy_category', p.category),
    'open',
    false,
    'legacy_proposal',
    p.expires_at,
    p.inserted_at,
    now()
  FROM memory_proposals p
  WHERE p.status = 'pending'
    AND p.expires_at > now()
    AND NOT EXISTS (
      SELECT 1 FROM memory_insights i
      WHERE i.block_hash = p.block_hash
        AND i.workspace_id IS NOT DISTINCT FROM p.workspace_id
    )
  """

  def up do
    %Postgrex.Result{num_rows: verdicts} =
      Ecto.Adapters.SQL.query!(Platform.Repo, @verdicts_sql, [])

    %Postgrex.Result{num_rows: insights} =
      Ecto.Adapters.SQL.query!(Platform.Repo, @insights_sql, [])

    %{verdicts: verdicts, insights: insights}
  end

  def down do
    %Postgrex.Result{num_rows: insights} =
      Ecto.Adapters.SQL.query!(
        Platform.Repo,
        "DELETE FROM memory_insights WHERE origin = 'legacy_proposal'",
        []
      )

    %Postgrex.Result{num_rows: verdicts} =
      Ecto.Adapters.SQL.query!(
        Platform.Repo,
        "DELETE FROM memory_insight_verdicts WHERE origin = 'legacy_proposal'",
        []
      )

    %{verdicts: verdicts, insights: insights}
  end
end

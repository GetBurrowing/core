defmodule Platform.Repo.Migrations.BackfillHistorianRoleAssignments do
  @moduledoc """
  One-shot data migration for task 019f2444 (Historian retirement, stage 1).

  Reads every `agents` row that carries `"historian"` in its
  `system_events` column and ensures a `role_assignments` row exists
  for `role_key = 'historian'` pointing at that agent — establishing
  the Roles-based source-of-truth ahead of the code cutover in later
  stages.

  ## Semantics (per the ticket)

    1. If NO `role_assignments` row exists for `role_key = 'historian'`,
       insert one for the legacy-flagged agent.
    2. If a row exists for the SAME agent_id, no-op (idempotent).
    3. If a row exists for a DIFFERENT agent_id, Roles wins — leave
       the existing assignment untouched and `Logger.warning/1` naming
       both slugs so an operator can reconcile out-of-band.

  ## Self-contained design

  Uses raw SQL via `Ecto.Adapters.SQL.query!/3`. Migrations should not
  depend on schema modules (they can drift after this migration lands
  and re-runs on a fresh DB should still work five years from now).
  The `20260624013500_seed_default_roles.exs` migration deliberately
  defers to `Platform.Roles.Seeds` — but that's ONE seed of static
  role rows, not per-row backfill logic. Here we prefer minimal
  moving parts.

  ## Idempotency

  Re-running `up/0` on a partially-backfilled DB must not error and
  must not insert duplicates. The `role_assignments.role_key` unique
  index (see `20260624012842_create_role_assignments_and_overrides.exs`)
  is the server-side guarantee. This migration uses
  `ON CONFLICT (role_key) DO NOTHING` on every insert; the
  disagreement branch (case 3 above) is discovered by inspecting the
  post-insert row.

  ## `down/0`

  Explicit no-op with an informational log. Reverting a Historian
  assignment programmatically could silently break the wiki write-gate
  in a way that's invisible to the operator running the rollback —
  much safer to require manual `Platform.Roles.unassign_role("historian")`
  if a revert is actually intended.
  """

  use Ecto.Migration
  require Logger

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    legacy_rows = fetch_legacy_historian_agents()

    Enum.each(legacy_rows, fn %{agent_id: agent_id, slug: legacy_slug} ->
      case fetch_existing_assignment() do
        nil ->
          insert_assignment!(agent_id, now)

        %{agent_id: same_agent_id} when same_agent_id == agent_id ->
          :ok

        %{agent_id: other_agent_id} ->
          other_slug = fetch_agent_slug(other_agent_id) || "<unknown>"

          Logger.warning(
            "[BackfillHistorianRoleAssignments] disagreement: legacy system_events " <>
              "flags agent slug=#{legacy_slug} as Historian but role_assignments " <>
              "already pins slug=#{other_slug}. Roles wins; operator to reconcile."
          )
      end
    end)
  end

  def down do
    # `Logger.warning/1` rather than `.info/1` so the message surfaces
    # under the default logger level (`:warning`) — a rollback that
    # silently drops guidance is worse than an ignorable warning.
    Logger.warning(
      "[BackfillHistorianRoleAssignments] down/0 is a deliberate no-op. " <>
        "Manually run `Platform.Roles.unassign_role(\"historian\")` if a revert " <>
        "of the Historian assignment is actually intended."
    )

    :ok
  end

  # ── Internal helpers ──────────────────────────────────────────────────

  # Returns %{agent_id: uuid_binary, slug: string} for every agent whose
  # system_events jsonb column contains "historian". Ordered by slug for
  # deterministic operator log output when multiple rows disagree.
  defp fetch_legacy_historian_agents do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Platform.Repo,
        """
        SELECT id, slug
        FROM agents
        WHERE system_events @> $1::jsonb
        ORDER BY slug ASC
        """,
        [["historian"]]
      )

    Enum.map(rows, fn [id, slug] -> %{agent_id: id, slug: slug} end)
  end

  # Returns %{agent_id: uuid_binary} for the current role_assignments row
  # pinned to role_key = 'historian', or nil if unassigned. Unique index
  # on role_key guarantees at most one row.
  defp fetch_existing_assignment do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Platform.Repo,
        "SELECT agent_id FROM role_assignments WHERE role_key = $1 LIMIT 1",
        ["historian"]
      )

    case rows do
      [] -> nil
      [[agent_id]] -> %{agent_id: agent_id}
    end
  end

  defp fetch_agent_slug(agent_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Platform.Repo,
        "SELECT slug FROM agents WHERE id = $1 LIMIT 1",
        [agent_id]
      )

    case rows do
      [] -> nil
      [[slug]] -> slug
    end
  end

  # Insert with ON CONFLICT DO NOTHING so a race against another writer
  # (or a re-run of this migration) resolves to a no-op rather than a
  # constraint violation.
  defp insert_assignment!(agent_id, now) do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      INSERT INTO role_assignments (id, role_key, agent_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, $3)
      ON CONFLICT (role_key) DO NOTHING
      """,
      ["historian", agent_id, now]
    )

    :ok
  end
end

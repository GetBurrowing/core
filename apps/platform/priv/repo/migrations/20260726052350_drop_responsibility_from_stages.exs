defmodule Platform.Repo.Migrations.DropResponsibilityFromStages do
  @moduledoc """
  Drops the `stages.responsibility` column (ADR-0046 member 9, task 019f9b29).

  Task 019f5d47 added this nullable column so a planner could tag one stage
  with a role key and have that single dispatch routed to the role owner's
  runtime. ADR-0046 replaces that mechanism: designer involvement now comes
  from the pre-plan design step (member 7), not from a planner-authored
  "Design direction (Saru)" stage. Member 9 removed the planning-template
  instruction that produced the value (stage 1), the resolution path that
  consumed it (stage 2), and the MCP plan surface that accepted it (stage 3).
  Nothing reads or writes the column at this point; this migration removes it.

  ## Census before drop

  `up/0` logs, at `:warning`, immediately before the `ALTER TABLE`:

    * three aggregates — the total number of rows with a non-NULL
      `responsibility`, the subset of those whose plan is non-terminal
      (`p.status NOT IN ('superseded','rejected')` — i.e. the in-flight plans
      whose dispatch behaviour actually changes), and the distinct values
      present;
    * the ROW IDENTITIES themselves — one `stage_id, plan_id, responsibility,
      plan_status` line per row, ordered by `stage_id`, capped at
      `@census_row_limit` with an "…and N more" tail so a pathological table
      cannot flood the deploy log.

  The aggregates alone would not survive the question actually asked during an
  incident, which is "which stage was it". Ids are cheap and the data is about
  to stop existing, so the log names the rows rather than counting them.

  This is deliberately a census inside the migration rather than a drain
  period or a one-off mix task:

    * A drain never terminates. The values live on in the stages of COMPLETED
      plans forever, so "wait until the column is empty" never becomes true.
    * A mix task is a permanent surface added to answer a temporary question.

  The migration runs exactly once per environment, at the exact moment the
  data stops existing, and its output lands in the release log where whoever
  reads the deploy output sees the real numbers.

  ## Why the values may be discarded

  The only consumer was dispatch routing, and its documented behaviour on an
  unresolvable value was already "fall back to the phase assignee, never
  block". Losing the value therefore degrades an in-flight design stage to
  exactly the fallback the mechanism already promised. The stage NAME
  ("Design direction (Saru)") preserves the human-readable intent, and the
  census log names the affected rows — `stage_id`, `plan_id`, the value and
  the plan status — up to `@census_row_limit` of them, so a reader can go back
  to a specific stage rather than only to a count.

  ## Reversibility

  `down/0` re-adds `responsibility` as a nullable `:text` column, so the
  migration is STRUCTURALLY reversible. **The data is NOT recoverable** — the
  column's contents are destroyed by `up/0` and `down/0` restores an empty
  column. The census log is the only surviving record of what was in it.

  ## Rollback procedure

  **`mix ecto.rollback` with no arguments does NOT reach this migration.**
  Rollback walks versions in DESCENDING order, and
  `20260726210000_force_update_architect_review_plan_citation_guidance.exs`
  sorts after `20260726052350`. One step therefore rolls back that prompt
  migration and leaves `stages.responsibility` dropped — the obvious recovery
  command silently does the wrong thing.

  To actually restore the column:

      mix ecto.rollback --to 20260726052350

  `--to` is inclusive, so that cycles BOTH `20260726210000` and this
  migration. Cycling the prompt migration is unavoidable and harmless: its
  `up/0` re-applies `default_content_for_slug/1` to the
  `architecture.review_plan.v1` row and its `down/0` is a no-op, so it
  round-trips without losing anything. Re-migrating afterwards restores it.

  Nothing later than `20260726210000` is cycled, and `20260726051455` (the
  other writer of that same prompt row) sorts BEFORE this migration, so it is
  untouched.

  Restoring the column does not restore its contents. The census log is the
  only source for that.

  ## Deploy window

  The container CMD is `/app/bin/platform eval 'Platform.Release.migrate()' &&
  /app/bin/platform start` (`apps/platform/Dockerfile:60`), so migrations run
  at new-container boot. If the outgoing container is still serving when the
  new one migrates, its `Stage` selects name a dropped column and error until
  cutover. That window is bounded (seconds), read-only, non-corrupting and
  self-healing.

  Rejected alternative — expand/contract across two releases (remove the
  schema field now, drop the column in a later release): that leaves a column
  named for one concept, holding another, with zero readers, for an
  indefinite period, since nothing schedules the contract half. That dead
  misleading column is precisely what ADR-0046 is retiring. The sub-minute
  read-only window is the cheaper cost.
  """

  use Ecto.Migration

  require Logger

  # Cap on identity lines in the census log. High enough that the realistic
  # population (a handful of in-flight design stages) is named in full, low
  # enough that a pathological table cannot bury the rest of the deploy log.
  @census_row_limit 50

  def up do
    census()

    alter table(:stages) do
      remove(:responsibility)
    end
  end

  def down do
    alter table(:stages) do
      add(:responsibility, :text)
    end
  end

  defp census do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        SELECT s.id, s.plan_id, s.responsibility, p.status
        FROM stages s
        JOIN plans p ON p.id = s.plan_id
        WHERE s.responsibility IS NOT NULL
        ORDER BY s.id
        """,
        []
      )

    terminal_statuses = ["superseded", "rejected"]

    non_terminal =
      Enum.count(rows, fn [_id, _plan_id, _responsibility, status] ->
        status not in terminal_statuses
      end)

    distinct =
      rows
      |> Enum.map(fn [_id, _plan_id, responsibility, _status] -> responsibility end)
      |> Enum.uniq()
      |> Enum.sort()

    Logger.warning("""
    [ADR-0046 member 9] Dropping stages.responsibility. Census before drop:
      rows with a non-NULL responsibility: #{length(rows)}
      of those, on a non-terminal plan:    #{non_terminal}
      distinct values:                     #{inspect(distinct)}
    Row identities (stage_id | plan_id | responsibility | plan_status):
    #{identity_lines(rows)}
    The data is not recoverable after this migration; down/0 restores the
    column but not its contents. `mix ecto.rollback` with no arguments does
    NOT reach this migration — see the moduledoc for the `--to` form.
    """)
  end

  defp identity_lines([]), do: "  (none)"

  defp identity_lines(rows) do
    listed =
      rows
      |> Enum.take(@census_row_limit)
      |> Enum.map_join("\n", fn [id, plan_id, responsibility, status] ->
        "  #{uuid(id)} | #{uuid(plan_id)} | #{inspect(responsibility)} | #{inspect(status)}"
      end)

    case length(rows) - @census_row_limit do
      more when more > 0 -> listed <> "\n  …and #{more} more"
      _all_listed -> listed
    end
  end

  # `Ecto.Adapters.SQL.query!/3` bypasses the schema layer, so a `:binary_id`
  # column arrives as the raw 16-byte value. Render it as the id a human can
  # paste into a query. The string clause is defensive only — an adapter that
  # already decoded should not turn the census into a crash inside a
  # destructive migration.
  defp uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp uuid(value) when is_binary(value), do: value
  defp uuid(value), do: inspect(value)
end

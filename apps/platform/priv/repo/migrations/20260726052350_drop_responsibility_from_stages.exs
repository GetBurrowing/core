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

  `up/0` logs, at `:warning`, three numbers taken immediately before the
  `ALTER TABLE`: the total number of rows with a non-NULL `responsibility`,
  the subset of those whose plan is non-terminal (`p.status NOT IN
  ('superseded','rejected')` — i.e. the in-flight plans whose dispatch
  behaviour actually changes), and the distinct values present. This is
  deliberately a census inside the migration rather than a drain period or a
  one-off mix task:

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
  census log preserves the row identities.

  ## Reversibility

  `down/0` re-adds `responsibility` as a nullable `:text` column, so the
  migration is STRUCTURALLY reversible. **The data is NOT recoverable** — the
  column's contents are destroyed by `up/0` and `down/0` restores an empty
  column. The census log is the only surviving record of what was in it.

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
    The data is not recoverable after this migration; down/0 restores the
    column but not its contents.
    """)
  end
end

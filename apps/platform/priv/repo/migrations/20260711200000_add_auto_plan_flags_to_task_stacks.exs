defmodule Platform.Repo.Migrations.AddAutoPlanFlagsToTaskStacks do
  use Ecto.Migration

  @moduledoc """
  Stack v2 stage 1 — add `auto_plan` and `auto_accept_plan` boolean
  columns to `task_stacks`.

  Both flags gate lifecycle branches in later stages of the Stack v2
  rollup:

    * `auto_plan` — when true, `Stacks.start_planning/1` dispatches
      every member to `planning` in a single concurrent pass rather
      than walking waves in dependency order.
    * `auto_accept_plan` — when true, each member's submitted plan
      auto-approves without human review (via `Tasks.maybe_auto_approve/1`
      resolving the flag through the member's stack).

  Both default to `false` — the safe manual-mode default — and are
  `null: false` so downstream reads never have to handle a nil case.
  Mirrors the top-level boolean pattern already in place for
  `tasks.auto_approve_plan` (see d0aaadf4).

  Admitted by task 019f487e stage 1, PR #531 — Stack v2 (ADR 0042)
  auto-plan cascade.
  """

  def change do
    alter table(:task_stacks) do
      add(:auto_plan, :boolean, default: false, null: false)
      add(:auto_accept_plan, :boolean, default: false, null: false)
    end
  end
end

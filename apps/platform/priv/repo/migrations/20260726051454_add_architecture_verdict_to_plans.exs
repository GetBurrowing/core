defmodule Platform.Repo.Migrations.AddArchitectureVerdictToPlans do
  use Ecto.Migration

  # ADR-0046 member 5 (task 019f9b28-ef50) stage 1 — the architecture
  # gate's state, recorded per PLAN VERSION.
  #
  # NULLABLE, NO DEFAULT — deliberately the opposite of member 4's
  # `tasks.planning_step_outcomes` (`default: %{}, null: false`), and
  # for the same underlying reason applied to a different shape.
  # `planning_step_outcomes` is a per-task accumulator whose empty state
  # is meaningful ("nothing has run yet", which is true of every task
  # that ever existed). `architecture_verdict` is a per-plan-version
  # record whose ABSENCE is meaningful ("the gate never opened for this
  # version"). A `%{}` default would make "never opened" and "opened and
  # empty" the same value — the conflation forbidden by
  # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`, in
  # miniature: a gate that never ran becomes indistinguishable from a gate
  # that ran and passed.
  #
  # NO INDEX — every read is by plan primary key or via
  # `Tasks.latest_plan/1`, which already orders by version and limits 1.
  # There is no "list all plans with an open gate" query; stage 5's
  # deadline sweep is timer-driven off the plan it opened, not a scan.
  #
  # ON `plans` AND NOT ON `tasks` — see the `Platform.Tasks.Plan`
  # moduledoc, which argues the choice at length so a reviewer can
  # reject the reasoning rather than the diff.
  def change do
    alter table(:plans) do
      add(:architecture_verdict, :map)
    end
  end
end

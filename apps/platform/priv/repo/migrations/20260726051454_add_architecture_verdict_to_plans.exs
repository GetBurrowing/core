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
  # SUPERSEDED 2026-07-28 (task 019fa605 stage 1, recorded here by stage 4).
  # The sentence above — "there is no 'list all plans with an open gate'
  # query" — IS NOW FALSE, and it was load-bearing for the no-index call, so
  # it is corrected in place rather than left for a reader to trip over.
  # `Platform.Orchestration.TaskRouterWatcher.sweep_expired_architecture_gates/0`
  # and its sibling `sweep_unsettled_auto_approvals/0` are exactly that scan.
  # They exist because a task whose PLANNING assignee is a USER never gets a
  # router (`TaskRouterWatcher.should_run?/1` requires `assignee_type ==
  # "agent"`), so nothing arms the deadline timer this comment assumed was
  # the only settler. Why that configuration is supported rather than
  # refused is recorded at
  # `0046-design-and-architecture-phases-in-planning.md § Addendum (2026-07-28, task 019fa605): a user planning assignee under auto-approval is supported`.
  #
  # THE NO-INDEX CALL STILL STANDS, on a narrower argument than the original.
  # Each sweep is `WHERE plans.status = 'pending_review' AND
  # architecture_verdict->>'state' ...` bounded by
  # `LIMIT @gate_expiry_sweep_cap` (25) at the 5-minute reconcile cadence —
  # a capped scan over a small hot partition, twelve times an hour, not a
  # per-request path.
  #
  # REVISIT WHEN, not "if it feels slow": if these two queries ever surface
  # in `pg_stat_statements` by total time, the one-line follow-up is a
  # partial index on `plans (status) WHERE architecture_verdict IS NOT NULL`.
  # DELIBERATELY NOT ADDED NOW — no measurement justifies it, and a migration
  # added on speculation pulls in stack timestamp reservation for nothing.
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

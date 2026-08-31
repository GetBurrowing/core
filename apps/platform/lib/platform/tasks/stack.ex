defmodule Platform.Tasks.Stack do
  @moduledoc """
  Schema for a task stack (ADR 0041).

  ## Stack-level agent assignment (`metadata["phase_assignees"]`)

  `metadata["phase_assignees"]` is the canonical stack-level default agent
  assignment. It is shaped identically to `tasks.phase_assignees`: a map
  keyed by phase (`"planning"` | `"execution"` | `"review"`), with values
  `%{"assignee_id" => uuid, "assignee_type" => "agent"}`.

  This default fans out to every member that is not individually
  overridden (a member is overridden when `task.metadata["assignee_override"]`
  is `true`). No schema field is needed — `metadata` is already a cast
  `:map` column. Read/normalize the stack-level map via
  `Platform.Tasks.Stacks.stack_phase_assignees/1`; write + percolate via
  `Platform.Tasks.Stacks.set_stack_phase_assignees/2`.
  """

  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  alias Platform.Tasks.Stacks.ShipState

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  # `blocked` is added per T5 stage 2 (rollup-merge conflict-halts-stack):
  # when a member branch fails to auto-merge into the stack rollup,
  # `Platform.Tasks.StackDeployer.merge_member_into_rollup/1` flips the
  # stack to `blocked` and records the conflict in `metadata.conflict`.
  # ADR 0041 §"Rollup-branch merge" mandates this halt; the enum was
  # widened here rather than in T1 because T1 had no producer for it.
  @statuses ~w(forming in_progress in_review deploying done abandoned blocked)

  schema "task_stacks" do
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:epic, Platform.Tasks.Epic)
    # Sponsor — human shepherd accountable for the stack landing (ADR 0042
    # Decision 8), distinct from any member's technical assignee. Nullable.
    # Cleared to NULL on user delete via the migration's :nilify_all FK so
    # a departing sponsor never orphans or hard-deletes a stack.
    belongs_to(:sponsor, Platform.Accounts.User,
      foreign_key: :sponsor_user_id,
      type: :binary_id
    )

    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "forming")
    field(:rollup_branch, :string)
    field(:base_branch, :string, default: "main")
    field(:metadata, :map, default: %{})
    # Stack v2 lifecycle flags (Stack v2 stage 1):
    #   * `auto_plan` — when true, `Stacks.start_planning/1` dispatches
    #     every member to `planning` in one pass (auto mode). Default
    #     false = manual mode: only the root wave dispatches; downstream
    #     waves advance as their upstream plans approve.
    #   * `auto_accept_plan` — when true, member plans auto-approve on
    #     submit without human review. Read at plan-submit time via
    #     `Tasks.maybe_auto_approve/1`, not propagated per-member.
    field(:auto_plan, :boolean, default: false)
    field(:auto_accept_plan, :boolean, default: false)

    # Per-stack migration-slot cursor. Holds the NEXT free
    # `mix ecto.gen.migration` timestamp for this stack's members; advanced
    # one second at a time by `Stacks.allocate_migration_slot/1` under a
    # per-stack advisory lock. `nil` = never allocated (lazy init to now).
    field(:next_migration_slot, :naive_datetime)

    has_many(:tasks, Platform.Tasks.Task, foreign_key: :stack_id)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  # Gap 3 no-regress guard (task 019f921d): once a stack has opened into an
  # execution phase, nothing may move it back to `forming` — that would
  # re-close `CommencementGate.open?/1` for every live member (the exact
  # deadlock that stranded the Inbox stack). A stray `recompute_stack_status`
  # over a transiently-empty member list, or an errant update, must not
  # regress the gate.
  @execution_phase_statuses ~w(in_progress in_review deploying done)

  def changeset(stack, attrs) do
    stack
    |> cast(attrs, [
      :project_id,
      :epic_id,
      :slug,
      :name,
      :description,
      :status,
      :rollup_branch,
      :base_branch,
      :sponsor_user_id,
      :metadata,
      :auto_plan,
      :auto_accept_plan,
      :next_migration_slot
    ])
    |> validate_required([:project_id, :slug, :name, :rollup_branch])
    |> validate_inclusion(:status, @statuses)
    |> guard_status_regression()
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> unique_constraint([:project_id, :slug], name: :task_stacks_slug_project_uniq)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:epic_id)
    |> foreign_key_constraint(:sponsor_user_id)
  end

  # Drop (skip) a `-> forming` status change when the persisted status is
  # already an execution phase, rather than erroring — a stray recompute is
  # a silent no-op, not a crash for its caller. Emits telemetry + a warning
  # so the anomaly is observable.
  #
  # Two further arms (task 01a05393, ADR 0045 decision 7) live in the same
  # guard because the changeset is the single funnel every stack writer
  # passes through (`update_stack/2`, `record_conflict/4`,
  # `complete_rollup_merge/2` and `recompute_stack_status/1` alike):
  #
  #   * A SHIPPED `done` stack is terminal: only `done` and `abandoned` are
  #     accepted. A `done` stack that never shipped (`ShipState.shipped?/1`
  #     false — the manual-ship lane) stays mutable.
  #   * A CONFLICT-HELD `blocked` stack is sticky: the status may move only
  #     when the same changeset also clears `metadata["conflict"]`. That
  #     one atomic write is the exit; without it a member event elsewhere
  #     would silently rewrite the conflicted stack to `in_review`.
  defp guard_status_regression(changeset) do
    current = changeset.data.status
    requested = get_change(changeset, :status)

    cond do
      requested == "forming" and current in @execution_phase_statuses ->
        :telemetry.execute(
          [:platform, :stacks, :status_regression_blocked],
          %{count: 1},
          %{stack_id: changeset.data.id, from: current, to: "forming"}
        )

        Logger.warning(
          "[Stack] blocked forming-regression for stack #{changeset.data.id} " <>
            "(current=#{current}); dropping status change"
        )

        delete_change(changeset, :status)

      current == "done" and is_binary(requested) and requested not in ~w(done abandoned) and
          ShipState.shipped?(changeset.data) ->
        drop_status_change(changeset, current, requested, :shipped)

      current == "blocked" and is_binary(requested) and requested != "blocked" and
        ShipState.conflict_held?(changeset.data) and
          not clearing_conflict?(changeset) ->
        drop_status_change(changeset, current, requested, :conflict_held)

      true ->
        changeset
    end
  end

  defp drop_status_change(changeset, from, to, reason) do
    :telemetry.execute(
      [:platform, :stacks, :status_regression_blocked],
      %{count: 1},
      %{stack_id: changeset.data.id, from: from, to: to, reason: reason}
    )

    Logger.warning(
      "[Stack] blocked status change #{from} -> #{to} for stack #{changeset.data.id} " <>
        "(reason=#{reason}); dropping status change"
    )

    delete_change(changeset, :status)
  end

  # The exit from a conflict-held `blocked`: the same changeset replaces
  # `metadata` with a map whose `"conflict"` key is absent or nil.
  defp clearing_conflict?(changeset) do
    case get_change(changeset, :metadata) do
      %{} = metadata -> is_nil(Map.get(metadata, "conflict"))
      _ -> false
    end
  end
end

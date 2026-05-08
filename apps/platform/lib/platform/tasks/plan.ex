defmodule Platform.Tasks.Plan do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft pending_review approved rejected superseded executing completed)

  schema "plans" do
    belongs_to(:task, Platform.Tasks.Task)
    field(:status, :string, default: "draft")
    field(:version, :integer)
    # Generic actor identifier: may be a user UUID or a system/runtime label.
    field(:approved_by, :string)
    field(:approved_at, :utc_datetime_usec)
    # Free-text reason captured when a plan is rejected. Reused by the
    # reopen-with-feedback flow (see task 019dfad1). Validation lives
    # in the UI/lifecycle layers, not here.
    field(:rejection_reason, :string)
    # Self-referential FK pointing to the plan that replaced this one.
    # Set by the auto-supersession lifecycle helper (stage 2 of task
    # 019dfd5a). Nullable: plans that were never superseded leave it nil.
    belongs_to(:superseded_by, Platform.Tasks.Plan, foreign_key: :superseded_by_plan_id)

    has_many(:stages, Platform.Tasks.Stage)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :task_id,
      :status,
      :version,
      :approved_by,
      :approved_at,
      :rejection_reason,
      :superseded_by_plan_id
    ])
    |> validate_required([:task_id, :version])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:task_id, :version])
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:superseded_by_plan_id)
  end
end

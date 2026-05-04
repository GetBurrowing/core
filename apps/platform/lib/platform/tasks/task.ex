defmodule Platform.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(backlog planning in_progress in_review deploying done blocked)
  @priorities ~w(low medium high critical)

  # Per-phase assignee keys. Order matches the natural lifecycle progression.
  @phases ~w(planning execution review)

  schema "tasks" do
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:epic, Platform.Tasks.Epic)
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "backlog")
    field(:priority, :string, default: "medium")
    # `assignee_type` / `assignee_id` are the *current-phase* assignee, derived
    # by `Platform.Tasks` whenever the phase changes. New assignments should be
    # written via `phase_assignees` so all phases get explicit values.
    field(:assignee_type, :string)
    field(:assignee_id, :binary_id)
    # Map keyed by phase ("planning" | "execution" | "review") with values
    # `%{"assignee_id" => uuid_string, "assignee_type" => "agent" | "user"}`.
    field(:phase_assignees, :map, default: %{})
    field(:deploy_target, :string)
    field(:deploy_strategy, :map)
    field(:dependencies, {:array, :map}, default: [])
    field(:metadata, :map, default: %{})
    field(:reported_by, :string)
    field(:deleted_at, :utc_datetime_usec)

    has_many(:plans, Platform.Tasks.Plan)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def phases, do: @phases

  @deletable_statuses ~w(backlog planning blocked done)
  def deletable_statuses, do: @deletable_statuses

  def deletable?(%__MODULE__{status: status}), do: status in @deletable_statuses

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :project_id,
      :epic_id,
      :title,
      :description,
      :status,
      :priority,
      :assignee_type,
      :assignee_id,
      :phase_assignees,
      :deploy_target,
      :deploy_strategy,
      :dependencies,
      :metadata,
      :reported_by,
      :deleted_at
    ])
    |> validate_required([:project_id, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_phase_assignees()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:epic_id)
  end

  # `phase_assignees` keys must be in `@phases`. Each value should be a map
  # with optional `"assignee_id"` (UUID string or nil) and `"assignee_type"`.
  # We don't strictly require both keys — a phase can be left unassigned.
  defp validate_phase_assignees(changeset) do
    case get_change(changeset, :phase_assignees) do
      nil ->
        changeset

      pa when is_map(pa) ->
        bad_keys = Map.keys(pa) -- @phases

        if bad_keys == [] do
          changeset
        else
          add_error(
            changeset,
            :phase_assignees,
            "contains invalid phase keys: #{inspect(bad_keys)} (allowed: #{inspect(@phases)})"
          )
        end

      _other ->
        add_error(changeset, :phase_assignees, "must be a map")
    end
  end
end

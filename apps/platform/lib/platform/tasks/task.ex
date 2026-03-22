defmodule Platform.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(backlog planning ready in_progress in_review done blocked)
  @priorities ~w(low medium high critical)
  @deploy_targets ~w(hive_production github_pr google_drive)

  schema "tasks" do
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:epic, Platform.Tasks.Epic)
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "backlog")
    field(:priority, :string, default: "medium")
    field(:assignee_type, :string)
    field(:assignee_id, :binary_id)
    field(:deploy_target, :string)
    field(:dependencies, {:array, :map}, default: [])
    field(:metadata, :map, default: %{})

    has_many(:plans, Platform.Tasks.Plan)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

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
      :deploy_target,
      :dependencies,
      :metadata
    ])
    |> validate_required([:project_id, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> then(fn cs ->
      if get_field(cs, :deploy_target),
        do: validate_inclusion(cs, :deploy_target, @deploy_targets),
        else: cs
    end)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:epic_id)
  end
end

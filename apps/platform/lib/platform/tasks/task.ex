defmodule Platform.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(backlog planning ready in_progress in_review done blocked)
  @priorities ~w(low medium high critical)

  schema "tasks" do
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:epic, Platform.Tasks.Epic)
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "backlog")
    field(:priority, :string, default: "medium")
    field(:assignee_type, :string)
    field(:assignee_id, :binary_id)
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
      :dependencies,
      :metadata
    ])
    |> validate_required([:project_id, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:epic_id)
  end
end

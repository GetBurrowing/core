defmodule Platform.Tasks.Stack do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(forming in_progress in_review deploying done abandoned)

  schema "task_stacks" do
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:epic, Platform.Tasks.Epic)
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "forming")
    field(:rollup_branch, :string)
    field(:base_branch, :string, default: "main")

    has_many(:tasks, Platform.Tasks.Task, foreign_key: :stack_id)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

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
      :base_branch
    ])
    |> validate_required([:project_id, :slug, :name, :rollup_branch])
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> unique_constraint([:project_id, :slug], name: :task_stacks_slug_project_uniq)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:epic_id)
  end
end

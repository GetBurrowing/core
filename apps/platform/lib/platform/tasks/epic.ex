defmodule Platform.Tasks.Epic do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open in_progress closed)

  schema "epics" do
    belongs_to(:project, Platform.Tasks.Project)
    field(:name, :string)
    field(:description, :string)
    field(:acceptance_criteria, :string)
    field(:status, :string, default: "open")
    field(:target_branch, :string)
    field(:deploy_target, :string)

    has_many(:tasks, Platform.Tasks.Task)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Build/validate an `Epic` changeset.

  ## Required fields
  - `:project_id` — every epic belongs to exactly one project. Foreign key
    enforced at the DB level (`on_delete: :delete_all`).
  - `:name` — human-readable label used in the kanban dropdown, breadcrumbs,
    and MCP tool output. Must be 1..120 chars after trimming. The DB column
    is `null: false` so `validate_required` is a redundant-but-friendly UI
    gate that turns a Postgres NOT NULL into an Ecto changeset error.

  ## Optional fields
  - `:description`, `:acceptance_criteria` — long-form body text. Both are
    nullable on purpose: epics are often created from a one-line title and
    fleshed out later in the planning conversation.
  - `:status` — defaults to `"open"`; constrained to `@statuses` via
    `validate_inclusion`.
  - `:target_branch`, `:deploy_target` — deploy-strategy hints inherited by
    member tasks. Optional so non-deploy epics (research, design) work too.
  """
  def changeset(epic, attrs) do
    epic
    |> cast(attrs, [
      :project_id,
      :name,
      :description,
      :acceptance_criteria,
      :status,
      :target_branch,
      :deploy_target
    ])
    |> validate_required([:project_id, :name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:project_id)
  end
end

defmodule Platform.Tasks.Epic do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open in_progress closed)

  schema "epics" do
    belongs_to(:project, Platform.Tasks.Project)
    field(:name, :string)
    field(:description, :string)
    field(:acceptance_criteria, :string)
    field(:status, :string, default: "open")

    has_many(:tasks, Platform.Tasks.Task)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(epic, attrs) do
    epic
    |> cast(attrs, [:project_id, :name, :description, :acceptance_criteria, :status])
    |> validate_required([:project_id, :name])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:project_id)
  end
end

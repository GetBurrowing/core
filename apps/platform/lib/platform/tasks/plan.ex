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
    field(:approved_by, :binary_id)
    field(:approved_at, :utc_datetime_usec)

    has_many(:stages, Platform.Tasks.Stage)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:task_id, :status, :version, :approved_by, :approved_at])
    |> validate_required([:task_id, :version])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:task_id, :version])
    |> foreign_key_constraint(:task_id)
  end
end

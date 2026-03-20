defmodule Platform.Tasks.Stage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running passed failed skipped)

  schema "stages" do
    belongs_to(:plan, Platform.Tasks.Plan)
    field(:position, :integer)
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "pending")
    field(:expected_artifacts, {:array, :map}, default: [])
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    has_many(:validations, Platform.Tasks.Validation)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [
      :plan_id,
      :position,
      :name,
      :description,
      :status,
      :expected_artifacts,
      :started_at,
      :completed_at
    ])
    |> validate_required([:plan_id, :position, :name])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:plan_id)
  end
end

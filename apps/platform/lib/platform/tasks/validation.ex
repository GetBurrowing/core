defmodule Platform.Tasks.Validation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(ci_check lint_pass type_check test_pass code_review manual_approval)
  @statuses ~w(pending running passed failed)

  schema "validations" do
    belongs_to(:stage, Platform.Tasks.Stage)
    field(:kind, :string)
    field(:status, :string, default: "pending")
    field(:evidence, :map, default: %{})
    field(:evaluated_by, :string)
    field(:evaluated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(validation, attrs) do
    validation
    |> cast(attrs, [:stage_id, :kind, :status, :evidence, :evaluated_by, :evaluated_at])
    |> validate_required([:stage_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:stage_id)
  end
end

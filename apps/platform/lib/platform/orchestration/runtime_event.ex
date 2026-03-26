defmodule Platform.Orchestration.RuntimeEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @phases ~w(planning execution review)

  schema "runtime_events" do
    belongs_to(:task, Platform.Tasks.Task)
    belongs_to(:lease, Platform.Orchestration.ExecutionLease)
    field(:phase, :string)
    field(:runtime_id, :string)
    field(:event_type, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:idempotency_key, :string)
    field(:payload, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def phases, do: @phases

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :task_id,
      :lease_id,
      :phase,
      :runtime_id,
      :event_type,
      :occurred_at,
      :idempotency_key,
      :payload
    ])
    |> validate_required([
      :task_id,
      :phase,
      :runtime_id,
      :event_type,
      :occurred_at,
      :idempotency_key
    ])
    |> validate_inclusion(:phase, @phases)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:lease_id)
    |> unique_constraint(:idempotency_key)
  end
end

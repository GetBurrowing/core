defmodule Platform.Orchestration.RuntimeEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @phases ~w(planning execution review)

  # ADR 0040 §D3: enum values for owner_attribution_status. Application-side enum
  # (no DB enum); changesets validate inclusion. SQL-level documentation lives
  # in the migration's `COMMENT ON COLUMN` statement.
  @attribution_statuses ~w(legacy_pre_migration attributed attribution_failed pseudonymous)

  schema "runtime_events" do
    belongs_to(:task, Platform.Tasks.Task)
    belongs_to(:lease, Platform.Orchestration.ExecutionLease)
    field(:phase, :string)
    field(:runtime_id, :string)
    field(:event_type, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:idempotency_key, :string)
    field(:payload, :map, default: %{})

    # ADR 0040 — owner identity (Stage 1: NULL-permissive, Stage 2: enforced).
    field(:invoked_by_user_id, Ecto.UUID)
    field(:owner_org_id, Ecto.UUID)
    field(:owner_attribution_status, :string, default: "legacy_pre_migration")

    timestamps(type: :utc_datetime_usec)
  end

  def phases, do: @phases
  def attribution_statuses, do: @attribution_statuses

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
      :payload,
      :invoked_by_user_id,
      :owner_org_id,
      :owner_attribution_status
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
    |> validate_inclusion(:owner_attribution_status, @attribution_statuses)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:lease_id)
    |> unique_constraint(:idempotency_key)
  end
end

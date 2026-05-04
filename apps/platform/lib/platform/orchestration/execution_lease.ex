defmodule Platform.Orchestration.ExecutionLease do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active blocked finished failed expired abandoned)
  @phases ~w(planning execution review)

  # ADR 0040 §D3: see RuntimeEvent.attribution_statuses for canonical list.
  @attribution_statuses ~w(legacy_pre_migration attributed attribution_failed pseudonymous)

  schema "execution_leases" do
    belongs_to(:task, Platform.Tasks.Task)
    field(:phase, :string)
    field(:runtime_id, :string)
    field(:runtime_worker_ref, :string)
    field(:status, :string, default: "active")
    field(:started_at, :utc_datetime_usec)
    field(:last_heartbeat_at, :utc_datetime_usec)
    field(:last_progress_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:block_reason, :string)
    field(:metadata, :map, default: %{})

    # ADR 0040 — owner identity (Stage 1: NULL-permissive, Stage 2: enforced).
    field(:invoked_by_user_id, Ecto.UUID)
    field(:owner_org_id, Ecto.UUID)
    field(:owner_attribution_status, :string, default: "legacy_pre_migration")

    timestamps(type: :utc_datetime_usec)
  end

  def phases, do: @phases
  def statuses, do: @statuses
  def attribution_statuses, do: @attribution_statuses

  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :task_id,
      :phase,
      :runtime_id,
      :runtime_worker_ref,
      :status,
      :started_at,
      :last_heartbeat_at,
      :last_progress_at,
      :expires_at,
      :block_reason,
      :metadata,
      :invoked_by_user_id,
      :owner_org_id,
      :owner_attribution_status
    ])
    |> validate_required([:task_id, :phase, :runtime_id, :status, :started_at, :expires_at])
    |> validate_inclusion(:phase, @phases)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:owner_attribution_status, @attribution_statuses)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint(:task_id,
      name: :execution_leases_active_unique_idx,
      message: "active lease already exists for task/runtime/phase"
    )
  end
end

defmodule Platform.Orchestration.ExecutionLease do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active blocked finished failed expired abandoned)
  @phases ~w(planning execution review)

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

    timestamps(type: :utc_datetime_usec)
  end

  def phases, do: @phases
  def statuses, do: @statuses

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
      :metadata
    ])
    |> validate_required([:task_id, :phase, :runtime_id, :status, :started_at, :expires_at])
    |> validate_inclusion(:phase, @phases)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint(:task_id,
      name: :execution_leases_active_unique_idx,
      message: "active lease already exists for task/runtime/phase"
    )
  end
end

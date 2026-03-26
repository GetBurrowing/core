defmodule Platform.Repo.Migrations.CreateExecutionLeasesAndRuntimeEvents do
  use Ecto.Migration

  def change do
    create table(:execution_leases, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :task_id,
        references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:phase, :string, null: false)
      add(:runtime_id, :string, null: false)
      add(:runtime_worker_ref, :string)
      add(:status, :string, null: false, default: "active")
      add(:started_at, :utc_datetime_usec, null: false)
      add(:last_heartbeat_at, :utc_datetime_usec)
      add(:last_progress_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:block_reason, :text)
      add(:metadata, :map, default: %{}, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:execution_leases, [:task_id]))
    create(index(:execution_leases, [:runtime_id]))
    create(index(:execution_leases, [:status]))
    create(index(:execution_leases, [:expires_at]))

    create(
      unique_index(:execution_leases, [:task_id, :phase, :runtime_id],
        where: "status in ('active', 'blocked')",
        name: :execution_leases_active_unique_idx
      )
    )

    create table(:runtime_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :task_id,
        references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :lease_id,
        references(:execution_leases, type: :binary_id, on_delete: :nilify_all)
      )

      add(:phase, :string, null: false)
      add(:runtime_id, :string, null: false)
      add(:event_type, :string, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:idempotency_key, :string, null: false)
      add(:payload, :map, default: %{}, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:runtime_events, [:task_id]))
    create(index(:runtime_events, [:runtime_id]))
    create(index(:runtime_events, [:event_type]))
    create(index(:runtime_events, [:occurred_at]))
    create(unique_index(:runtime_events, [:idempotency_key]))
  end
end

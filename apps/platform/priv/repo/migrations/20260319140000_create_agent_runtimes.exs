defmodule Platform.Repo.Migrations.CreateAgentRuntimes do
  use Ecto.Migration

  def change do
    create table(:agent_runtimes, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:runtime_id, :string, null: false)

      add(:owner_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:display_name, :string)
      add(:transport, :string, null: false, default: "websocket")
      add(:status, :string, null: false, default: "pending")
      add(:trust_level, :string, null: false, default: "participant")
      add(:capabilities, :map, default: "[]")
      add(:auth_token_hash, :string)
      add(:last_connected_at, :utc_datetime_usec)
      add(:metadata, :map, default: "{}")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:agent_runtimes, [:runtime_id]))
    create(index(:agent_runtimes, [:owner_user_id]))
    create(index(:agent_runtimes, [:agent_id]))

    alter table(:agents) do
      add(:runtime_type, :string, default: "built_in")
      add(:runtime_id, references(:agent_runtimes, type: :binary_id, on_delete: :nilify_all))
    end
  end
end

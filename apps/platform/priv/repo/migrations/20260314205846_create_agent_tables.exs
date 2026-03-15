defmodule Platform.Repo.Migrations.CreateAgentTables do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :workspace_id, :binary_id
      add :slug, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :model_config, :map, null: false, default: %{}
      add :tools_config, :map, null: false, default: %{}
      add :thinking_default, :string
      add :heartbeat_config, :map, default: %{}
      add :max_concurrent, :integer, default: 1
      add :sandbox_mode, :string, default: "off"
      add :parent_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:workspace_id, :slug], name: :agents_unique_slug)
    create index(:agents, [:status])
    create index(:agents, [:parent_agent_id])

    create table(:agent_workspace_files, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :file_key, :string, null: false
      add :content, :text, null: false, default: ""
      add :version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_workspace_files, [:agent_id, :file_key],
             name: :agent_workspace_files_unique_key
           )

    create table(:agent_memories, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :memory_type, :string, null: false
      add :date, :date
      add :content, :text, null: false
      add :metadata, :map, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:agent_memories, ["agent_id ASC", "date DESC"],
             name: :agent_memories_agent_date
           )

    create index(:agent_memories, [:agent_id, :memory_type])

    create table(:agent_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :restrict), null: false

      add :parent_session_id,
          references(:agent_sessions, type: :binary_id, on_delete: :nilify_all)

      add :status, :string, null: false, default: "running"
      add :context_snapshot, :map
      add :model_used, :string
      add :token_usage, :map, default: %{}
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
    end

    create index(:agent_sessions, [:agent_id])
    create index(:agent_sessions, [:parent_session_id])
    create index(:agent_sessions, [:status])

    create table(:agent_context_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :from_session_id,
          references(:agent_sessions, type: :binary_id, on_delete: :restrict),
          null: false

      add :to_session_id,
          references(:agent_sessions, type: :binary_id, on_delete: :restrict),
          null: false

      add :scope, :string, null: false
      add :scope_filter, :map
      add :delta, :map
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:agent_context_shares, [:from_session_id])
    create index(:agent_context_shares, [:to_session_id])
  end
end

defmodule Platform.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :event_type, :string, null: false
      add :actor_id, :binary_id
      add :actor_type, :string, null: false, default: "system"
      add :resource_type, :string
      add :resource_id, :string
      add :action, :string, null: false
      add :metadata, :map, default: %{}
      add :session_id, :string
      add :ip_address, :string
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:audit_events, [:actor_id, :inserted_at])
    create index(:audit_events, [:resource_type, :resource_id, :inserted_at])
    create index(:audit_events, [:event_type, :inserted_at])
    create index(:audit_events, [:session_id], where: "session_id IS NOT NULL")
  end
end

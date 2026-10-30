defmodule Platform.Repo.Migrations.CalendarAgentConsent do
  @moduledoc "Task 01a16991-b7ae-7000-923f-54cd0b8cd7f7: revocable agent grants and Inbox consent."
  use Ecto.Migration

  def change do
    alter table(:calendar_events) do
      add(:tentative, :boolean, null: false, default: false)
    end

    create table(:calendar_agent_grants, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:agent_id, references(:agents, type: :uuid, on_delete: :delete_all), null: false)

      for field <- [:read, :read_private, :create, :move, :preapprove] do
        add(field, :boolean, null: false, default: false)
      end

      add(:revoked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_agent_grants, [:owner_id, :agent_id]))

    create table(:calendar_consents, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:agent_id, references(:agents, type: :uuid, on_delete: :delete_all), null: false)
      add(:grant_id, references(:calendar_agent_grants, type: :uuid), null: false)
      add(:briefing_id, references(:memory_briefings, type: :uuid), null: false)
      add(:event_id, references(:calendar_events, type: :uuid))
      add(:hold_id, references(:calendar_events, type: :uuid), null: false)
      add(:request_key, :string, null: false)
      add(:operation, :string, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:prior, :map, null: false, default: %{})
      add(:target_sequence, :integer)
      add(:committed_sequence, :integer)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_consents, [:owner_id, :agent_id, :request_key]))
    create(index(:calendar_consents, [:grant_id, :state]))
  end
end

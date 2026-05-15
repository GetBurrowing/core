defmodule Platform.Repo.Migrations.CreateMeetings do
  use Ecto.Migration

  @moduledoc """
  Adds the durable `meetings` entity (ADR 0042 data-layer foundation).

  Distinct from the existing `meeting_rooms` table: `meeting_rooms` tracks
  ephemeral LiveKit call state keyed 1:1 to a chat space, whereas `meetings`
  is the project-scoped meeting record with a slug, host, status lifecycle,
  and an embedded chat space (the future intent panel).
  """

  def change do
    create table(:meetings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :project_id,
        references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :host_participant_id,
        references(:chat_participants, type: :binary_id, on_delete: :nilify_all)
      )

      add(
        :chat_space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:slug, :string, null: false)
      add(:name, :string, null: false)
      add(:status, :string, null: false, default: "scheduled")
      add(:livekit_room_name, :string, null: false)
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    # slug is unique per project, not globally
    create(unique_index(:meetings, [:project_id, :slug]))
    create(unique_index(:meetings, [:livekit_room_name]))
    create(index(:meetings, [:project_id, :status]))
    create(index(:meetings, [:chat_space_id]))
    create(index(:meetings, [:host_participant_id]))
  end
end

defmodule Platform.Repo.Migrations.CreateMeetingsTables do
  use Ecto.Migration

  def change do
    # ── meeting_rooms ──────────────────────────────────────────────────────
    create table(:meeting_rooms, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:livekit_room_name, :string, null: false)
      add(:status, :string, null: false, default: "idle")
      add(:config, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:meeting_rooms, [:space_id]))
    create(unique_index(:meeting_rooms, [:livekit_room_name]))
    create(index(:meeting_rooms, [:status]))

    # ── meeting_participants ───────────────────────────────────────────────
    create table(:meeting_participants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :room_id,
        references(:meeting_rooms, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:display_name, :string, null: false)
      add(:joined_at, :utc_datetime_usec, null: false)
      add(:left_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})
    end

    create(index(:meeting_participants, [:room_id]))
    create(index(:meeting_participants, [:user_id]))
    create(index(:meeting_participants, [:agent_id]))

    # ── meeting_recordings ─────────────────────────────────────────────────
    create table(:meeting_recordings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :room_id,
        references(:meeting_rooms, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:egress_id, :string)
      add(:status, :string, null: false, default: "recording")
      add(:duration_seconds, :integer)
      add(:file_url, :string)
      add(:file_size_bytes, :bigint)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:meeting_recordings, [:room_id]))
    create(index(:meeting_recordings, [:space_id]))
    create(index(:meeting_recordings, [:status]))
  end
end

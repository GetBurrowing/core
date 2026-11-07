defmodule Platform.Repo.Migrations.CreateNativePlaySessions do
  @moduledoc """
  Task 01a1b287: persists native Play channel bindings, immutable build
  manifests, session lifecycle and hashed one-use reservations so host/core
  restarts cannot duplicate a channel session or replay a player's admission.
  """
  use Ecto.Migration

  def change do
    create table(:game_channel_bindings, primary_key: false) do
      add(:id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false)
      add(:repo_url, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create table(:native_game_builds, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false)
      add(:manifest, :map, null: false)
      add(:published_at, :utc_datetime_usec, null: false)
    end

    create(index(:native_game_builds, [:project_id, :published_at]))

    create table(:native_play_sessions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:channel_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all), null: false)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false)
      add(:build_id, references(:native_game_builds, type: :string), null: false)
      add(:immutable_build, :map, null: false)
      add(:protocol_version, :integer, null: false)
      add(:server_image, :text, null: false)
      add(:host_runtime_id, :string, null: false)
      add(:host_handle, :string)
      add(:host_credential_hash, :string)
      add(:generation, :integer, null: false, default: 1)
      add(:state, :string, null: false, default: "starting")
      add(:endpoint, :string)
      add(:reason, :string)
      add(:capacity, :integer, null: false)
      add(:heartbeat_at, :utc_datetime_usec)
      add(:idle_since, :utc_datetime_usec)
      add(:idle_timeout_s, :integer, null: false, default: 600)
      add(:experiment_id, :binary_id)
      add(:variant_slug, :string)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      add(:duration_s, :integer, default: 0, null: false)
      add(:idle_seconds, :integer, default: 0, null: false)
      add(:player_seconds, :integer, default: 0, null: false)
      add(:reconnect_attempts, :integer, default: 0, null: false)
      add(:connect_count, :integer, default: 0, null: false)
      add(:reconnect_count, :integer, default: 0, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:native_play_sessions, [:channel_id],
        name: :native_one_active_channel,
        where: "state IN ('starting', 'running', 'stopping')"
      )
    )

    create(
      constraint(:native_play_sessions, :native_session_state,
        check: "state IN ('starting','running','stopping','ended','failed')"
      )
    )

    create(
      constraint(:native_play_sessions, :native_session_limits,
        check: "capacity BETWEEN 1 AND 8 AND idle_timeout_s IN (300,600,900) AND generation > 0"
      )
    )

    create table(:native_join_tokens, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :session_id,
        references(:native_play_sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:channel_id, :binary_id, null: false)
      add(:build_id, :string, null: false)
      add(:generation, :integer, null: false)
      add(:digest, :string, null: false)
      add(:slot, :integer, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:connected, :boolean, default: false, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:native_join_tokens, [:digest]))
    create(index(:native_join_tokens, [:session_id, :expires_at]))
  end
end

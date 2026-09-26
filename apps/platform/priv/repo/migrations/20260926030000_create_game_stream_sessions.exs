defmodule Platform.Repo.Migrations.CreateGameStreamSessions do
  @moduledoc """
  One row per ENDED play session (task 01a0db5f-4f1a-7001-87a3-e777ad1cab82
  stage 2, playable review builds).

  Live session state is ephemeral — a `Platform.GameStream.Session`
  GenServer, carried on PubSub — so nothing is written while a session runs.
  The row is written once, when the session ends or fails, from the last
  stats the viewer's browser reported. It is what the
  `game_stream_input_to_photon` experiment metric reads (the `cycle_time`
  pattern: a domain table the metric computes over, not a second exposure
  store), so `experiment_id` / `variant_slug` record which arm of
  `game_stream.encoder_preset` the session ran and `encoder` records the
  exact payload it ran with.

  `id` IS the session id the protocol carried, so a host log line and this
  row name the same thing. `connection_path` is CHECK-constrained to
  `lan | turn`, and is null when no viewer ever reported stats. Additive
  only: one new table, no change to an existing one.
  """

  use Ecto.Migration

  def change do
    create table(:game_stream_sessions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false)
      add(:review_sha, :string, null: false)
      add(:branch, :string, null: false)
      add(:host_runtime_id, :string, null: false)
      add(:started_by_kind, :string)
      add(:started_by_id, :uuid)

      add(:experiment_id, references(:experiments, type: :binary_id, on_delete: :nilify_all))

      add(:variant_slug, :string)
      add(:encoder, :map, null: false, default: %{})
      add(:connection_path, :string)
      add(:rtt_p50_ms, :float)
      add(:rtt_p95_ms, :float)
      add(:fps_avg, :float)
      add(:ended_state, :string, null: false)
      add(:ended_reason, :string)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:game_stream_sessions, [:task_id]))
    create(index(:game_stream_sessions, [:experiment_id, :variant_slug]))

    create(
      constraint(:game_stream_sessions, :game_stream_sessions_connection_path_check,
        check: "connection_path IS NULL OR connection_path IN ('lan', 'turn')"
      )
    )

    create(
      constraint(:game_stream_sessions, :game_stream_sessions_ended_state_check,
        check: "ended_state IN ('ended', 'failed')"
      )
    )
  end
end

defmodule Platform.GameStream.SessionRecord do
  @moduledoc """
  The `game_stream_sessions` row: one per ENDED play session (task 01a0db5f
  stage 2). Written once, at the end, by `Platform.GameStream.Session`; read
  by `Platform.Experiments.Metrics.GameStreamInputToPhoton`.

  `id` is the session id the protocol carried. See the migration's moduledoc
  for why nothing is written while a session is live.

  ## Several players (task 01a0dbd6 stage 2)

  `slot_stats` holds each player slot's last reported figures (string slot
  keys, "0" is P1). The v1 columns `rtt_p50_ms`, `rtt_p95_ms`, `fps_avg` and
  `connection_path` are the WORST slot's (highest `rtt_p95_ms`; see
  `Platform.GameStream.Session.summarize_stats/1`). For a one-player row the
  worst slot IS the only slot, so those columns read exactly as they did in
  v1 and every existing reader, the input-to-photon metric included, is
  unchanged for it. `peak_players` and `peak_spectators` are the session's
  maxima. `roster_experiment_id` / `roster_variant_slug` record the
  `game_stream.roster` arm, as `experiment_id` / `variant_slug` record the
  encoder's.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @connection_paths ~w(lan turn)
  @ended_states ~w(ended failed)

  schema "game_stream_sessions" do
    field(:task_id, :binary_id)
    field(:review_sha, :string)
    field(:branch, :string)
    field(:host_runtime_id, :string)
    field(:started_by_kind, :string)
    field(:started_by_id, :binary_id)
    field(:experiment_id, :binary_id)
    field(:variant_slug, :string)
    field(:encoder, :map, default: %{})
    field(:connection_path, :string)
    field(:rtt_p50_ms, :float)
    field(:rtt_p95_ms, :float)
    field(:fps_avg, :float)
    field(:slot_stats, :map, default: %{})
    field(:peak_players, :integer, default: 0)
    field(:peak_spectators, :integer, default: 0)
    field(:roster_experiment_id, :binary_id)
    field(:roster_variant_slug, :string)
    field(:ended_state, :string)
    field(:ended_reason, :string)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(id task_id review_sha branch host_runtime_id ended_state started_at ended_at)a
  @optional ~w(started_by_kind started_by_id experiment_id variant_slug encoder connection_path
               rtt_p50_ms rtt_p95_ms fps_avg ended_reason slot_stats peak_players
               peak_spectators roster_experiment_id roster_variant_slug)a

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:connection_path, @connection_paths)
    |> validate_inclusion(:ended_state, @ended_states)
    |> validate_number(:peak_players, greater_than_or_equal_to: 0)
    |> validate_number(:peak_spectators, greater_than_or_equal_to: 0)
    |> check_constraint(:connection_path, name: :game_stream_sessions_connection_path_check)
    |> check_constraint(:ended_state, name: :game_stream_sessions_ended_state_check)
    |> foreign_key_constraint(:task_id)
  end
end

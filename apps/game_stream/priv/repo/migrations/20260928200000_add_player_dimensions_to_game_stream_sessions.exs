defmodule Platform.Repo.Migrations.AddPlayerDimensionsToGameStreamSessions do
  @moduledoc """
  Task 01a0dbd6-76bb-7001-a322-08a81e3d7927 stage 2 (multiplayer
  game_stream): a play session now has N peers and up to `max_players`
  player slots, so its one ended row records the multiplayer dimensions.

    * `peak_players` / `peak_spectators` — the most occupied player slots,
      and the most peers without a slot, at any moment of the session.
    * `slot_stats` — a map of slot (string key, "0" is P1) to that slot's
      last reported `rtt_p50_ms`, `rtt_p95_ms`, `fps_avg` and
      `connection_path`.
    * `roster_experiment_id` / `roster_variant_slug` — which arm of the
      `game_stream.roster` surface the session ran, next to the existing
      encoder pair, so a roster experiment's metric can find its sessions.

  The existing `rtt_p50_ms`, `rtt_p95_ms`, `fps_avg` and `connection_path`
  columns keep their meaning for a one-player row and become the WORST
  slot's figures otherwise (see `Platform.GameStream.SessionRecord`).
  Additive only: new nullable or defaulted columns, no rewrite of old rows.
  """

  use Ecto.Migration

  def change do
    alter table(:game_stream_sessions) do
      add(:peak_players, :integer, null: false, default: 0)
      add(:peak_spectators, :integer, null: false, default: 0)
      add(:slot_stats, :map, null: false, default: %{})

      add(
        :roster_experiment_id,
        references(:experiments, type: :binary_id, on_delete: :nilify_all)
      )

      add(:roster_variant_slug, :string)
    end

    create(index(:game_stream_sessions, [:roster_experiment_id, :roster_variant_slug]))
  end
end

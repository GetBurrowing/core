defmodule Platform.Repo.Migrations.AddPlayerDimensionsToGameStreamSessionsTest do
  @moduledoc """
  `20260928200000_add_player_dimensions_to_game_stream_sessions` (task
  01a0dbd6 stage 2) against the migrated test database.

  The columns are read from `information_schema`, not from the Ecto schema,
  so a schema field with no column behind it fails here. A row written the
  way a v1 writer wrote it (none of the new keys) must land with the
  defaults, which is what "additive" promises every existing reader.
  """

  use Platform.DataCase, async: true

  alias Platform.GameStream.SessionRecord
  alias Platform.Repo
  alias Platform.Tasks

  @migration "priv/repo/migrations/20260928200000_add_player_dimensions_to_game_stream_sessions.exs"

  defp columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name, data_type, is_nullable, column_default
        FROM information_schema.columns
       WHERE table_name = 'game_stream_sessions'
      """)

    Map.new(rows, fn [name, type, nullable, default] -> {name, {type, nullable, default}} end)
  end

  test "adds the five columns with the documented types and defaults" do
    cols = columns()

    assert {"integer", "NO", "0"} = cols["peak_players"]
    assert {"integer", "NO", "0"} = cols["peak_spectators"]
    assert {"jsonb", "NO", default} = cols["slot_stats"]
    assert default =~ "'{}'"
    assert {"uuid", "YES", nil} = cols["roster_experiment_id"]
    assert {"character varying", "YES", nil} = cols["roster_variant_slug"]

    # The v1 columns are untouched.
    for col <- ~w(rtt_p50_ms rtt_p95_ms fps_avg connection_path experiment_id variant_slug) do
      assert Map.has_key?(cols, col), "#{col} is gone"
    end
  end

  test "a row written without the new keys (a v1 writer) gets the defaults" do
    {:ok, project} = Tasks.create_project(%{name: "GS migration #{System.unique_integer()}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "GS"})
    now = DateTime.utc_now()
    id = Ecto.UUID.generate()

    {1, _} =
      Repo.insert_all("game_stream_sessions", [
        %{
          id: Ecto.UUID.dump!(id),
          task_id: Ecto.UUID.dump!(task.id),
          review_sha: String.duplicate("a", 40),
          branch: "task/" <> task.id,
          host_runtime_id: "play-host-wave",
          encoder: %{},
          ended_state: "ended",
          started_at: now,
          ended_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

    row = Repo.get!(SessionRecord, id)
    assert {row.peak_players, row.peak_spectators, row.slot_stats} == {0, 0, %{}}
    assert row.roster_experiment_id == nil
  end

  test "the migration cites its task in its moduledoc" do
    source = File.read!(Path.join(File.cwd!(), @migration))
    assert source =~ ~r/@moduledoc """\n\s+Task 01a0dbd6/
  end
end

defmodule Platform.Repo.Migrations.AddBuildMsToGameStreamSessionsTest do
  @moduledoc """
  `20261027040000_add_build_ms_to_game_stream_sessions` (task 01a17b51 stage
  3) against the migrated test database: one nullable integer, no default, so
  every row written before it reads NULL, and a down/0 that removes it.
  """

  use Platform.DataCase, async: true

  alias Platform.GameStream.SessionRecord
  alias Platform.Repo
  alias Platform.Tasks

  @migration "priv/repo/migrations/20261027040000_add_build_ms_to_game_stream_sessions.exs"

  test "adds build_ms as a nullable integer with no default" do
    %{rows: rows} =
      Repo.query!("""
      SELECT data_type, is_nullable, column_default
        FROM information_schema.columns
       WHERE table_name = 'game_stream_sessions' AND column_name = 'build_ms'
      """)

    assert [["integer", "YES", nil]] = rows
  end

  test "a row written without build_ms reads NULL" do
    {:ok, project} = Tasks.create_project(%{name: "GS build_ms #{System.unique_integer()}"})
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

    assert %SessionRecord{build_ms: nil} = Repo.get!(SessionRecord, id)
  end

  test "is reversible: it defines up/0 and down/0, and cites its task" do
    source = File.read!(Path.join(File.cwd!(), @migration))
    assert source =~ "def up do"
    assert source =~ "def down do"
    assert source =~ ~r/@moduledoc """\n\s+Task 01a17b51/
  end
end

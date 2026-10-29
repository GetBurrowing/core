defmodule Platform.Repo.Migrations.AddBuildMsToGameStreamSessions do
  @moduledoc """
  Task 01a17b51-76e1-7000-8eab-0288b6aa15b0 stage 3 (Unreal builds): the
  Building card says how long the task's last build took, so the one ended
  row records how long its session spent in `building`.

    * `build_ms` — milliseconds from the session start until the host first
      reported `connecting` or `live`. NULL for a session that never left
      `building` that way (it failed or was stopped while building), and for
      every row written before this column existed.

  Additive and nullable: no rewrite of old rows, no change to the wire.
  """

  use Ecto.Migration

  def up do
    alter table(:game_stream_sessions) do
      add(:build_ms, :integer)
    end
  end

  def down do
    alter table(:game_stream_sessions) do
      remove(:build_ms)
    end
  end
end

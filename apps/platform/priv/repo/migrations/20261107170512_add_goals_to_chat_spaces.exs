defmodule Platform.Repo.Migrations.AddGoalsToChatSpaces do
  @moduledoc """
  Task 01a1b6de stage 1: `chat_spaces.goals`, the install's goals in the
  owner's own words (0 to 3, each 1 to 500 characters; the changeset
  enforces both). `goal` stays and is always `goals[0]`
  (`Platform.Chat.Space.changeset/2` mirrors the two in one write), so
  `AgentsGoalHeartbeat.agents_space/0` and the heartbeat keep reading `goal`.

  Existing rows with a goal are backfilled to a one-item list.
  """
  use Ecto.Migration

  def up do
    alter table(:chat_spaces) do
      add :goals, {:array, :text}, null: false, default: []
    end

    execute("""
    UPDATE chat_spaces
       SET goals = ARRAY[goal]
     WHERE goal IS NOT NULL AND btrim(goal) <> ''
    """)
  end

  def down do
    alter table(:chat_spaces) do
      remove :goals
    end
  end
end

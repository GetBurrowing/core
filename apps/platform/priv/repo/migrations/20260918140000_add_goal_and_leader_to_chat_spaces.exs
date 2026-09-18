defmodule Platform.Repo.Migrations.AddGoalAndLeaderToChatSpaces do
  @moduledoc """
  Add `goal` and `leader_agent_id` to `chat_spaces` (task
  `01a0b491-0718-7001-8bba-bf50f119bb13` stage 1).

  A space may declare a single sentence of intent (`goal`) and name the
  agent accountable for it (`leader_agent_id`). Stage 3 derives a daily
  measurement from the goal; stage 4 renders both behind an env flag.

  BOTH COLUMNS ARE NULLABLE ON PURPOSE. Every existing space has no goal
  and no leader, and that is the correct steady state for all but one
  space — the agents space. A NOT NULL column with a backfilled sentinel
  would make "no goal declared" indistinguishable from "goal set to the
  sentinel", and the whole surface in stage 4 is conditional on the
  absence being readable.

  `on_delete: :nilify_all` rather than `:delete_all`: deleting an agent
  must not delete the space it happened to lead. The space outlives its
  leader and simply becomes leaderless, which is a state the stage-4
  render already has to handle (it is the same state as never having had
  one).

  No leader assignment and no goal value are seeded here. The first
  leader and the first goal are set at runtime through the existing
  role-assignment path and the stage-4 goal editor, so that reassigning
  either later is the same operation as setting it the first time.
  """

  use Ecto.Migration

  def change do
    alter table(:chat_spaces) do
      add(:goal, :text, null: true)

      add(
        :leader_agent_id,
        references(:agents, type: :binary_id, on_delete: :nilify_all),
        null: true
      )
    end
  end
end

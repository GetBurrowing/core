defmodule PlatformWeb.ChatLive.AgentsSheetHooksTest do
  @moduledoc """
  Coverage for `AgentsSheetHooks.resolve_armable/2` — the resolver behind the
  arm the Agents sheet's master switch does when it goes back on.

  The ordering rules matter:

    1. the space's remembered last agent, **if still a participant**
    2. else the sole agent participant
    3. else `:none`

  Rule 1's liveness guard is the subtle one. `ActiveAgentStore` retains its row
  on release, and `clear_if_match/2` leaves a *deleted* agent's participant id
  sitting in `last`, so `get_last_agent/1` can name somebody who is no longer in
  the space. Without the guard the master switch would arm a ghost —
  "last-agent-no-longer-a-participant falls through to rule 2" pins that.
  """

  use ExUnit.Case, async: true

  alias Platform.Chat.ActiveAgentStore
  alias PlatformWeb.ChatLive.AgentsSheetHooks

  setup do
    # Unique space id per test: the store is a globally-named ETS table, so
    # isolation comes from the key rather than from a sandbox.
    %{space_id: "space-#{:erlang.unique_integer([:positive])}"}
  end

  describe "resolve_armable/2 — rule 1 (remembered last agent)" do
    test "the remembered agent wins over a differently-ordered single agent", %{
      space_id: space_id
    } do
      remembered = agent("Historian")
      other = agent("Scribe")
      participants = [other, remembered, user("Alex")]

      ActiveAgentStore.set_active(space_id, remembered.id)
      ActiveAgentStore.clear_active(space_id)

      assert AgentsSheetHooks.resolve_armable(space_id, participants) == {:ok, remembered.id}
    end

    test "a remembered agent that is no longer a participant falls through to rule 2", %{
      space_id: space_id
    } do
      deleted = agent("Deleted")
      survivor = agent("Survivor")

      ActiveAgentStore.set_active(space_id, deleted.id)
      # `clear_if_match/2` is what AgentData calls when the agent is deleted:
      # the mutex is released but the id is retained as `last`.
      ActiveAgentStore.clear_if_match(space_id, deleted.id)
      assert ActiveAgentStore.get_last_agent(space_id) == deleted.id

      # Roster no longer contains the deleted agent — arming it would be a ghost.
      assert AgentsSheetHooks.resolve_armable(space_id, [survivor, user("Alex")]) ==
               {:ok, survivor.id}
    end

    test "a remembered agent no longer present, with two live agents, returns :none", %{
      space_id: space_id
    } do
      deleted = agent("Deleted")

      ActiveAgentStore.set_active(space_id, deleted.id)
      ActiveAgentStore.clear_if_match(space_id, deleted.id)

      assert AgentsSheetHooks.resolve_armable(space_id, [agent("A"), agent("B")]) == :none
    end

    test "two agents WITH history returns the remembered one", %{space_id: space_id} do
      first = agent("First")
      second = agent("Second")

      ActiveAgentStore.set_active(space_id, second.id)
      ActiveAgentStore.clear_active(space_id)

      assert AgentsSheetHooks.resolve_armable(space_id, [first, second]) == {:ok, second.id}
    end
  end

  describe "resolve_armable/2 — rule 2 (sole agent)" do
    test "exactly one agent participant arms it", %{space_id: space_id} do
      only = agent("Only")

      assert AgentsSheetHooks.resolve_armable(space_id, [user("Alex"), only, user("Ada")]) ==
               {:ok, only.id}
    end

    test "users do not count toward the agent tally", %{space_id: space_id} do
      only = agent("Only")

      assert AgentsSheetHooks.resolve_armable(space_id, [only]) == {:ok, only.id}
    end
  end

  describe "resolve_armable/2 — rule 3 (:none)" do
    test "two agents and no history returns :none", %{space_id: space_id} do
      assert AgentsSheetHooks.resolve_armable(space_id, [agent("A"), agent("B"), user("Alex")]) ==
               :none
    end

    test "zero agents returns :none", %{space_id: space_id} do
      assert AgentsSheetHooks.resolve_armable(space_id, [user("Alex"), user("Ada")]) == :none
    end

    test "an empty roster returns :none", %{space_id: space_id} do
      assert AgentsSheetHooks.resolve_armable(space_id, []) == :none
    end

    test "a nil roster returns :none (assign not yet seeded)", %{space_id: space_id} do
      assert AgentsSheetHooks.resolve_armable(space_id, nil) == :none
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────
  # Plain maps in the shape `:space_participants` carries — no DB needed, the
  # resolver only reads `:id` and `:participant_type`.

  defp agent(display_name) do
    %{
      id: Ecto.UUID.generate(),
      participant_type: "agent",
      participant_id: Ecto.UUID.generate(),
      display_name: display_name
    }
  end

  defp user(display_name) do
    %{
      id: Ecto.UUID.generate(),
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: display_name
    }
  end
end

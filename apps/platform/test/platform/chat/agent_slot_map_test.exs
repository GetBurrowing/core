defmodule Platform.Chat.AgentSlotMapTest do
  @moduledoc """
  `Chat.agent_slot_map_for_participants/1` (task 01a1557a rung 3 stage 1):
  participant.id -> the slot id whose `--ag-<id>*` theme tokens the agent
  wears. It replaced the OKLCH accent map in stage 2.
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo

  defp space! do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{name: "Slot Test #{n}", slug: "slot-test-#{n}", kind: "channel"})

    space
  end

  defp agent!(color) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "slot-agent-#{n}",
        name: "Slot Agent #{n}",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        color: color,
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    agent
  end

  test "maps each agent participant to its stored slot, and nil or unknown to blue" do
    space = space!()

    {:ok, teal} = Chat.add_agent_participant(space.id, agent!("teal"))
    {:ok, rose} = Chat.add_agent_participant(space.id, agent!("rose"))
    {:ok, none} = Chat.add_agent_participant(space.id, agent!(nil))
    {:ok, odd} = Chat.add_agent_participant(space.id, agent!("magenta"))

    map = Chat.agent_slot_map_for_participants(Chat.list_participants(space.id))

    assert map == %{teal.id => "teal", rose.id => "rose", none.id => "blue", odd.id => "blue"}
  end

  test "human participants are not in the map, and no agents is an empty map" do
    human = %Participant{
      id: Ecto.UUID.generate(),
      participant_type: "user",
      participant_id: Ecto.UUID.generate()
    }

    assert Chat.agent_slot_map_for_participants([human]) == %{}
    assert Chat.agent_slot_map_for_participants([]) == %{}
  end
end

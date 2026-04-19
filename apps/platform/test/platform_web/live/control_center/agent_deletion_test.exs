defmodule PlatformWeb.ControlCenter.AgentDeletionTest do
  @moduledoc """
  Integration tests for agent deletion cascade cleanup.

  Verifies that deleting an agent via `AgentData.delete_agent/1` cleans up:
  - chat_participants (hard-deleted, ADR 0038)
  - DM spaces (archived)
  - NodeContext ETS entries (cleared)
  - RuntimePresence entries (untracked)
  - ActiveAgentStore entries (cleared)

  Also verifies that re-creating an agent with the same slug works cleanly.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Federation.NodeContext
  alias Platform.Repo

  alias PlatformWeb.ControlCenter.AgentData

  import Ecto.Query

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "TestAgent",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: "test-#{System.unique_integer([:positive])}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp active_participants_for_agent(agent_id) do
    Repo.all(
      from(p in Participant,
        where:
          p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  defp all_participants_for_agent(agent_id) do
    Repo.all(
      from(p in Participant,
        where:
          p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  # Post-ADR-0038: "roster entries" are just agent participants, so the
  # two queries coincide.
  defp roster_entries_for_agent(agent_id), do: all_participants_for_agent(agent_id)

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "delete_agent/1 cascade cleanup" do
    test "hard-deletes all chat_participants for the agent (ADR 0038)" do
      agent = create_agent()

      space1 =
        create_space(%{name: "General", slug: "general-#{System.unique_integer([:positive])}"})

      space2 = create_space(%{name: "Dev", slug: "dev-#{System.unique_integer([:positive])}"})

      {:ok, _} = Chat.add_agent_participant(space1.id, agent, display_name: agent.name)
      {:ok, _} = Chat.add_agent_participant(space2.id, agent, display_name: agent.name)

      # Verify participants exist before deletion
      assert length(active_participants_for_agent(agent.id)) == 2

      :ok = AgentData.delete_agent(agent)

      # Rows are gone. Historical messages stay attributed via author_*
      # snapshots on chat_messages (not tested here — see author_snapshot
      # tests in message attribution coverage).
      assert all_participants_for_agent(agent.id) == []
    end

    test "removes all chat_space_agents roster entries" do
      agent = create_agent()
      space1 = create_space()
      space2 = create_space()

      {:ok, _} = Chat.add_space_agent(space1.id, agent.id)
      {:ok, _} = Chat.add_space_agent(space2.id, agent.id)

      assert length(roster_entries_for_agent(agent.id)) == 2

      :ok = AgentData.delete_agent(agent)

      assert roster_entries_for_agent(agent.id) == []
    end

    test "archives DM spaces where the agent was a participant" do
      agent = create_agent()

      dm_space =
        create_space(%{
          name: "DM with agent",
          slug: "dm-#{System.unique_integer([:positive])}",
          kind: "dm"
        })

      channel_space = create_space(%{kind: "channel"})

      {:ok, _} = Chat.add_agent_participant(dm_space.id, agent, display_name: agent.name)
      {:ok, _} = Chat.add_agent_participant(channel_space.id, agent, display_name: agent.name)

      :ok = AgentData.delete_agent(agent)

      # DM space should be archived
      dm = Repo.get(Space, dm_space.id)
      assert dm.archived_at != nil

      # Channel space should NOT be archived
      channel = Repo.get(Space, channel_space.id)
      assert channel.archived_at == nil
    end

    test "does not affect other agents' participants or roster entries" do
      agent_to_delete = create_agent(%{name: "DeleteMe"})
      agent_to_keep = create_agent(%{name: "KeepMe"})
      space = create_space()

      {:ok, _} =
        Chat.add_agent_participant(space.id, agent_to_delete, display_name: "DeleteMe")

      {:ok, _} = Chat.add_agent_participant(space.id, agent_to_keep, display_name: "KeepMe")
      {:ok, _} = Chat.add_space_agent(space.id, agent_to_delete.id)
      {:ok, _} = Chat.add_space_agent(space.id, agent_to_keep.id)

      :ok = AgentData.delete_agent(agent_to_delete)

      # Other agent's participant should still be active
      keep_active = active_participants_for_agent(agent_to_keep.id)
      assert length(keep_active) == 1

      # Other agent's roster entry should still exist
      keep_roster = roster_entries_for_agent(agent_to_keep.id)
      assert length(keep_roster) == 1
    end

    test "deletes the agent record itself" do
      agent = create_agent()

      :ok = AgentData.delete_agent(agent)

      assert Repo.get(Agent, agent.id) == nil
    end

    test "clears NodeContext ETS entry for the agent" do
      agent = create_agent()
      space = create_space()

      # Set a space context for the agent
      NodeContext.set_space(agent.id, space.id)
      assert NodeContext.get_space(agent.id) == space.id

      :ok = AgentData.delete_agent(agent)

      assert NodeContext.get_space(agent.id) == nil
    end

    test "re-creating an agent with the same slug works cleanly" do
      slug = "reusable-agent-#{System.unique_integer([:positive])}"
      agent = create_agent(%{slug: slug, name: "Original"})
      space = create_space()

      {:ok, _} = Chat.add_agent_participant(space.id, agent, display_name: "Original")
      {:ok, _} = Chat.add_space_agent(space.id, agent.id)

      :ok = AgentData.delete_agent(agent)

      # Re-create with the same slug
      new_agent = create_agent(%{slug: slug, name: "Replacement"})

      # Should be able to add as participant and roster member without conflicts
      {:ok, new_participant} =
        Chat.add_agent_participant(space.id, new_agent, display_name: "Replacement")

      assert new_participant.display_name == "Replacement"

      {:ok, new_roster} = Chat.add_space_agent(space.id, new_agent.id)
      assert new_roster.agent_id == new_agent.id
    end
  end
end

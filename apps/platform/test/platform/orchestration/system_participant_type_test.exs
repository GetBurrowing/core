defmodule Platform.Orchestration.SystemParticipantTypeTest do
  @moduledoc """
  The synthetic per-space TaskRouter participant is typed `"system"`, not
  `"agent"`.

  The load-bearing assertion is that the space-health DENOMINATOR does not move
  when execution spaces exist — a test with zero execution spaces cannot fail
  for the reason this change exists. Every router here is minted by calling
  `ExecutionSpace.ensure_system_participant/1`, never hand-inserted, so the
  assertions are about the real write path.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Participant, SpaceAgentPresence}
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo

  defp create_space(kind \\ "channel") do
    {:ok, space} =
      Chat.create_space(%{
        name: "Test",
        slug: "s-#{System.unique_integer([:positive])}",
        kind: kind
      })

    space
  end

  defp create_agent do
    Repo.insert!(%Agent{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Agent #{System.unique_integer([:positive])}",
      status: "active"
    })
  end

  test "execution-space routers do not move the roster denominator" do
    space = create_space()

    for _ <- 1..3 do
      agent = create_agent()
      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
    end

    before = length(Chat.list_active_space_agents(space.id))
    assert before == 3
    assert SpaceAgentPresence.composite_for_space(space.id).total == 3

    # Each execution space mints a router through the real write path.
    routers =
      for _ <- 1..2 do
        exec = create_space("execution")
        {:ok, router} = ExecutionSpace.ensure_system_participant(exec.id)
        # ...and one in the roster space itself, the shape that inflated it.
        {:ok, _} = ExecutionSpace.ensure_system_participant(space.id)
        router
      end

    assert length(Chat.list_active_space_agents(space.id)) == before,
           "denominator moved once execution-space routers existed"

    assert SpaceAgentPresence.composite_for_space(space.id).total == before

    # Asserted AFTER the denominator so a regression detonates naming the thing
    # that matters, not its mechanism.
    assert Enum.all?(routers, &(&1.participant_type == "system"))

    # Positive control: the denominator is not hardcoded — a real agent moves it
    # by exactly one.
    extra = create_agent()
    {:ok, _} = Chat.add_space_agent(space.id, extra.id)
    assert length(Chat.list_active_space_agents(space.id)) == before + 1
  end

  test "agent-typed participant listings exclude the router at each call site" do
    space = create_space("execution")
    agent = create_agent()
    {:ok, _} = Chat.add_space_agent(space.id, agent.id)
    {:ok, router} = ExecutionSpace.ensure_system_participant(space.id)

    # chat/presence.ex path
    presence_ids =
      Chat.list_participants(space.id, participant_type: "agent") |> Enum.map(& &1.id)

    refute router.id in presence_ids

    # federation/tool_surface.ex path — through the real tool
    assert {:ok, %{agents: rows}} =
             ToolSurface.execute("space_list_agents", %{"space_id" => space.id}, %{})

    refute router.id in Enum.map(rows, & &1.participant_id)
    assert agent.id in Enum.map(rows, & &1.agent_id)
  end

  test "ensure_system_participant/1 is idempotent — exactly one system row" do
    space = create_space("execution")

    {:ok, first} = ExecutionSpace.ensure_system_participant(space.id)
    {:ok, second} = ExecutionSpace.ensure_system_participant(space.id)
    assert first.id == second.id

    count =
      Repo.aggregate(
        from(p in Participant, where: p.space_id == ^space.id and p.participant_type == "system"),
        :count
      )

    assert count == 1
  end

  test "the router can still post into its execution space after the retype" do
    space = create_space("execution")

    assert {:ok, message} = ExecutionSpace.post_log(space.id, "dispatch delivered")
    assert message.content == "dispatch delivered"
    assert message.author_participant_type == "system"
  end
end

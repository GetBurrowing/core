defmodule Platform.Goals.SpaceClaimTest do
  @moduledoc """
  Goals 7/8 stage 4 (task 01a1dfc1-dffb): Goals answers core's
  `claims_space_goal?/1`, so a space an active goal is opened to no longer
  gets core's old single-goal heartbeat. With the switch off it claims
  nothing and runs no query.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.SpaceClaim
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat

  setup do
    enable_goals!()
    org = org_id!()
    owner = member!(org)
    coach = agent!()
    goal = goal!(owner, org, %{coach_agent_id: coach.id, unit: "steps"})
    %{org: org, owner: owner, coach: coach, goal: goal}
  end

  defp opened_space!(c) do
    space = space!(c.org)
    join_space!(space.id, :user, c.owner.id)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, space.id})
    space
  end

  defp count_queries(fun) do
    test_pid = self()
    handler_id = "goals-space-claim-#{unique()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, _meta, _config ->
          if self() == test_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain(0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(n) do
    receive do
      :repo_query -> drain(n + 1)
    after
      0 -> n
    end
  end

  test "switch off: false, with no query; switch on: the same handler sees one", c do
    space = opened_space!(c)

    assert {true, on_queries} = count_queries(fn -> SpaceClaim.claimed?(space.id) end)
    assert on_queries > 0

    Application.put_env(:goals, :enabled, false)
    assert {false, 0} = count_queries(fn -> SpaceClaim.claimed?(space.id) end)

    assert {false, 0} =
             count_queries(fn -> Platform.Goals.Extension.claims_space_goal?(space.id) end)
  end

  test "a non-UUID id is false with no query" do
    assert {false, 0} = count_queries(fn -> SpaceClaim.claimed?("not-a-uuid") end)
    assert {false, 0} = count_queries(fn -> SpaceClaim.claimed?(nil) end)
  end

  test "only an active goal opened to the space claims it", c do
    bare = space!(c.org)
    refute SpaceClaim.claimed?(bare.id)

    space = opened_space!(c)
    assert SpaceClaim.claimed?(space.id)
    assert Platform.Goals.Extension.claims_space_goal?(space.id)
    assert Platform.Extensions.space_goal_claimed?(space.id)

    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{status: "paused"})
    refute SpaceClaim.claimed?(space.id)

    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{status: "active"})
    assert SpaceClaim.claimed?(space.id)

    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:space, space.id})
    refute SpaceClaim.claimed?(space.id)
  end

  describe "end to end with core's heartbeat" do
    setup c do
      leader = agent!()
      prior = %{"measurement" => 3, "measured_at" => "2026-01-01T00:00:00Z", "goal" => "Old"}

      {:ok, space} =
        Chat.create_space(%{
          name: "Agents #{unique()}",
          slug: "agents-#{unique()}",
          kind: "channel",
          org_id: c.org,
          goal: "Close backlog items in Suite",
          leader_agent_id: leader.id,
          metadata: %{"goal_heartbeat" => prior}
        })

      join_space!(space.id, :user, c.owner.id)
      %{agents_space: space, prior: prior}
    end

    defp prompt, do: AgentsGoalHeartbeat.build_prompt(AgentsGoalHeartbeat.gather_context())

    defp heartbeat_row(space),
      do: Chat.get_space(space.id).metadata["goal_heartbeat"]

    test "an active linked goal stands the heartbeat down until it is closed", c do
      assert Platform.Goals.Extension in Platform.Extensions.list()
      assert AgentsGoalHeartbeat.agents_space().id == c.agents_space.id

      {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.agents_space.id})

      assert {:error, {:no_measurement, _}} = prompt()
      assert heartbeat_row(c.agents_space) == c.prior

      {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:space, c.agents_space.id})
      assert {:ok, _} = prompt()
    end

    test "with the switch off the grant claims nothing", c do
      {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.agents_space.id})
      Application.put_env(:goals, :enabled, false)

      refute Platform.Extensions.space_goal_claimed?(c.agents_space.id)
      assert {:ok, _} = prompt()
    end
  end

  test "Extensions.validate/0 is :ok with the switch on and off" do
    assert Platform.Extensions.validate() == :ok
    Application.put_env(:goals, :enabled, false)
    assert Platform.Extensions.validate() == :ok
  end
end

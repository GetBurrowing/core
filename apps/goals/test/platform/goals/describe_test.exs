defmodule Platform.Goals.DescribeTest do
  @moduledoc """
  The page reads (task 01a1dfc1, Goals 4/8 stage 1): `describe_goals/1`,
  `describe_goal/2` and `list_audience_options/2`. Sets the global
  `:goals, :enabled`, so not async.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Goals

  setup do
    enable_goals!()
    org_id = org_id!()
    owner = member!(org_id)
    {:ok, org_id: org_id, owner: owner}
  end

  defp coached_goal!(owner, org_id, attrs \\ %{}) do
    coach = coach_agent!()
    goal = goal!(owner, org_id, attrs)
    {:ok, goal} = Goals.update_goal(owner, goal.id, %{coach_agent_id: coach.id})
    {goal, coach}
  end

  describe "describe_goals/1 and describe_goal/2" do
    test "the owner, the coach and a viewer each get their role; only a viewer has the audience hidden",
         %{org_id: org_id, owner: owner} do
      {goal, coach} = coached_goal!(owner, org_id, %{title: "Learn Spanish"})
      viewer = user!()
      {:ok, _} = Goals.open_goal(owner, goal.id, {:user, viewer.id})
      {:ok, _} = Goals.open_goal(owner, goal.id, {:team, org_id})

      audience = [
        %{type: :user, id: viewer.id, name: viewer.name},
        %{type: :team, id: org_id, name: Platform.Repo.get!(Platform.Tenancy.Org, org_id).name}
      ]

      assert {:ok, card} = Goals.describe_goal(owner, goal.id)
      assert card.role == :owner
      assert card.goal.id == goal.id
      assert card.owner_name == owner.name
      assert card.coach_name == coach.name
      assert card.audience == audience

      assert {:ok, %{role: :coach, audience: ^audience}} = Goals.describe_goal(coach, goal.id)

      assert {:ok, %{role: :viewer, audience: :hidden} = seen} =
               Goals.describe_goal(viewer, goal.id)

      assert seen.owner_name == owner.name
      assert seen.coach_name == coach.name
    end

    test "a personal goal has an empty audience and no coach", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)

      assert {:ok, %{role: :owner, audience: [], coach_name: nil, current_stop: nil}} =
               Goals.describe_goal(owner, goal.id)
    end

    test "the current stop is the first unreached stop by position", %{
      org_id: org_id,
      owner: owner
    } do
      goal = goal!(owner, org_id)

      {:ok, _} =
        Goals.put_stops(owner, goal.id, [
          %{label: "First 1,000", reached_on: ~D[2026-10-01]},
          %{label: "30,000"},
          %{label: "1 million"}
        ])

      assert {:ok, %{current_stop: %{label: "30,000", position: 2}}} =
               Goals.describe_goal(owner, goal.id)

      all_reached = goal!(owner, org_id)

      {:ok, _} =
        Goals.put_stops(owner, all_reached.id, [%{label: "x", reached_on: ~D[2026-10-01]}])

      assert {:ok, %{current_stop: nil}} = Goals.describe_goal(owner, all_reached.id)
    end

    test "a stranger, a missing id and a malformed id are the same :not_found", %{
      org_id: org_id,
      owner: owner
    } do
      goal = goal!(owner, org_id)
      stranger = member!(org_id)

      assert Goals.describe_goal(stranger, goal.id) == {:error, :not_found}
      assert Goals.describe_goal(owner, Ecto.UUID.generate()) == {:error, :not_found}
      assert Goals.describe_goal(owner, "not-a-uuid") == {:error, :not_found}
      assert Goals.describe_goal(nil, goal.id) == {:error, :not_found}
    end

    test "lists exactly the visible goals, newest first", %{org_id: org_id, owner: owner} do
      older = goal!(owner, org_id, %{title: "older"})
      newer = goal!(owner, org_id, %{title: "newer"})
      other = member!(org_id)
      _unseen = goal!(other, org_id, %{title: "theirs"})
      shared = goal!(other, org_id, %{title: "shared with owner"})
      {:ok, _} = Goals.open_goal(other, shared.id, {:user, owner.id})

      assert {:ok, cards} = Goals.describe_goals(owner)
      {:ok, goals} = Goals.list_goals(owner)

      assert Enum.map(cards, & &1.goal.id) == Enum.map(goals, & &1.id)
      assert MapSet.new(cards, & &1.goal.id) == MapSet.new([older.id, newer.id, shared.id])

      assert %{role: :viewer, audience: :hidden, owner_name: other_name} =
               Enum.find(cards, &(&1.goal.id == shared.id))

      assert other_name == other.name
      assert {:ok, []} = Goals.describe_goals(user!())
      assert {:ok, []} = Goals.describe_goals(nil)
    end

    test "issues the same number of queries for one goal as for six", %{
      org_id: org_id,
      owner: owner
    } do
      one = fn ->
        {goal, _} = coached_goal!(owner, org_id)
        {:ok, _} = Goals.open_goal(owner, goal.id, {:user, user!().id})
        {:ok, _} = Goals.put_stops(owner, goal.id, [%{label: "a"}])
      end

      one.()
      single = count_queries(fn -> {:ok, [_]} = Goals.describe_goals(owner) end)

      for _ <- 1..5, do: one.()
      many = count_queries(fn -> {:ok, [_, _, _, _, _, _]} = Goals.describe_goals(owner) end)

      assert single > 0
      assert many == single
    end
  end

  describe "list_audience_options/2" do
    setup %{org_id: org_id, owner: owner} do
      teammate = member!(org_id)
      external = external_member!(org_id)

      # An org where the owner is external: not a team they may open to, and
      # its members are not people they may open to.
      outside_org = org_id!()
      join_org!(owner, outside_org, external: true)
      outsider = member!(outside_org)

      joined = space!(org_id)
      join_space!(joined.id, :user, owner.id)
      not_joined = space!(org_id)

      archived = space!(org_id)
      join_space!(archived.id, :user, owner.id)

      archived
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Platform.Repo.update!()

      {:ok, dm} =
        Platform.Chat.create_space(%{kind: "dm", name: "dm #{unique()}", org_id: org_id})

      join_space!(dm.id, :user, owner.id)

      left = space!(org_id)
      left |> Map.fetch!(:id) |> join_space!(:user, owner.id) |> leave_space!()

      goal = goal!(owner, org_id)

      %{
        goal: goal,
        teammate: teammate,
        external: external,
        outside_org: outside_org,
        outsider: outsider,
        joined: joined,
        not_joined: not_joined,
        archived: archived,
        dm: dm,
        left: left
      }
    end

    test "people, teams and spaces the owner may open to", ctx do
      assert {:ok, %{people: people, teams: teams, spaces: spaces}} =
               Goals.list_audience_options(ctx.owner, ctx.goal.id)

      assert [%{id: id, name: name, detail: nil, open?: false}] = people
      assert id == ctx.teammate.id
      assert name == ctx.teammate.name

      # owner + teammate; the external member is not counted.
      assert [%{id: org_id, detail: 2, open?: false}] = teams
      assert org_id == ctx.org_id

      assert [%{id: space_id, name: space_name, detail: nil, open?: false}] = spaces
      assert space_id == ctx.joined.id
      assert space_name == ctx.joined.name
    end

    test "excludes external members, the owner, DMs, archived and unjoined spaces", ctx do
      {:ok, options} = Goals.list_audience_options(ctx.owner, ctx.goal.id)
      people = Enum.map(options.people, & &1.id)
      spaces = Enum.map(options.spaces, & &1.id)

      for user <- [ctx.owner, ctx.external, ctx.outsider], do: refute(user.id in people)
      refute ctx.outside_org in Enum.map(options.teams, & &1.id)

      for space <- [ctx.not_joined, ctx.archived, ctx.dm, ctx.left],
          do: refute(space.id in spaces)
    end

    test "open? follows the goal's grants", ctx do
      for audience <- [{:user, ctx.teammate.id}, {:team, ctx.org_id}, {:space, ctx.joined.id}] do
        {:ok, _} = Goals.open_goal(ctx.owner, ctx.goal.id, audience)
      end

      {:ok, options} = Goals.list_audience_options(ctx.owner, ctx.goal.id)

      assert Enum.all?(options.people ++ options.teams ++ options.spaces, & &1.open?)

      {:ok, _} = Goals.close_goal(ctx.owner, ctx.goal.id, {:team, ctx.org_id})
      {:ok, options} = Goals.list_audience_options(ctx.owner, ctx.goal.id)
      assert [%{open?: false}] = options.teams
    end

    test "marks the agents channel, the space core's agents rail block shows", ctx do
      previous = Application.fetch_env(:platform, :agents_goal_surface)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:platform, :agents_goal_surface, value)
          :error -> Application.delete_env(:platform, :agents_goal_surface)
        end
      end)

      {:ok, _} =
        ctx.joined
        |> Ecto.Changeset.change(goal: "Ship the redesign")
        |> Platform.Repo.update()

      # Flag off: core shows no agents block, so nothing is marked.
      Application.put_env(:platform, :agents_goal_surface, false)
      {:ok, options} = Goals.list_audience_options(ctx.owner, ctx.goal.id)
      assert Enum.all?(options.spaces, &is_nil(&1.detail))

      Application.put_env(:platform, :agents_goal_surface, true)
      assert %{space: %{id: agents_id}} = Platform.Chat.Sidebar.agents_rail_block()
      {:ok, options} = Goals.list_audience_options(ctx.owner, ctx.goal.id)

      for space <- options.spaces do
        assert space.detail == if(space.id == agents_id, do: :agents)
      end

      if agents_id == ctx.joined.id,
        do: assert([%{detail: :agents}] = options.spaces)
    end

    test "a viewer and the coach are :forbidden, a stranger :not_found", ctx do
      {:ok, _} = Goals.open_goal(ctx.owner, ctx.goal.id, {:user, ctx.teammate.id})
      coach = coach_agent!()
      {:ok, _} = Goals.update_goal(ctx.owner, ctx.goal.id, %{coach_agent_id: coach.id})

      assert Goals.list_audience_options(ctx.teammate, ctx.goal.id) == {:error, :forbidden}
      assert Goals.list_audience_options(coach, ctx.goal.id) == {:error, :forbidden}
      assert Goals.list_audience_options(ctx.outsider, ctx.goal.id) == {:error, :not_found}
      assert Goals.list_audience_options(ctx.owner, "not-a-uuid") == {:error, :not_found}
    end
  end

  # Counts Platform.Repo queries this process issues while `fun` runs.
  defp count_queries(fun) do
    test_pid = self()
    handler = "goals-describe-count-#{unique()}"

    :telemetry.attach(
      handler,
      [:platform, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, :goals_query)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain(0)
  end

  defp drain(n) do
    receive do
      :goals_query -> drain(n + 1)
    after
      0 -> n
    end
  end
end

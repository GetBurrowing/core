defmodule Platform.Goals.PrivacyTest do
  # Sets the global `:goals, :enabled`, so not async.
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Goals
  alias Platform.Goals.Goal

  setup do
    enable_goals!()
    org_id = org_id!()
    owner = member!(org_id)
    {:ok, org_id: org_id, owner: owner, goal: goal!(owner, org_id)}
  end

  defp sees?(actor, goal) do
    match?({:ok, %Goal{}}, Goals.get_goal(actor, goal.id)) and
      goal.id in (actor |> Goals.list_goals() |> elem(1) |> Enum.map(& &1.id))
  end

  defp hidden?(actor, goal) do
    Goals.get_goal(actor, goal.id) == {:error, :not_found} and
      goal.id not in (actor |> Goals.list_goals() |> elem(1) |> Enum.map(& &1.id))
  end

  defp reload(goal) do
    id = goal.id
    Repo.one(from(g in Goal, where: g.id == ^id))
  end

  describe "a personal goal" do
    test "is invisible to a second user in the same org and to a root admin",
         %{org_id: org_id, owner: owner, goal: goal} do
      before = reload(goal)
      random = Ecto.UUID.generate()
      other_space = space!(org_id)
      join_space!(other_space.id, :user, owner.id)

      for outsider <- [member!(org_id), root_admin!()] do
        missing = Goals.get_goal(outsider, random)
        assert missing == {:error, :not_found}

        assert Goals.get_goal(outsider, goal.id) == missing
        assert Goals.update_goal(outsider, goal.id, %{title: "taken"}) == missing
        assert Goals.update_goal(outsider, random, %{title: "taken"}) == missing
        assert Goals.open_goal(outsider, goal.id, {:user, outsider.id}) == missing
        assert Goals.open_goal(outsider, random, {:user, outsider.id}) == missing
        assert Goals.close_goal(outsider, goal.id, {:user, outsider.id}) == missing
        assert Goals.close_goal(outsider, random, {:user, outsider.id}) == missing
        assert Goals.list_audience(outsider, goal.id) == missing
        assert Goals.list_audience(outsider, random) == missing

        {:ok, listed} = Goals.list_goals(outsider)
        refute goal.id in Enum.map(listed, & &1.id)
      end

      assert reload(goal) == before
      assert {:ok, []} = Goals.list_audience(owner, goal.id)
    end

    test "a malformed id is :not_found and does not raise", %{owner: owner} do
      assert Goals.get_goal(owner, "not-a-uuid") == {:error, :not_found}
      assert Goals.get_goal(owner, nil) == {:error, :not_found}
      assert Goals.update_goal(owner, 42, %{}) == {:error, :not_found}
    end

    test "an actor that is not a user or an agent sees nothing", %{owner: owner, goal: goal} do
      for actor <- [nil, owner.id, %{id: owner.id}] do
        assert Goals.get_goal(actor, goal.id) == {:error, :not_found}
        assert Goals.list_goals(actor) == {:ok, []}
        assert Goals.update_goal(actor, goal.id, %{title: "x"}) == {:error, :not_found}
      end
    end
  end

  describe "opened to a person" do
    test "that user sees it, a third does not; closing removes it",
         %{org_id: org_id, owner: owner, goal: goal} do
      reader = user!()
      third = member!(org_id)

      assert hidden?(reader, goal)
      assert {:ok, %Goal{kind: "shared"}} = Goals.open_goal(owner, goal.id, {:user, reader.id})

      assert sees?(reader, goal)
      assert hidden?(third, goal)

      assert {:ok, _} = Goals.close_goal(owner, goal.id, {:user, reader.id})
      assert hidden?(reader, goal)
    end
  end

  describe "opened to a team" do
    test "a non-external member sees it; another org, an external and a root member do not",
         %{org_id: org_id, owner: owner, goal: goal} do
      member = member!(org_id)
      other_org_member = member!(org_id!())
      external = external_member!(org_id)
      root_member = join_org!(user!(), Platform.TenancyFixtures.acme_org_id())

      assert hidden?(member, goal)
      assert {:ok, _} = Goals.open_goal(owner, goal.id, {:team, org_id})

      assert sees?(member, goal)
      assert hidden?(other_org_member, goal)
      assert hidden?(external, goal)
      assert hidden?(root_member, goal)
      assert hidden?(root_admin!(), goal)

      assert {:ok, _} = Goals.close_goal(owner, goal.id, {:team, org_id})
      assert hidden?(member, goal)
    end
  end

  describe "opened to a space" do
    test "a current participant sees it; one who left and a non-participant do not",
         %{org_id: org_id, owner: owner, goal: goal} do
      space = space!(org_id)
      join_space!(space.id, :user, owner.id)

      current = member!(org_id)
      join_space!(space.id, :user, current.id)

      left = member!(org_id)
      left_row = join_space!(space.id, :user, left.id)

      outsider = member!(org_id)

      assert {:ok, _} = Goals.open_goal(owner, goal.id, {:space, space.id})
      assert sees?(current, goal)
      assert sees?(left, goal)

      leave_space!(left_row)
      assert hidden?(left, goal)
      assert sees?(current, goal)
      assert hidden?(outsider, goal)

      assert {:ok, _} = Goals.close_goal(owner, goal.id, {:space, space.id})
      assert hidden?(current, goal)
    end
  end

  describe "an audience member" do
    test "reads but cannot update, open, close or list the audience",
         %{org_id: org_id, owner: owner, goal: goal} do
      reader = member!(org_id)
      {:ok, _} = Goals.open_goal(owner, goal.id, {:team, org_id})
      before = reload(goal)

      assert {:ok, %Goal{}} = Goals.get_goal(reader, goal.id)
      assert Goals.update_goal(reader, goal.id, %{title: "mine"}) == {:error, :forbidden}
      assert Goals.open_goal(reader, goal.id, {:user, user!().id}) == {:error, :forbidden}
      assert Goals.close_goal(reader, goal.id, {:team, org_id}) == {:error, :forbidden}
      assert Goals.list_audience(reader, goal.id) == {:error, :forbidden}

      assert reload(goal) == before
    end
  end

  describe "agents" do
    test "the coach reads and updates but cannot open or close; another agent sees nothing",
         %{org_id: org_id, owner: owner, goal: goal} do
      coach = coach_agent!()
      {:ok, _} = Goals.update_goal(owner, goal.id, %{coach_agent_id: coach.id})

      assert {:ok, %Goal{}} = Goals.get_goal(coach, goal.id)

      assert {:ok, %Goal{title: "Run more"}} =
               Goals.update_goal(coach, goal.id, %{title: "Run more"})

      assert {:ok, [%Goal{}]} = Goals.list_goals(coach)
      assert {:ok, []} = Goals.list_audience(coach, goal.id)

      assert Goals.open_goal(coach, goal.id, {:team, org_id}) == {:error, :forbidden}
      assert Goals.close_goal(coach, goal.id, {:team, org_id}) == {:error, :forbidden}

      # The coach cannot reassign the coach.
      other = agent!()
      {:ok, updated} = Goals.update_goal(coach, goal.id, %{coach_agent_id: other.id, why: "fit"})
      assert updated.coach_agent_id == coach.id
      assert updated.why == "fit"

      assert hidden?(other, goal)
      assert Goals.update_goal(other, goal.id, %{title: "x"}) == {:error, :not_found}
    end

    test "an agent participant of an opened space reads and cannot update",
         %{org_id: org_id, owner: owner, goal: goal} do
      space = space!(org_id)
      join_space!(space.id, :user, owner.id)
      agent = agent!()
      row = join_space!(space.id, :agent, agent.id)

      assert hidden?(agent, goal)
      {:ok, _} = Goals.open_goal(owner, goal.id, {:space, space.id})

      assert sees?(agent, goal)
      assert Goals.update_goal(agent, goal.id, %{title: "x"}) == {:error, :forbidden}
      assert Goals.open_goal(agent, goal.id, {:space, space.id}) == {:error, :forbidden}

      leave_space!(row)
      assert hidden?(agent, goal)
    end
  end
end

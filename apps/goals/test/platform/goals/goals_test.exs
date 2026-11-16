defmodule Platform.Goals.GoalsTest do
  # Sets the global `:goals, :enabled`, so not async.
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Goals
  alias Platform.Goals.{Goal, Grant}

  setup do
    enable_goals!()
    org_id = org_id!()
    {:ok, org_id: org_id, owner: member!(org_id)}
  end

  defp grant_count(goal),
    do: Repo.aggregate(from(gr in Grant, where: gr.goal_id == ^goal.id), :count)

  describe "the switch" do
    test "every function answers :goals_disabled while off", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      Application.put_env(:goals, :enabled, false)

      disabled = {:error, :goals_disabled}
      assert Goals.create_goal(owner, %{org_id: org_id, title: "x"}) == disabled
      assert Goals.list_goals(owner) == disabled
      assert Goals.get_goal(owner, goal.id) == disabled
      assert Goals.update_goal(owner, goal.id, %{title: "x"}) == disabled
      assert Goals.open_goal(owner, goal.id, {:team, org_id}) == disabled
      assert Goals.close_goal(owner, goal.id, {:team, org_id}) == disabled
      assert Goals.list_audience(owner, goal.id) == disabled
      assert Goals.describe_goals(owner) == disabled
      assert Goals.describe_goal(owner, goal.id) == disabled
      assert Goals.list_audience_options(owner, goal.id) == disabled
    end
  end

  describe "create_goal/2" do
    test "the owner is the actor, kind defaults to personal, and attrs cannot set the owner",
         %{org_id: org_id, owner: owner} do
      someone = user!()

      assert {:ok, goal} =
               Goals.create_goal(owner, %{
                 "org_id" => org_id,
                 "title" => "Read 20 books",
                 "owner_user_id" => someone.id
               })

      assert goal.owner_user_id == owner.id
      assert goal.org_id == org_id
      assert goal.kind == "personal"
    end

    test "an org the user cannot read is refused", %{owner: owner} do
      elsewhere = org_id!()

      assert Goals.create_goal(owner, %{org_id: elsewhere, title: "x"}) ==
               {:error, :org_not_visible}

      assert Goals.create_goal(owner, %{org_id: "nope", title: "x"}) == {:error, :org_not_visible}
      assert Goals.create_goal(owner, %{title: "x"}) == {:error, :org_not_visible}
    end

    test "an agent cannot create a goal", %{org_id: org_id} do
      assert Goals.create_goal(agent!(), %{org_id: org_id, title: "x"}) == {:error, :not_found}
    end

    test "a bad value is a changeset error", %{org_id: org_id, owner: owner} do
      assert {:error, %Ecto.Changeset{}} =
               Goals.create_goal(owner, %{org_id: org_id, title: "x", rhythm: "hourly"})
    end
  end

  describe "list_goals/1" do
    test "newest first, the owner's own", %{org_id: org_id, owner: owner} do
      first = goal!(owner, org_id, %{title: "first"})
      second = goal!(owner, org_id, %{title: "second"})

      assert {:ok, [a, b]} = Goals.list_goals(owner)
      assert [a.id, b.id] == [second.id, first.id]
    end
  end

  describe "update_goal/3" do
    test "the owner changes settings but never owner or org", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      other_org = org_id!()

      assert {:ok, updated} =
               Goals.update_goal(owner, goal.id, %{
                 title: "Ship v2",
                 status: "paused",
                 unit: "users",
                 target_value: 100,
                 rhythm: "weekly",
                 rhythm_weekday: 3,
                 owner_user_id: user!().id,
                 org_id: other_org
               })

      assert updated.title == "Ship v2"
      assert updated.status == "paused"
      assert updated.rhythm_weekday == 3
      assert updated.owner_user_id == owner.id
      assert updated.org_id == org_id
    end

    test "back to personal is refused while an audience exists", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      {:ok, _} = Goals.open_goal(owner, goal.id, {:team, org_id})

      assert Goals.update_goal(owner, goal.id, %{kind: "personal"}) == {:error, :has_audience}

      {:ok, closed} = Goals.close_goal(owner, goal.id, {:team, org_id})
      assert closed.kind == "shared"

      assert {:ok, %Goal{kind: "personal"}} =
               Goals.update_goal(owner, goal.id, %{kind: "personal"})
    end
  end

  describe "open_goal/3 and close_goal/3" do
    test "opening is idempotent and shares a personal goal in the same step",
         %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      reader = user!()

      assert {:ok, %Goal{kind: "shared"}} = Goals.open_goal(owner, goal.id, {:user, reader.id})
      assert {:ok, %Goal{kind: "shared"}} = Goals.open_goal(owner, goal.id, {:user, reader.id})
      assert grant_count(goal) == 1

      assert {:ok, [%Grant{audience_type: "user", user_id: user_id, granted_by_user_id: by}]} =
               Goals.list_audience(owner, goal.id)

      assert user_id == reader.id
      assert by == owner.id
    end

    test "a failed open leaves a personal goal personal with no grant",
         %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)

      assert Goals.open_goal(owner, goal.id, {:user, Ecto.UUID.generate()}) ==
               {:error, :audience_not_available}

      assert {:ok, %Goal{kind: "personal"}} = Goals.get_goal(owner, goal.id)
      assert grant_count(goal) == 0
    end

    test "unavailable audiences are refused", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      not_mine_org = org_id!()
      external_org = org_id!()
      join_org!(owner, external_org, external: true)
      not_my_space = space!(org_id)

      for audience <- [
            {:user, owner.id},
            {:user, Ecto.UUID.generate()},
            {:user, "nope"},
            {:team, not_mine_org},
            {:team, external_org},
            {:space, not_my_space.id},
            {:space, Ecto.UUID.generate()},
            {:everyone, org_id},
            :everyone
          ] do
        assert Goals.open_goal(owner, goal.id, audience) == {:error, :audience_not_available},
               "#{inspect(audience)} was opened"
      end

      assert grant_count(goal) == 0
    end

    test "closing an audience that was not open is a no-op", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      reader = user!()
      {:ok, _} = Goals.open_goal(owner, goal.id, {:user, reader.id})

      assert {:ok, %Goal{}} = Goals.close_goal(owner, goal.id, {:team, org_id})
      assert {:ok, %Goal{}} = Goals.close_goal(owner, goal.id, {:user, user!().id})
      assert {:ok, %Goal{}} = Goals.close_goal(owner, goal.id, {:user, "nope"})
      assert grant_count(goal) == 1
    end
  end

  describe "source guard" do
    @lib Path.expand("../../../lib", __DIR__)
    @forbidden [
      "Repo.get(",
      "Repo.get!(",
      "Repo.get_by(",
      "Repo.all(Goal",
      "Repo.all(Stop",
      "Repo.all(Entry",
      "Repo.all(Grant",
      "Repo.all(Reading",
      "Repo.all(WakeUp",
      "Repo.all(GoalClock",
      "Repo.all(Ask",
      "Repo.all(TaskLink",
      "Repo.all(BriefItem"
    ]

    defp hits(text), do: Enum.filter(@forbidden, &String.contains?(text, &1))

    test "the scan can hit (positive control)" do
      assert hits("goal = Repo.get(Goal, id)") == ["Repo.get("]

      for schema <- ~w(Goal Stop Entry Grant Reading WakeUp GoalClock Ask TaskLink BriefItem) do
        assert "Repo.all(#{schema}" in hits("Repo.all(#{schema})")
      end
    end

    test "apps/goals/lib has no unscoped read" do
      files = Path.wildcard(Path.join(@lib, "**/*.{ex,exs}"))
      assert Enum.any?(files, &String.ends_with?(&1, "platform/goals.ex")), "no lib files scanned"

      assert Enum.any?(files, &String.ends_with?(&1, "platform/goals/retro_changes.ex")),
             "retro reads must be scanned"

      assert Enum.any?(files, &String.ends_with?(&1, "platform/goals/owner_pace.ex")),
             "pacing reads must be scanned"

      found =
        for file <- files, hit <- hits(File.read!(file)), do: {Path.relative_to(file, @lib), hit}

      assert found == []
    end

    defp actorless_goal_binding?(text) do
      Regex.match?(~r/\b(?:from|join:?)\s*\(?\s*\w+\s+in\s+(?:Platform\.Goals\.)?Goal\b/, text)
    end

    test "goal binding scan catches a planted query" do
      assert actorless_goal_binding?("from g in Goal, select: g.id")
      assert actorless_goal_binding?("join: g in Platform.Goals.Goal, on: g.id == c.goal_id")
      assert actorless_goal_binding?("join g in Platform.Goals.Goal, on: g.id == c.goal_id")
      refute actorless_goal_binding?("from g in visible_goals(actor), select: g")
    end

    test "only the audited context, visibility and identifier clock query bind goals" do
      allowed = ~w(platform/goals.ex platform/goals/visibility.ex platform/goals/clock.ex)

      found =
        for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
            relative = Path.relative_to(file, @lib),
            relative not in allowed,
            actorless_goal_binding?(File.read!(file)),
            do: relative

      assert found == []
    end

    test "the scan reads the Goals 4/8 page reads too" do
      source = File.read!(Path.join(@lib, "platform/goals.ex"))

      for name <- ~w(describe_goals describe_goal list_audience_options),
          do: assert(source =~ "def #{name}(", "#{name} is not in the scanned file")
    end

    test "Platform.Goals has no arity-0 function but enabled?/0" do
      zero = for {name, 0} <- Platform.Goals.__info__(:functions), do: name
      assert zero == [:enabled?]
    end
  end
end

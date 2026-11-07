defmodule Platform.Chat.SpaceGoalsTest do
  @moduledoc """
  `chat_spaces.goals` (task 01a1b6de stage 1): 0 to 3 goals in the owner's
  words, `goal` mirrored to `goals[0]` in the same write, and the setup
  write path `Platform.Agents.Lead.save_setup_goals/1`.

  Mutants these name:

    * raise the cap in `Space.validate_goals/1` → "a 4th goal is refused";
    * drop the blank filter in `Space.normalize_goals/1` → "blanks are dropped";
    * drop the `goals` branch of `Space.mirror_goal/1` → "goal mirrors goals[0]";
    * drop the `goal` branch of `Space.mirror_goal/1` → "the chat goal editor
      replaces goals[0]";
    * write `leader_agent_id` unconditionally in `Sidebar.save_goals/3` →
      "an existing leader is kept".
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Lead
  alias Platform.Chat
  alias Platform.Chat.{Sidebar, Space}
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat
  alias Platform.Roles

  defp insert_agent(label) do
    Repo.insert!(%Platform.Agents.Agent{
      name: "Agent #{label}",
      slug: "lead-#{label}-#{System.unique_integer([:positive])}",
      status: "active"
    })
  end

  defp insert_space(attrs \\ %{}) do
    slug = "goals-#{System.unique_integer([:positive])}"

    %Space{}
    |> Space.changeset(Map.merge(%{kind: "channel", name: "Team", slug: slug}, Map.new(attrs)))
    |> Repo.insert!()
  end

  describe "Sidebar.save_goals/3" do
    test "saves up to 3 goals, trimmed, and goal mirrors goals[0]" do
      space = insert_space()

      assert {:ok, saved} =
               Sidebar.save_goals(space, [
                 "  Launch the new site by December ",
                 "Answer email within a day",
                 "Hire two people"
               ])

      assert saved.goals == [
               "Launch the new site by December",
               "Answer email within a day",
               "Hire two people"
             ]

      assert saved.goal == "Launch the new site by December"

      fresh = Repo.get!(Space, space.id)
      assert fresh.goals == saved.goals
      assert fresh.goal == hd(fresh.goals)
    end

    test "a 4th goal is refused and nothing is written" do
      space = insert_space()
      {:ok, _} = Sidebar.save_goals(space, ["one"])

      assert {:error, %Ecto.Changeset{} = cs} = Sidebar.save_goals(space, ["a", "b", "c", "d"])
      assert {"can have at most %{count} goals", opts} = cs.errors[:goals]
      assert opts[:count] == 3

      fresh = Repo.get!(Space, space.id)
      assert fresh.goals == ["one"]
      assert fresh.goal == "one"
    end

    test "blanks are dropped before the cap is counted" do
      space = insert_space()

      assert {:ok, saved} = Sidebar.save_goals(space, ["", "first", "   ", "second", "third"])
      assert saved.goals == ["first", "second", "third"]
      assert saved.goal == "first"
    end

    test "a goal over 500 characters is refused" do
      space = insert_space()
      assert {:error, cs} = Sidebar.save_goals(space, [String.duplicate("x", 501)])
      assert {"each goal can be at most %{count} characters", _} = cs.errors[:goals]
      assert {:ok, _} = Sidebar.save_goals(space, [String.duplicate("x", 500)])
    end

    test "an empty list clears goal too" do
      space = insert_space()
      {:ok, _} = Sidebar.save_goals(space, ["one", "two"])
      assert {:ok, saved} = Sidebar.save_goals(space, [])
      assert saved.goals == []
      assert saved.goal == nil
    end

    test "metadata is not touched (the heartbeat baseline survives)" do
      space = insert_space(%{metadata: %{"goal_heartbeat" => %{"baseline" => 7}}})
      {:ok, saved} = Sidebar.save_goals(space, ["one"])
      assert saved.metadata == %{"goal_heartbeat" => %{"baseline" => 7}}
    end

    test "leader_agent_id is set only when the space has none" do
      first = insert_agent("first")
      second = insert_agent("second")

      space = insert_space()
      {:ok, saved} = Sidebar.save_goals(space, ["one"], leader_agent_id: first.id)
      assert saved.leader_agent_id == first.id

      # an existing leader is kept
      {:ok, again} = Sidebar.save_goals(saved, ["two"], leader_agent_id: second.id)
      assert again.leader_agent_id == first.id
    end
  end

  describe "the chat goal editor (save_goal/3) keeps goals in step" do
    test "the chat goal editor replaces goals[0] and keeps the rest" do
      space = insert_space()
      {:ok, _} = Sidebar.save_goals(space, ["one", "two"])

      assert {:ok, saved} = Sidebar.save_goal(space, "uno", nil)
      assert saved.goal == "uno"
      assert saved.goals == ["uno", "two"]
    end

    test "a first goal from the editor becomes goals[0]" do
      space = insert_space()
      assert {:ok, saved} = Sidebar.save_goal(space, "Close the backlog", nil)
      assert saved.goals == ["Close the backlog"]
    end

    test "a blank goal from the editor clears goals" do
      space = insert_space()
      {:ok, _} = Sidebar.save_goals(space, ["one", "two"])
      assert {:ok, saved} = Sidebar.save_goal(space, "", nil)
      assert saved.goals == []
    end

    test "agents_space/0 finds a space whose goals were saved" do
      space = insert_space()
      {:ok, _} = Sidebar.save_goals(space, ["Ship it"])
      assert %Space{id: id, goal: "Ship it"} = AgentsGoalHeartbeat.agents_space()
      assert id == space.id
    end
  end

  describe "Lead.save_setup_goals/1" do
    setup do
      :ok = Roles.unassign_role("agents_leader")
      :ok
    end

    test "all blank is a skip and writes nothing" do
      assert {:ok, :skipped} = Lead.save_setup_goals(["", "  "])
      assert AgentsGoalHeartbeat.agents_space() == nil
    end

    test "with no agents space, creates the team channel led by the lead agent" do
      lead = insert_agent("lead")
      {:ok, _} = Roles.assign_role("agents_leader", lead.id)

      assert {:ok, %Space{} = space} =
               Lead.save_setup_goals(["Launch by December", "", "Answer email"])

      assert space.slug == "general"
      assert space.kind == "channel"
      assert space.org_id == Platform.Tenancy.get_root_org().id
      assert space.leader_agent_id == lead.id
      assert space.goals == ["Launch by December", "Answer email"]
      assert space.goal == "Launch by December"
      assert AgentsGoalHeartbeat.agents_space().id == space.id
      assert Lead.goals() == ["Launch by December", "Answer email"]
    end

    test "writes onto the existing agents space and keeps its leader" do
      leader = insert_agent("existing")
      lead = insert_agent("lead")
      {:ok, _} = Roles.assign_role("agents_leader", lead.id)
      space = insert_space(%{goal: "Old goal", leader_agent_id: leader.id})

      assert {:ok, saved} = Lead.save_setup_goals(["New goal"])
      assert saved.id == space.id
      assert saved.goals == ["New goal"]
      assert saved.leader_agent_id == leader.id
    end

    test "a 4th goal is refused whole" do
      assert {:error, %Ecto.Changeset{}} = Lead.save_setup_goals(["a", "b", "c", "d"])
      assert AgentsGoalHeartbeat.agents_space() == nil
    end
  end

  describe "Lead.name/0, the one config point" do
    setup do
      previous = Application.get_env(:platform, Lead)
      :ok = Roles.unassign_role("agents_leader")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:platform, Lead, previous),
          else: Application.delete_env(:platform, Lead)
      end)
    end

    test "defaults to the lead agent's name, then Burrow" do
      Application.delete_env(:platform, Lead)
      assert Lead.name() == Platform.Agents.Burrow.name()

      lead = insert_agent("named")
      {:ok, _} = Roles.assign_role("agents_leader", lead.id)
      assert Lead.name() == lead.name
    end

    test "config wins" do
      Application.put_env(:platform, Lead, name: "{lead}")
      assert Lead.name() == "{lead}"
    end
  end

  test "Chat.update_space/2 keeps the mirror on any write that names goals" do
    space = insert_space()
    {:ok, saved} = Chat.update_space(space, %{goals: ["x", "y"]})
    assert saved.goal == "x"
  end
end

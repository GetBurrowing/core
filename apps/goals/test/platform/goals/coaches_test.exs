defmodule Platform.Goals.CoachesTest do
  @moduledoc """
  Task 01a1eab7 stage 1: the eligible-coach rule. One predicate, read by
  `list_eligible/1`, `eligible?/2` and `fetch_eligible/2`.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.Coaches

  setup do
    enable_goals!()
    org = org_id!()
    person = member!(org)
    %{org: org, person: person}
  end

  defp external_agent!(owner, attrs \\ %{}) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: owner.id,
        runtime_id: "goal-coach-#{unique()}",
        display_name: "Goals coach test",
        status: "active"
      })

    agent!()
    |> Ecto.Changeset.change(
      Map.merge(%{runtime_type: "external", runtime_id: runtime.id}, attrs)
    )
    |> Repo.update!()
  end

  defp coach!(owner, attrs \\ %{}), do: owner |> external_agent!(attrs) |> grant_goals_tools!()

  defp lead!(agent) do
    {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), agent.id)
    agent
  end

  # Only the agents a test made: the sandbox may hold others.
  defp ids_among(list, agents) do
    mine = MapSet.new(agents, & &1.id)
    list |> Enum.map(& &1.id) |> Enum.filter(&MapSet.member?(mine, &1))
  end

  describe "list_eligible/1" do
    test "lists only active, chat-accepting agents whose runtime holds the goals bundle", c do
      b = coach!(c.person, %{name: "Bravo coach"})
      a = coach!(c.person, %{name: "Alpha coach"})

      no_bundle =
        c.person |> external_agent!(%{name: "Charlie"}) |> grant_goals_tools!(["messaging"])

      no_profile = external_agent!(c.person, %{name: "Delta"})
      inactive = coach!(c.person, %{name: "Echo", status: "paused"})
      no_chat = coach!(c.person, %{name: "Foxtrot", accepts_chat: false})
      built_in = agent!()

      everyone = [a, b, no_bundle, no_profile, inactive, no_chat, built_in]
      list = Coaches.list_eligible(c.person)

      assert ids_among(list, everyone) == [a.id, b.id]

      for agent <- everyone do
        assert Coaches.eligible?(c.person, agent) == agent.id in [a.id, b.id],
               "eligible?/2 disagrees with list_eligible/1 for #{agent.name}"
      end
    end

    test "an owner without goals.use caps the bundle away: effective tools decide", c do
      owner = member!(c.org)
      capped = coach!(owner)
      assert capped.id in Enum.map(Coaches.list_eligible(c.person), & &1.id)

      revoke_goals_use!(owner)
      refute capped.id in Enum.map(Coaches.list_eligible(c.person), & &1.id)
      refute Coaches.eligible?(c.person, capped.id)
    end

    test "an external user without a DM allowlist entry for the agent's org gets no agent", c do
      a = coach!(c.person)
      external = external_member!(c.org)
      assert Platform.Tenancy.external_user?(external)

      assert ids_among(Coaches.list_eligible(external), [a]) == []
      refute Coaches.eligible?(external, a)

      # Core's gate, not a second rule here.
      refute Chat.external_dm_permitted?(external.id, "agent", a.id)
    end

    test "each entry carries id, name, palette slot, model family and first role", c do
      a = coach!(c.person, %{name: "Alpha", color: "teal", model: "claude-opus-4"})

      b = coach!(c.person, %{name: "Bravo", model_config: %{"primary" => "openai/gpt-5"}})

      plain = coach!(c.person, %{name: "Charlie"})
      lead!(a)

      by_id = c.person |> Coaches.list_eligible() |> Map.new(&{&1.id, &1})
      leader_name = Platform.Roles.get_role(Chat.Sidebar.agents_leader_role()).name

      assert by_id[a.id] == %{
               id: a.id,
               name: "Alpha",
               slot: Platform.Agents.ColorPalette.slot_for("teal"),
               avatar_url: nil,
               model_label: "Opus",
               role_label: leader_name
             }

      assert by_id[b.id].model_label == "GPT"
      assert by_id[b.id].role_label == nil
      assert by_id[plain.id].model_label == nil
      assert by_id[plain.id].slot == Platform.Agents.ColorPalette.slot_for(nil)
    end

    test "a non-user actor gets nothing" do
      assert Coaches.list_eligible(agent!()) == []
      assert Coaches.list_eligible(nil) == []
    end
  end

  describe "eligible?/2 and fetch_eligible/2" do
    test "unknown, malformed and nil ids answer the one refusal", c do
      for id <- [Ecto.UUID.generate(), "not-a-uuid", nil, 42] do
        refute Coaches.eligible?(c.person, id)
        assert Coaches.fetch_eligible(c.person, id) == {:error, :lead_missing_goals_tools}
      end
    end

    test "a passed struct is re-read, never trusted", c do
      no_bundle = external_agent!(c.person)
      forged = %{no_bundle | status: "active", accepts_chat: true}
      refute Coaches.eligible?(c.person, forged)

      a = coach!(c.person)
      assert {:ok, %Platform.Agents.Agent{id: id}} = Coaches.fetch_eligible(c.person, a)
      assert id == a.id
      assert Coaches.eligible?(c.person, String.upcase(a.id))
    end
  end

  describe "default_id/2 and Goals.list_coaches/1" do
    test "the leader when eligible, else the first eligible, else nil", c do
      a = coach!(c.person, %{name: "Alpha"})
      b = c.person |> coach!(%{name: "Bravo"}) |> lead!()

      assert {:ok, %{coaches: coaches, default_id: default}} = Goals.list_coaches(c.person)
      assert default == b.id
      assert ids_among(coaches, [a, b]) == [a.id, b.id]

      # The leader loses the bundle: the first eligible agent is the default.
      grant_goals_tools!(b, ["messaging"])
      assert {:ok, %{coaches: coaches, default_id: default}} = Goals.list_coaches(c.person)
      refute b.id in Enum.map(coaches, & &1.id)
      assert default == hd(coaches).id

      assert Coaches.default_id(c.person, []) == nil
    end

    test "list_coaches is behind the switch and goals.use", c do
      assert {:ok, _} = Goals.list_coaches(c.person)
      assert Goals.list_coaches(user_without_goals_use!()) == {:error, :forbidden}
      Application.put_env(:goals, :enabled, false)
      assert Goals.list_coaches(c.person) == {:error, :goals_disabled}
    end
  end

  describe "Goals.update_goal/3 coach changes" do
    setup c do
      a = coach!(c.person, %{name: "Alpha"})
      goal = goal!(c.person, c.org, %{coach_agent_id: a.id})
      %{a: a, goal: goal}
    end

    defp coach_of(goal),
      do: Repo.one!(from(g in Goals.Goal, where: g.id == ^goal.id)).coach_agent_id

    test "the owner may change to an eligible coach, and back to nil", c do
      b = coach!(c.person, %{name: "Bravo"})

      assert {:ok, %{coach_agent_id: id}} =
               Goals.update_goal(c.person, c.goal.id, %{coach_agent_id: b.id})

      assert id == b.id

      # String keys reach the same check.
      assert {:ok, _} = Goals.update_goal(c.person, c.goal.id, %{"coach_agent_id" => c.a.id})
      assert coach_of(c.goal) == c.a.id

      assert {:ok, %{coach_agent_id: nil}} =
               Goals.update_goal(c.person, c.goal.id, %{coach_agent_id: nil})
    end

    test "an ineligible, unknown or malformed coach is refused and the goal is unchanged", c do
      no_bundle = c.person |> external_agent!() |> grant_goals_tools!(["messaging"])
      built_in = agent!()

      for id <- [no_bundle.id, built_in.id, Ecto.UUID.generate(), "not-a-uuid"],
          attrs <- [%{coach_agent_id: id}, %{"coach_agent_id" => id}] do
        assert Goals.update_goal(c.person, c.goal.id, Map.put(attrs, :title, "Changed")) ==
                 {:error, :lead_missing_goals_tools},
               inspect(attrs)

        stored = Repo.one!(from(g in Goals.Goal, where: g.id == ^c.goal.id))
        assert stored.coach_agent_id == c.a.id
        assert stored.title == c.goal.title
      end
    end

    test "re-sending the current coach is not a change", c do
      grant_goals_tools!(c.a, ["messaging"])
      refute Coaches.eligible?(c.person, c.a)

      assert {:ok, %{title: "Renamed"}} =
               Goals.update_goal(c.person, c.goal.id, %{coach_agent_id: c.a.id, title: "Renamed"})
    end

    test "the coach's coach_agent_id is dropped, not checked (owner only, unchanged rule)", c do
      b = coach!(c.person, %{name: "Bravo"})

      for id <- [b.id, Ecto.UUID.generate()] do
        assert {:ok, %{title: "By coach"}} =
                 Goals.update_goal(c.a, c.goal.id, %{coach_agent_id: id, title: "By coach"})

        assert coach_of(c.goal) == c.a.id
      end
    end
  end

  describe "Goals.hand_off_coach/3 (the hand-off's write, unchecked by design)" do
    test "sets a coachless goal's coach without the eligible-coach check", c do
      goal = goal!(c.person, c.org)
      built_in = agent!()
      refute Coaches.eligible?(c.person, built_in)

      assert {:ok, %{coach_agent_id: id}} = Goals.hand_off_coach(c.person, goal.id, built_in.id)
      assert id == built_in.id
    end

    test "a goal that already has a coach is :forbidden and keeps its coach", c do
      a = coach!(c.person)
      goal = goal!(c.person, c.org, %{coach_agent_id: a.id})

      assert Goals.hand_off_coach(c.person, goal.id, agent!().id) == {:error, :forbidden}
      assert Repo.one!(from(g in Goals.Goal, where: g.id == ^goal.id)).coach_agent_id == a.id
    end
  end
end

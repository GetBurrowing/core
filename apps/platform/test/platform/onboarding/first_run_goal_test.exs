defmodule Platform.Onboarding.FirstRunGoalTest do
  @moduledoc "The first-run goal box backend, task 01a19554-fd07 stage 1."
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.AgentHost.State
  alias Platform.Agents.NativeAgents
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Onboarding.FirstRunGoal
  alias Platform.Repo

  defp user!(label \\ "member") do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "frg-#{label}-#{n}@example.com",
      name: "FRG #{label} #{n}",
      oidc_sub: "oidc-frg-#{label}-#{n}"
    })
  end

  defp burrow_agent! do
    {:ok, agent, _runtime} =
      NativeAgents.create(user!("owner").id, %{name: "Burrow", harness: "claude_code"})

    assert agent.slug == "burrow"

    on_exit(fn ->
      if :ets.whereis(State.table()) != :undefined, do: :ets.delete(State.table(), agent.id)
    end)

    agent
  end

  defp running_burrow! do
    agent = burrow_agent!()
    State.init_table()
    State.put(agent.id, :running)
    agent
  end

  defp pref(user), do: Accounts.get_user_preferences(user.id)["first_run_goal"]

  defp messages_in(space_id),
    do: Repo.all(from(m in Message, where: m.space_id == ^space_id))

  defp goal_messages(user) do
    Repo.all(
      from(m in Message,
        join: p in Participant,
        on: p.id == m.participant_id,
        where:
          p.participant_type == "user" and p.participant_id == ^user.id and
            fragment("?->>'source' = 'first_run_goal'", m.metadata)
      )
    )
  end

  test "example_goals/0 is the three chips" do
    assert length(FirstRunGoal.example_goals()) == 3
  end

  describe "pending?/1" do
    test "a fresh member is pending" do
      assert FirstRunGoal.pending?(user!())
    end

    test "a member who skipped is not pending" do
      user = user!()
      assert :ok = FirstRunGoal.skip(user)
      assert :ok = FirstRunGoal.skip(user)
      refute FirstRunGoal.pending?(user)
      assert pref(user) == "skipped"
    end

    test "any stored value, even an unknown one, means not pending" do
      user = user!()
      {:ok, _} = Accounts.update_user_preference(user.id, "first_run_goal", "something-new")
      refute FirstRunGoal.pending?(user)
    end

    test "an external user is never pending" do
      org = Platform.Tenancy.get_org_by_slug!("globex")
      ext = Platform.ExternalUserFixtures.external_user!(org)
      refute FirstRunGoal.pending?(ext)
    end

    test "nil is never pending" do
      refute FirstRunGoal.pending?(nil)
    end
  end

  describe "burrow/0" do
    test "no Burrow agent is :no_agent" do
      assert {:error, :no_agent} = FirstRunGoal.burrow()
    end

    test "a Burrow the host does not report running is :no_agent" do
      agent = burrow_agent!()
      assert {:error, :no_agent} = FirstRunGoal.burrow()
      State.init_table()
      State.put(agent.id, :stopped)
      assert {:error, :no_agent} = FirstRunGoal.burrow()
      State.put(agent.id, :running)
      assert {:ok, %{id: id}} = FirstRunGoal.burrow()
      assert id == agent.id
    end
  end

  describe "submit/2" do
    test "submit posts the goal into a DM with Burrow and marks submitted" do
      agent = running_burrow!()
      user = user!()

      assert {:ok, %Space{} = space, %Message{} = msg} =
               FirstRunGoal.submit(user, "  Plan this week's work \n")

      assert space.kind == "dm"

      assert Repo.exists?(
               from(p in Participant,
                 where:
                   p.space_id == ^space.id and p.participant_type == "agent" and
                     p.participant_id == ^agent.id
               )
             )

      assert msg.space_id == space.id
      assert msg.content == "Plan this week's work"
      assert msg.metadata["source"] == "first_run_goal"

      author = Repo.get!(Participant, msg.participant_id)
      assert {author.participant_type, author.participant_id} == {"user", user.id}

      assert pref(user) == "submitted"
      refute FirstRunGoal.pending?(user)
    end

    test "a second submit reuses the same DM" do
      agent = running_burrow!()
      user = user!()
      {:ok, existing} = Chat.find_or_create_dm(user.id, "agent", agent.id)

      assert {:ok, space, _msg} = FirstRunGoal.submit(user, "Start a project with my team")
      assert space.id == existing.id

      # A second submit (double click) posts nothing and makes no new DM.
      assert {:error, :not_pending} = FirstRunGoal.submit(user, "Start a project with my team")
      assert length(messages_in(space.id)) == 1
      assert {:ok, again} = Chat.find_or_create_dm(user.id, "agent", agent.id)
      assert again.id == space.id
    end

    test "two concurrent submits post the goal once" do
      running_burrow!()
      user = user!()

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn -> FirstRunGoal.submit(user, "Plan this week's work") end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))

      assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :not_pending})) == 1
      assert length(goal_messages(user)) == 1
      assert pref(user) == "submitted"
    end

    test "submit with no Burrow returns :no_agent and leaves the member pending" do
      user = user!()
      assert {:error, :no_agent} = FirstRunGoal.submit(user, "Plan this week's work")
      assert FirstRunGoal.pending?(user)
      assert goal_messages(user) == []
    end

    test "submit with a Burrow that is not running returns :no_agent" do
      agent = burrow_agent!()
      State.init_table()
      State.put(agent.id, :crashed)
      user = user!()

      assert {:error, :no_agent} = FirstRunGoal.submit(user, "Plan this week's work")
      assert FirstRunGoal.pending?(user)
      assert goal_messages(user) == []
    end

    test "blank submit writes nothing" do
      running_burrow!()
      user = user!()
      before = Repo.get!(User, user.id)

      assert {:error, :blank} = FirstRunGoal.submit(user, "   \n\t ")
      assert {:error, :blank} = FirstRunGoal.submit(user, nil)

      assert Repo.get!(User, user.id).preferences == before.preferences
      assert FirstRunGoal.pending?(user)
      assert goal_messages(user) == []
    end

    test "a failed post leaves the member pending" do
      running_burrow!()
      user = user!()
      failing = fn _attrs -> {:error, :space_archived} end

      assert {:error, :space_archived} =
               FirstRunGoal.submit(user, "Plan this week's work", post: failing)

      assert FirstRunGoal.pending?(user)
      refute Map.has_key?(Accounts.get_user_preferences(user.id), "first_run_goal")

      # And the member can submit again for real.
      assert {:ok, _space, _msg} = FirstRunGoal.submit(user, "Plan this week's work")
      assert pref(user) == "submitted"
    end

    test "a post that raises leaves the member pending" do
      running_burrow!()
      user = user!()

      assert_raise RuntimeError, fn ->
        FirstRunGoal.submit(user, "Plan this week's work", post: fn _ -> raise "boom" end)
      end

      assert FirstRunGoal.pending?(user)
    end

    test "an external user cannot submit" do
      running_burrow!()
      org = Platform.Tenancy.get_org_by_slug!("globex")
      ext = Platform.ExternalUserFixtures.external_user!(org)

      assert {:error, :not_pending} = FirstRunGoal.submit(ext, "Plan this week's work")
      assert goal_messages(ext) == []
    end
  end

  describe "users.preferences writes touch only their own key" do
    test "theme then first_run_goal: both keys survive" do
      user = user!()
      {:ok, _} = Accounts.update_user_preference(user.id, "theme", %{"preset" => "sage"})
      :ok = FirstRunGoal.skip(user)

      prefs = Accounts.get_user_preferences(user.id)
      assert prefs["theme"] == %{"preset" => "sage"}
      assert prefs["first_run_goal"] == "skipped"
    end

    test "first_run_goal then theme: both keys survive" do
      user = user!()
      :ok = FirstRunGoal.skip(user)
      {:ok, _} = Accounts.update_user_preference(user.id, "theme", %{"preset" => "sage"})

      prefs = Accounts.get_user_preferences(user.id)
      assert prefs["theme"] == %{"preset" => "sage"}
      assert prefs["first_run_goal"] == "skipped"
    end

    test "a write from a stale user struct does not clobber a newer theme" do
      running_burrow!()
      stale = user!()
      {:ok, _} = Accounts.update_user_preference(stale.id, "theme", %{"preset" => "sage"})

      assert {:ok, _, _} = FirstRunGoal.submit(stale, "Plan this week's work")

      prefs = Accounts.get_user_preferences(stale.id)
      assert prefs["theme"] == %{"preset" => "sage"}
      assert prefs["first_run_goal"] == "submitted"
    end
  end
end

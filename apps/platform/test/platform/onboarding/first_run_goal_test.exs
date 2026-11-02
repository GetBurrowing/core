defmodule Platform.Onboarding.FirstRunGoalTest do
  @moduledoc """
  The first-run goal box backend, task 01a19554-fd07 stage 1. Since task
  01a19948-d342 stage 1 a submitted goal opens a visible channel with Burrow,
  never a DM.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures, only: [acme_org_id: 0]

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.AgentHost.State
  alias Platform.Agents.NativeAgents
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Chat.ExternalScope
  alias Platform.Onboarding.FirstRunGoal
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  doctest FirstRunGoal

  defp user!(label \\ "member") do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "frg-#{label}-#{n}@example.com",
      name: "FRG #{label} #{n}",
      oidc_sub: "oidc-frg-#{label}-#{n}"
    })
  end

  # An internal member of `org_id`.
  defp member_of!(org_id, label \\ "member") do
    user = user!(label)

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    user
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

  # Every channel a first-run submit by `user` opened.
  defp goal_channels(user) do
    Repo.all(
      from(s in Space,
        where:
          s.created_by == ^user.id and
            fragment("?->>'origin' = 'first_run_goal'", s.metadata)
      )
    )
  end

  # Every DM `user` holds a participant row in.
  defp dms_of(user) do
    Repo.all(
      from(s in Space,
        join: p in Participant,
        on: p.space_id == s.id,
        where: s.kind == "dm" and p.participant_type == "user" and p.participant_id == ^user.id
      )
    )
  end

  defp participant(space_id, type, id) do
    Repo.one(
      from(p in Participant,
        where: p.space_id == ^space_id and p.participant_type == ^type and p.participant_id == ^id
      )
    )
  end

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

    test "a malformed user id is not pending and cannot submit or skip, without raising" do
      refute FirstRunGoal.pending?(%{id: "not-a-uuid"})
      assert {:error, :not_pending} = FirstRunGoal.submit(%{id: "not-a-uuid"}, "Plan")
      assert {:error, :not_found} = FirstRunGoal.skip(%{id: "not-a-uuid"})
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
    test "submit opens a visible channel with Burrow, posts the goal and marks submitted" do
      agent = running_burrow!()
      user = member_of!(acme_org_id())

      assert {:ok, %Space{} = space, %Message{} = msg} =
               FirstRunGoal.submit(user, "  Plan this week's work \n")

      assert space.kind == "channel"
      refute space.is_direct
      assert space.org_id == acme_org_id()
      assert space.created_by == user.id
      assert space.metadata["origin"] == "first_run_goal"
      assert space.name == FirstRunGoal.placeholder_name("Plan this week's work")
      assert space.name == "Plan this week's work"
      assert space.slug =~ ~r/\Aplan-this-weeks-work-[0-9a-f]{6}\z/

      stored = Repo.get!(Space, space.id)
      assert stored.agent_attention_policy == "directed"
      assert space.agent_attention_policy == "directed"

      # The member is the channel's admin, Burrow its principal agent.
      assert %Participant{role: "admin"} = participant(space.id, "user", user.id)
      assert %Participant{role: "principal"} = participant(space.id, "agent", agent.id)

      # The goal is the channel's first message.
      assert [first] = messages_in(space.id)
      assert first.id == msg.id
      assert msg.space_id == space.id
      assert msg.content == "Plan this week's work"
      assert msg.metadata["source"] == "first_run_goal"

      author = Repo.get!(Participant, msg.participant_id)
      assert {author.participant_type, author.participant_id} == {"user", user.id}

      assert pref(user) == "submitted"
      refute FirstRunGoal.pending?(user)
    end

    test "a member with no internal org gets a channel in the root org" do
      running_burrow!()
      user = user!()

      assert {:ok, space, _msg} = FirstRunGoal.submit(user, "Plan this week's work")
      assert space.kind == "channel"
      root = Platform.Tenancy.get_root_org()
      assert space.org_id == (root && root.id)
    end

    test "a second submit returns :not_pending and creates no second channel" do
      running_burrow!()
      user = user!()

      assert {:ok, space, _msg} = FirstRunGoal.submit(user, "Start a project with my team")

      # A second submit (double click) posts nothing and opens no channel.
      assert {:error, :not_pending} = FirstRunGoal.submit(user, "Start a project with my team")
      assert length(messages_in(space.id)) == 1
      assert [only] = goal_channels(user)
      assert only.id == space.id
    end

    test "submit never creates a DM" do
      running_burrow!()
      user = member_of!(acme_org_id())

      assert {:ok, space, _msg} = FirstRunGoal.submit(user, "Plan this week's work")
      refute space.kind == "dm"
      refute space.is_direct
      assert dms_of(user) == []
    end

    test "the channel is visible to another member of the org, with no restriction" do
      running_burrow!()
      org_id = acme_org_id()
      owner = member_of!(org_id, "owner")
      other = member_of!(org_id, "other")

      assert {:ok, space, _msg} = FirstRunGoal.submit(owner, "Plan this week's work")

      assert participant(space.id, "user", other.id) == nil

      listed = Chat.list_spaces(kind: "channel", scope: ExternalScope.for_user(other.id))
      assert space.id in Enum.map(listed, & &1.id)

      rail = PlatformWeb.ChatLive.ReadScope.channels(ExternalScope.for_user(other.id))
      assert space.id in Enum.map(rail, & &1.id)

      assert Platform.Access.Restrictions.restricted_role_keys(space.id) == []
    end

    test "two members submitting the same chip goal both get a channel, with different slugs" do
      running_burrow!()
      org_id = acme_org_id()
      a = member_of!(org_id, "a")
      b = member_of!(org_id, "b")

      assert {:ok, space_a, _} = FirstRunGoal.submit(a, "Plan this week's work")
      assert {:ok, space_b, _} = FirstRunGoal.submit(b, "Plan this week's work")

      assert space_a.id != space_b.id
      assert space_a.name == space_b.name
      assert space_a.slug != space_b.slug
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
      assert length(goal_channels(user)) == 1
      assert pref(user) == "submitted"
    end

    test "submit with no Burrow returns :no_agent and leaves the member pending" do
      user = user!()
      assert {:error, :no_agent} = FirstRunGoal.submit(user, "Plan this week's work")
      assert FirstRunGoal.pending?(user)
      assert goal_messages(user) == []
      assert goal_channels(user) == []
    end

    test "submit with a Burrow that is not running returns :no_agent" do
      agent = burrow_agent!()
      State.init_table()
      State.put(agent.id, :crashed)
      user = user!()

      assert {:error, :no_agent} = FirstRunGoal.submit(user, "Plan this week's work")
      assert FirstRunGoal.pending?(user)
      assert goal_messages(user) == []
      assert goal_channels(user) == []
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
      assert goal_channels(user) == []
    end

    test "a failed post leaves the member pending and leaves no channel" do
      running_burrow!()
      user = user!()
      failing = fn _attrs -> {:error, :space_archived} end

      assert {:error, :space_archived} =
               FirstRunGoal.submit(user, "Plan this week's work", post: failing)

      assert FirstRunGoal.pending?(user)
      refute Map.has_key?(Accounts.get_user_preferences(user.id), "first_run_goal")
      assert goal_channels(user) == []

      # And the member can submit again for real, which opens one channel.
      assert {:ok, space, _msg} = FirstRunGoal.submit(user, "Plan this week's work")
      assert pref(user) == "submitted"
      assert [only] = goal_channels(user)
      assert only.id == space.id
    end

    test "a post that raises leaves the member pending and leaves no channel" do
      running_burrow!()
      user = user!()

      assert_raise RuntimeError, fn ->
        FirstRunGoal.submit(user, "Plan this week's work", post: fn _ -> raise "boom" end)
      end

      assert FirstRunGoal.pending?(user)
      assert goal_channels(user) == []
    end

    test "an external user cannot submit" do
      running_burrow!()
      org = Platform.Tenancy.get_org_by_slug!("globex")
      ext = Platform.ExternalUserFixtures.external_user!(org)

      assert {:error, :not_pending} = FirstRunGoal.submit(ext, "Plan this week's work")
      assert goal_messages(ext) == []
      assert goal_channels(ext) == []
    end
  end

  describe "placeholder_name/1" do
    test "a short goal is kept, first letter upcased, whitespace collapsed" do
      assert FirstRunGoal.placeholder_name("Plan this week's work") == "Plan this week's work"

      assert FirstRunGoal.placeholder_name("  plan   this\tweek's work ") ==
               "Plan this week's work"
    end

    test "a long goal is cut at a word boundary to at most 40 characters" do
      goal = "Help me organise the quarterly planning offsite for the whole design team"
      name = FirstRunGoal.placeholder_name(goal)

      assert name == "Help me organise the quarterly planning"
      assert String.length(name) <= 40
    end

    test "a single word longer than 40 characters is cut at 40" do
      assert FirstRunGoal.placeholder_name(String.duplicate("a", 60)) ==
               "A" <> String.duplicate("a", 39)
    end

    test "only the first line of a multi-line goal is used" do
      assert FirstRunGoal.placeholder_name("fix the onboarding emails\nthey bounce for gmail") ==
               "Fix the onboarding emails"

      assert FirstRunGoal.placeholder_name("\n\n  draft the launch post\r\nwith the team") ==
               "Draft the launch post"
    end

    test "trailing punctuation and emoji are dropped, closing brackets and C++ kept" do
      assert FirstRunGoal.placeholder_name("Ship the beta!!!") == "Ship the beta"

      assert FirstRunGoal.placeholder_name("Can you plan the launch?") ==
               "Can you plan the launch"

      assert FirstRunGoal.placeholder_name("Plan the launch \u{1F680}") == "Plan the launch"

      assert FirstRunGoal.placeholder_name("Fix the login bug (urgent)") ==
               "Fix the login bug (urgent)"

      assert FirstRunGoal.placeholder_name("Learn C++") == "Learn C++"
    end

    test "an emoji-only, punctuation-only or empty goal is \"New goal\"" do
      assert FirstRunGoal.placeholder_name("\u{1F389}\u{1F389}") == "New goal"
      assert FirstRunGoal.placeholder_name("\u{2764}\u{FE0F}") == "New goal"
      assert FirstRunGoal.placeholder_name("?!...") == "New goal"
      assert FirstRunGoal.placeholder_name("   ") == "New goal"
      assert FirstRunGoal.placeholder_name(nil) == "New goal"
    end

    test "an emoji-only goal still opens a channel named New goal" do
      running_burrow!()
      user = user!()

      assert {:ok, space, _msg} = FirstRunGoal.submit(user, "\u{1F389}")
      assert space.name == "New goal"
      assert space.slug =~ ~r/\Anew-goal-[0-9a-f]{6}\z/
    end

    test "a goal whose slug would start with a reserved prefix is prefixed with goal-" do
      running_burrow!()
      user = user!()

      assert {:ok, space, _msg} = FirstRunGoal.submit(user, "DM the team about Friday")
      refute Chat.reserved_slug_prefix?(space.slug)
      assert space.slug =~ ~r/\Agoal-dm-the-team-about-friday-[0-9a-f]{6}\z/
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

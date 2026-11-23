defmodule Platform.Goals.ConversationSpaceTest do
  @moduledoc """
  Task 01a20939 stage 1: each goal's own conversation space
  (`Platform.Goals.Conversation`). The proposal's space becomes the goal's
  at confirm; a goal with no proposal gets one lazily; members are the owner
  and the current coach only; the space is hidden from the chat rail and
  never grants goal visibility.

  The real concurrent `ensure_space/1` race runs outside the SQL sandbox, in
  `Platform.Goals.ConversationSpaceConcurrencyTest`.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Goals
  alias Platform.Goals.{Conversation, Goal, Grant, Visibility}

  @now ~U[2026-11-16 09:00:00.000000Z]

  setup do
    enable_goals!()

    old = Map.new([:clock_now, :wake_up_dispatcher], &{&1, Application.fetch_env(:goals, &1)})
    parent = self()
    Application.put_env(:goals, :clock_now, fn -> @now end)

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:signal, signal})
      :ok
    end)

    on_exit(fn ->
      for {key, previous} <- old do
        case previous do
          {:ok, value} -> Application.put_env(:goals, key, value)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end)

    org = org_id!()
    %{org: org, person: member!(org)}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  @full %{
    title: "Run a half marathon",
    why: "To feel strong",
    unit: "km",
    target_value: "21.1",
    source_key: "self_reported",
    agent_mode: "coach",
    rhythm: "weekly",
    rhythm_weekday: 3,
    outreach: "gentle",
    kind: "shared"
  }

  defp lead!(c) do
    agent = coach_agent!(c.person)
    {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), agent.id)
    agent
  end

  defp confirmed!(c, lead) do
    {:ok, proposal} = Goals.start_goal_conversation(c.person, "I want to run a half marathon")
    assert_received {:signal, _new_goal}

    {:ok, proposal} = Goals.propose_goal(lead, proposal.id, Map.put(@full, :ready, true))

    {:ok, %{goal: goal, proposal: proposal}} =
      Goals.confirm_proposal(c.person, proposal.id, proposal.revision)

    assert_received {:signal, _research}
    {goal, proposal}
  end

  defp coached_goal!(c) do
    coach = coach_agent!(c.person)
    {goal!(c.person, c.org, %{coach_agent_id: coach.id}), coach}
  end

  defp spaces_for(goal_id) do
    Repo.all(from(s in Space, where: fragment("?->>'goal_id' = ?", s.metadata, ^goal_id)))
  end

  defp members_of(space_id) do
    space_id
    |> Chat.list_participants()
    |> MapSet.new(&{&1.participant_type, &1.participant_id})
  end

  defp agent_row(space_id, agent_id) do
    Repo.one(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  defp reload(goal), do: Repo.get!(Goal, goal.id)

  # ── confirm ───────────────────────────────────────────────────────────────

  test "confirm links the proposal's space to the goal, in the same write, with no new space",
       c do
    lead = lead!(c)

    {:ok, proposal} = Goals.start_goal_conversation(c.person, "I want to run a half marathon")
    assert_received {:signal, _}
    {:ok, proposal} = Goals.propose_goal(lead, proposal.id, Map.put(@full, :ready, true))
    spaces_before = Repo.aggregate(Space, :count)

    {:ok, %{goal: goal}} = Goals.confirm_proposal(c.person, proposal.id, proposal.revision)
    assert_received {:signal, _}

    assert goal.conversation_space_id == proposal.space_id
    assert reload(goal).conversation_space_id == proposal.space_id
    assert Repo.aggregate(Space, :count) == spaces_before

    space = Repo.get!(Space, proposal.space_id)
    assert space.metadata["goal_id"] == goal.id
    assert space.metadata["surface"] == "goals"
    refute Chat.rail_visible?(space)
    assert members_of(space.id) == MapSet.new([{"user", c.person.id}, {"agent", lead.id}])

    assert [%{type: "user", id: owner_id}, %{type: "agent", id: coach_id}] =
             Conversation.members(goal)

    assert {owner_id, coach_id} == {c.person.id, lead.id}

    # ensure_space finds it; it does not make another.
    assert {:ok, %Space{id: id}} = Conversation.ensure_space(goal)
    assert id == proposal.space_id
    assert [_one] = spaces_for(goal.id)
  end

  # ── ensure_space ──────────────────────────────────────────────────────────

  test "ensure_space creates one hidden owner + coach space, and a second call returns it", c do
    {goal, coach} = coached_goal!(c)
    assert goal.conversation_space_id == nil
    assert Conversation.members(goal) == []

    assert {:ok, %Space{} = first} = Conversation.ensure_space(goal)
    assert {:ok, %Space{} = second} = Conversation.ensure_space(goal)
    assert first.id == second.id
    assert [%Space{id: only}] = spaces_for(goal.id)
    assert only == first.id
    assert reload(goal).conversation_space_id == first.id

    assert first.kind == "dm"
    refute first.is_direct
    assert first.metadata == %{"surface" => "goals", "goal_id" => goal.id}
    refute Chat.rail_visible?(first)
    assert members_of(first.id) == MapSet.new([{"user", c.person.id}, {"agent", coach.id}])
    assert agent_row(first.id, coach.id).history_visible_from == nil
  end

  test "ensure_space for a coachless goal seats the owner only", c do
    goal = goal!(c.person, c.org)

    assert {:ok, space} = Conversation.ensure_space(goal)
    assert members_of(space.id) == MapSet.new([{"user", c.person.id}])
  end

  test "ensure_space replaces an archived space and repoints the goal", c do
    {goal, _coach} = coached_goal!(c)
    {:ok, old} = Conversation.ensure_space(goal)

    Repo.update_all(from(s in Space, where: s.id == ^old.id),
      set: [archived_at: DateTime.utc_now()]
    )

    assert {:ok, new} = Conversation.ensure_space(reload(goal))
    refute new.id == old.id
    assert reload(goal).conversation_space_id == new.id
  end

  # Sandboxed processes share one connection, so these run one after another:
  # this pins idempotency across processes. The real overlapping race (and
  # the FOR UPDATE probe) is ConversationSpaceConcurrencyTest.
  test "ensure_space from several sandboxed processes in turn gives one space", c do
    {goal, _coach} = coached_goal!(c)
    owner = self()

    ids =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
          {:ok, space} = Conversation.ensure_space(goal)
          space.id
        end)
      end)
      |> Enum.map(&Task.await(&1, 15_000))

    assert length(Enum.uniq(ids)) == 1
    assert [_one] = spaces_for(goal.id)
  end

  # ── membership ────────────────────────────────────────────────────────────

  test "sharing the goal with a user, a team and a space adds nobody to its space", c do
    {goal, coach} = coached_goal!(c)
    {:ok, space} = Conversation.ensure_space(goal)

    other = member!(c.org)
    channel = space!(c.org)
    join_space!(channel.id, :user, c.person.id)
    join_space!(channel.id, :user, other.id)
    contributor = agent!()
    join_space!(channel.id, :agent, contributor.id)

    {:ok, _} = Goals.open_goal(c.person, goal.id, {:user, other.id})
    {:ok, _} = Goals.open_goal(c.person, goal.id, {:team, c.org})
    {:ok, _} = Goals.open_goal(c.person, goal.id, {:space, channel.id})

    assert members_of(space.id) == MapSet.new([{"user", c.person.id}, {"agent", coach.id}])
    refute Repo.exists?(from(g in Grant, where: g.space_id == ^space.id))
    assert Repo.aggregate(from(g in Grant, where: g.goal_id == ^goal.id), :count) == 3
  end

  test "a coach change deletes the old coach's row and bounds the new coach's history", c do
    {goal, old_coach} = coached_goal!(c)
    {:ok, space} = Conversation.ensure_space(goal)
    new_coach = coach_agent!(c.person)

    before = DateTime.utc_now()
    {:ok, updated} = Goals.update_goal(c.person, goal.id, %{coach_agent_id: new_coach.id})
    assert updated.coach_agent_id == new_coach.id

    assert agent_row(space.id, old_coach.id) == nil
    row = agent_row(space.id, new_coach.id)
    assert %DateTime{} = row.history_visible_from
    assert DateTime.compare(row.history_visible_from, before) != :lt
    assert members_of(space.id) == MapSet.new([{"user", c.person.id}, {"agent", new_coach.id}])

    assert [%{type: "user"}, %{type: "agent", id: id}] = Conversation.members(reload(goal))
    assert id == new_coach.id

    # An edit that leaves the coach alone touches no participant row.
    {:ok, _} = Goals.update_goal(c.person, goal.id, %{title: "Renamed"})
    assert agent_row(space.id, new_coach.id) == row

    # Removing the coach leaves the owner alone in the space.
    {:ok, _} = Goals.update_goal(c.person, goal.id, %{coach_agent_id: nil})
    assert members_of(space.id) == MapSet.new([{"user", c.person.id}])
  end

  test "a coach change on a goal with no space yet writes no space", c do
    {goal, _coach} = coached_goal!(c)
    new_coach = coach_agent!(c.person)

    {:ok, _} = Goals.update_goal(c.person, goal.id, %{coach_agent_id: new_coach.id})
    assert spaces_for(goal.id) == []

    {:ok, space} = Conversation.ensure_space(reload(goal))
    assert members_of(space.id) == MapSet.new([{"user", c.person.id}, {"agent", new_coach.id}])
  end

  # ── visibility ────────────────────────────────────────────────────────────

  test "participating only in a goal's space grants no visibility of the goal", c do
    {lazy_goal, _coach} = coached_goal!(c)
    {:ok, lazy_space} = Conversation.ensure_space(lazy_goal)
    {confirmed_goal, proposal} = confirmed!(c, lead!(c))

    stranger = member!(c.org)
    stray_agent = agent!()

    for space_id <- [lazy_space.id, proposal.space_id] do
      join_space!(space_id, :user, stranger.id)
      join_space!(space_id, :agent, stray_agent.id)
    end

    assert Repo.all(Visibility.visible_goals(stranger)) == []
    assert Repo.all(Visibility.visible_goals(stray_agent)) == []
    assert Goals.get_goal(stranger, lazy_goal.id) == {:error, :not_found}
    assert Goals.get_goal(stranger, confirmed_goal.id) == {:error, :not_found}

    refute Repo.exists?(from(g in Grant, where: g.goal_id in ^[lazy_goal.id, confirmed_goal.id]))
  end
end

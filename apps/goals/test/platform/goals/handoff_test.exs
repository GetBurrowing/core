defmodule Platform.Goals.HandoffTest do
  @moduledoc """
  Goals 7/8 stage 1 (task 01a1dfc1-dffb): the hand-off of a shared goal to a
  space's agents, stored on the space grant, and the contributors derived
  from the space's agent participants.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures, only: [put_now: 1]

  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.{Clock, GoalClock, Grant}

  @t0 ~U[2026-02-04 07:00:00.000000Z]

  @goal_tables [
    Platform.Goals.Goal,
    Platform.Goals.Stop,
    Platform.Goals.Entry,
    Platform.Goals.Reading,
    GoalClock,
    Platform.Goals.WakeUp,
    Platform.Goals.Ask,
    Platform.Goals.AskAnswer,
    Platform.Goals.TaskLink,
    Platform.Goals.BriefItem
  ]

  setup do
    enable_goals!()
    previous = Application.fetch_env(:goals, :clock_now)
    put_now(@t0)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :clock_now, value)
        :error -> Application.delete_env(:goals, :clock_now)
      end
    end)

    org = org_id!()
    owner = member!(org)
    manager = root_admin!()
    coach = agent!()
    x = agent!()
    y = agent!()
    space = space!(org)

    for user <- [owner, manager], do: join_space!(space.id, :user, user.id)
    for agent <- [coach, x, y], do: join_space!(space.id, :agent, agent.id)

    goal = goal!(owner, org, %{coach_agent_id: coach.id, agent_mode: "do"})

    %{
      org: org,
      owner: owner,
      manager: manager,
      coach: coach,
      x: x,
      y: y,
      space: space,
      goal: goal
    }
  end

  defp grant(goal_id, space_id),
    do:
      Repo.one!(
        from(gr in Grant,
          where:
            gr.goal_id == ^goal_id and gr.audience_type == "space" and gr.space_id == ^space_id
        )
      )

  defp ids(contributors), do: contributors |> Enum.map(& &1.agent_id) |> Enum.sort()

  defp counts(schemas), do: Enum.map(schemas, &Repo.aggregate(&1, :count))

  test "opening a personal goal to a space shares it and adds exactly one grant", c do
    assert c.goal.kind == "personal"
    grants_before = Repo.aggregate(Grant, :count)
    others_before = counts(@goal_tables)

    assert {:ok, opened} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})

    assert opened.kind == "shared"
    assert Repo.aggregate(Grant, :count) == grants_before + 1
    assert counts(@goal_tables) == others_before
    assert %Grant{handed_at: nil, handed_by_user_id: nil} = grant(c.goal.id, c.space.id)
  end

  test "a root admin in the space hands the goal; contributors are its agents minus the coach",
       c do
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})
    assert {:ok, []} = Goals.list_contributors(c.owner, c.goal.id)

    assert {:ok, %{grant: handed, goal: goal}} =
             Goals.hand_goal_to_space(c.manager, c.goal.id, c.space.id)

    assert handed.handed_at == @t0
    assert handed.handed_by_user_id == c.manager.id
    assert goal.coach_agent_id == c.coach.id

    assert {:ok, contributors} = Goals.list_contributors(c.owner, c.goal.id)
    assert ids(contributors) == Enum.sort([c.x.id, c.y.id])

    for row <- contributors do
      assert row.space_id == c.space.id
      assert row.space_name == c.space.name
      assert row.name in [c.x.name, c.y.name]
    end

    # The coach and the contributors read the same list.
    assert {:ok, ^contributors} = Goals.list_contributors(c.coach, c.goal.id)
    assert {:ok, ^contributors} = Goals.list_contributors(c.x, c.goal.id)

    # A second hand, later, changes nothing.
    put_now(DateTime.add(@t0, 3600))
    assert {:ok, %{grant: again}} = Goals.hand_goal_to_space(c.manager, c.goal.id, c.space.id)
    assert again.handed_at == @t0
    assert grant(c.goal.id, c.space.id) == handed
  end

  describe "refusals leave the grant unchanged" do
    setup c do
      {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})
      %{before: grant(c.goal.id, c.space.id)}
    end

    test "who may hand", c do
      outsider_admin = root_admin!()
      participant = user!()
      join_space!(c.space.id, :user, participant.id)
      {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, outsider_admin.id})
      {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, participant.id})

      # A root admin who is not a participant, the owner who is not a root
      # admin, and a participant who is neither.
      for user <- [outsider_admin, c.owner, participant] do
        assert Goals.hand_goal_to_space(user, c.goal.id, c.space.id) == {:error, :forbidden}
        assert grant(c.goal.id, c.space.id) == c.before
      end

      # Agents never hand, not even the coach.
      assert Goals.hand_goal_to_space(c.coach, c.goal.id, c.space.id) == {:error, :forbidden}
      assert grant(c.goal.id, c.space.id) == c.before
    end

    test "an unseen goal is the same not_found as a random id", c do
      other_org = org_id!()
      other_goal = goal!(member!(other_org), other_org)

      unseen = Goals.hand_goal_to_space(c.manager, other_goal.id, c.space.id)
      random = Goals.hand_goal_to_space(c.manager, Ecto.UUID.generate(), c.space.id)
      malformed = Goals.hand_goal_to_space(c.manager, "not-a-uuid", c.space.id)

      assert unseen == {:error, :not_found}
      assert random == unseen
      assert malformed == unseen
      assert Goals.hand_goal_to_space(c.manager, c.goal.id, "not-a-uuid") == unseen
      assert grant(c.goal.id, c.space.id) == c.before
    end

    test "a space the goal is not opened to is not_linked and creates no grant", c do
      other = space!(c.org)
      join_space!(other.id, :user, c.manager.id)
      join_space!(other.id, :agent, c.coach.id)
      before = Repo.aggregate(Grant, :count)

      assert Goals.hand_goal_to_space(c.manager, c.goal.id, other.id) == {:error, :not_linked}
      assert Repo.aggregate(Grant, :count) == before
      assert grant(c.goal.id, c.space.id) == c.before
    end

    test "a coachless goal handed by someone other than the owner is no_coach", c do
      coachless = goal!(c.owner, c.org, %{agent_mode: "do"})
      {:ok, _} = Goals.open_goal(c.owner, coachless.id, {:space, c.space.id})
      {:ok, _} = Chat.update_space(c.space, %{leader_agent_id: c.x.id})
      before = grant(coachless.id, c.space.id)

      assert Goals.hand_goal_to_space(c.manager, coachless.id, c.space.id) ==
               {:error, :no_coach}

      assert grant(coachless.id, c.space.id) == before
      assert {:ok, %{coach_agent_id: nil}} = Goals.get_goal(c.owner, coachless.id)
    end

    test "a coach who is not a participant of the space is coach_not_in_space", c do
      outside_coach = agent!()
      goal = goal!(c.owner, c.org, %{coach_agent_id: outside_coach.id})
      {:ok, _} = Goals.open_goal(c.owner, goal.id, {:space, c.space.id})
      before = grant(goal.id, c.space.id)
      participants = length(Chat.list_participants(c.space.id))

      assert Goals.hand_goal_to_space(c.manager, goal.id, c.space.id) ==
               {:error, :coach_not_in_space}

      assert grant(goal.id, c.space.id) == before
      assert length(Chat.list_participants(c.space.id)) == participants
    end
  end

  test "the owner who may hand gives a coachless goal the space's leader and syncs the clock",
       c do
    admin_owner = root_admin!()
    join_space!(c.space.id, :user, admin_owner.id)
    goal = goal!(admin_owner, c.org, %{coach_agent_id: c.coach.id, agent_mode: "do"})

    # A clock row exists (the first tick creates it), then the coach is removed.
    :ok = Clock.tick(@t0)
    assert %GoalClock{} = clock = Repo.one!(from(k in GoalClock, where: k.goal_id == ^goal.id))

    {:ok, %{coach_agent_id: nil}} =
      Goals.update_goal(admin_owner, goal.id, %{coach_agent_id: nil})

    {:ok, _} = Goals.open_goal(admin_owner, goal.id, {:space, c.space.id})
    {:ok, _} = Chat.update_space(c.space, %{leader_agent_id: c.x.id})

    later = DateTime.add(@t0, 3 * 86_400)
    put_now(later)

    assert {:ok, %{goal: handed_goal, grant: handed}} =
             Goals.hand_goal_to_space(admin_owner, goal.id, c.space.id)

    assert handed_goal.coach_agent_id == c.x.id
    assert handed.handed_at == later
    assert {:ok, %{coach_agent_id: coach_id}} = Goals.get_goal(admin_owner, goal.id)
    assert coach_id == c.x.id

    synced = Repo.one!(from(k in GoalClock, where: k.goal_id == ^goal.id))
    assert DateTime.compare(synced.next_wake_at, clock.next_wake_at) == :gt
    assert DateTime.compare(synced.next_wake_at, later) == :gt

    # The leader is the coach, so it is not a contributor.
    assert {:ok, contributors} = Goals.list_contributors(admin_owner, goal.id)
    assert ids(contributors) == Enum.sort([c.coach.id, c.y.id])
  end

  test "a coachless goal with no leader is no_coach even for an owner who may hand", c do
    admin_owner = root_admin!()
    join_space!(c.space.id, :user, admin_owner.id)
    goal = goal!(admin_owner, c.org)
    {:ok, _} = Goals.open_goal(admin_owner, goal.id, {:space, c.space.id})

    assert Goals.hand_goal_to_space(admin_owner, goal.id, c.space.id) == {:error, :no_coach}
    assert grant(goal.id, c.space.id).handed_at == nil
  end

  describe "take_goal_back/3" do
    setup c do
      {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})
      {:ok, _} = Goals.hand_goal_to_space(c.manager, c.goal.id, c.space.id)
      :ok
    end

    test "the owner takes it back; contributors empty; taking back again is ok unchanged", c do
      assert {:ok, %{grant: back}} = Goals.take_goal_back(c.owner, c.goal.id, c.space.id)
      assert back.handed_at == nil
      assert back.handed_by_user_id == nil
      assert {:ok, []} = Goals.list_contributors(c.owner, c.goal.id)

      assert {:ok, %{grant: ^back}} = Goals.take_goal_back(c.owner, c.goal.id, c.space.id)
      assert grant(c.goal.id, c.space.id) == back
    end

    test "a user who may hand takes it back; anyone else is refused", c do
      participant = user!()
      join_space!(c.space.id, :user, participant.id)
      handed = grant(c.goal.id, c.space.id)

      assert Goals.take_goal_back(participant, c.goal.id, c.space.id) == {:error, :forbidden}
      assert Goals.take_goal_back(c.coach, c.goal.id, c.space.id) == {:error, :forbidden}
      assert grant(c.goal.id, c.space.id) == handed

      assert {:ok, %{grant: %{handed_at: nil}}} =
               Goals.take_goal_back(c.manager, c.goal.id, c.space.id)
    end
  end

  test "closing and reopening the space gives a fresh grant with no hand-off", c do
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})
    {:ok, _} = Goals.hand_goal_to_space(c.manager, c.goal.id, c.space.id)
    assert {:ok, [_, _]} = Goals.list_contributors(c.owner, c.goal.id)

    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:space, c.space.id})
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})

    assert grant(c.goal.id, c.space.id).handed_at == nil
    assert {:ok, []} = Goals.list_contributors(c.owner, c.goal.id)
  end

  describe "contributors are derived live" do
    setup c do
      {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})
      {:ok, _} = Goals.hand_goal_to_space(c.manager, c.goal.id, c.space.id)
      :ok
    end

    test "an agent whose participant row is deleted is no longer listed", c do
      row = Chat.get_agent_participant(c.space.id, c.x.id)
      leave_space!(row)

      assert {:ok, contributors} = Goals.list_contributors(c.owner, c.goal.id)
      assert ids(contributors) == [c.y.id]
    end

    test "an agent that is not active is not listed", c do
      {:ok, _} = c.y |> Platform.Agents.Agent.changeset(%{status: "paused"}) |> Repo.update()

      assert {:ok, contributors} = Goals.list_contributors(c.owner, c.goal.id)
      assert ids(contributors) == [c.x.id]
    end

    test "the coach is never listed", c do
      assert {:ok, contributors} = Goals.list_contributors(c.owner, c.goal.id)
      refute c.coach.id in ids(contributors)
    end

    test "an agent of a space the goal is shown in but not handed to is not listed", c do
      shown = space!(c.org)
      z = agent!()
      join_space!(shown.id, :user, c.owner.id)
      join_space!(shown.id, :agent, z.id)
      {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, shown.id})

      assert {:ok, contributors} = Goals.list_contributors(c.owner, c.goal.id)
      assert ids(contributors) == Enum.sort([c.x.id, c.y.id])
    end

    test "an agent in two handed spaces is one row, under the first space by name", c do
      second = space!(c.org)
      {:ok, second} = Chat.update_space(second, %{name: "AAA first by name #{unique()}"})
      join_space!(second.id, :user, c.owner.id)
      join_space!(second.id, :user, c.manager.id)
      join_space!(second.id, :agent, c.coach.id)
      join_space!(second.id, :agent, c.x.id)
      {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, second.id})
      {:ok, _} = Goals.hand_goal_to_space(c.manager, c.goal.id, second.id)

      assert {:ok, contributors} = Goals.list_contributors(c.owner, c.goal.id)
      assert ids(contributors) == Enum.sort([c.x.id, c.y.id])
      assert %{space_id: space_id} = Enum.find(contributors, &(&1.agent_id == c.x.id))
      assert space_id == second.id
    end
  end

  test "describe_goal/2 and describe_goals/1 mark each space item handed? or not", c do
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, c.manager.id})

    assert {:ok, %{audience: audience}} = Goals.describe_goal(c.owner, c.goal.id)
    assert %{type: :space, handed?: false} = Enum.find(audience, &(&1.type == :space))
    refute Map.has_key?(Enum.find(audience, &(&1.type == :user)), :handed?)

    {:ok, _} = Goals.hand_goal_to_space(c.manager, c.goal.id, c.space.id)

    assert {:ok, %{audience: audience}} = Goals.describe_goal(c.owner, c.goal.id)

    assert %{type: :space, id: space_id, name: name, handed?: true} =
             Enum.find(audience, &(&1.type == :space))

    assert {space_id, name} == {c.space.id, c.space.name}

    assert {:ok, cards} = Goals.describe_goals(c.owner)
    card = Enum.find(cards, &(&1.goal.id == c.goal.id))
    assert %{handed?: true} = Enum.find(card.audience, &(&1.type == :space))
  end

  test "the CHECK refuses a hand-off on a user or a team grant as a changeset error", c do
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, c.manager.id})
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:team, c.org})

    for type <- ~w(user team) do
      row =
        Repo.one!(
          from(gr in Grant, where: gr.goal_id == ^c.goal.id and gr.audience_type == ^type)
        )

      assert {:error, changeset} =
               row
               |> Ecto.Changeset.change(handed_at: @t0)
               |> Grant.name_constraints()
               |> Repo.update()

      assert {"is invalid", opts} = changeset.errors[:handed_at]
      assert opts[:constraint_name] == "goal_grants_handoff_only_space"
      assert Repo.reload!(row).handed_at == nil
    end

    # Positive control: the same write on a space grant is accepted.
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})

    assert {:ok, %{handed_at: @t0}} =
             grant(c.goal.id, c.space.id)
             |> Ecto.Changeset.change(handed_at: @t0)
             |> Grant.name_constraints()
             |> Repo.update()
  end

  test "the grant changeset never casts the hand-off columns from attrs", c do
    changeset =
      %Grant{goal_id: c.goal.id}
      |> Grant.changeset(%{
        audience_type: "space",
        space_id: c.space.id,
        handed_at: @t0,
        handed_by_user_id: c.manager.id,
        card_canvas_id: Ecto.UUID.generate(),
        last_update_wake_up_id: Ecto.UUID.generate(),
        last_update_at: @t0,
        last_update_number: "all|3"
      })

    for field <-
          ~w(handed_at handed_by_user_id card_canvas_id last_update_wake_up_id last_update_at last_update_number)a,
        do: refute(Map.has_key?(changeset.changes, field))
  end

  test "a stranger and an agent outside the space see none of it", c do
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, c.space.id})
    {:ok, _} = Goals.hand_goal_to_space(c.manager, c.goal.id, c.space.id)
    handed = grant(c.goal.id, c.space.id)
    stranger = root_admin!()
    outside_agent = agent!()

    for actor <- [stranger, outside_agent] do
      assert Goals.hand_goal_to_space(actor, c.goal.id, c.space.id) == {:error, :not_found}
      assert Goals.take_goal_back(actor, c.goal.id, c.space.id) == {:error, :not_found}
      assert Goals.list_contributors(actor, c.goal.id) == {:error, :not_found}
    end

    assert grant(c.goal.id, c.space.id) == handed
  end

  test "max_tasks_per_wake_up defaults to 3 and reads :goals, :limits" do
    previous = Application.fetch_env(:goals, :limits)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :limits, value)
        :error -> Application.delete_env(:goals, :limits)
      end
    end)

    Application.delete_env(:goals, :limits)
    assert Platform.Goals.Limits.max_tasks_per_wake_up() == 3
    Application.put_env(:goals, :limits, %{max_tasks_per_wake_up: 2})
    assert Platform.Goals.Limits.max_tasks_per_wake_up() == 2
  end
end

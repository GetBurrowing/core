defmodule Platform.Goals.DisabledTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals
  alias Platform.Goals.{Goal, Stop, Entry, Grant, Reading, WakeUp, Ask, AskAnswer, TaskLink}

  test "every public context function refuses before writes" do
    enable_goals!()
    Application.put_env(:goals, :enabled, false)
    before = counts()
    functions = Goals.__info__(:functions) |> Enum.reject(fn {name, _} -> name == :enabled? end)
    assert length(functions) >= 79

    # Goals 7/8: the hand-off functions are in the iterated set.
    for f <- [
          hand_goal_to_space: 3,
          take_goal_back: 3,
          list_contributors: 2,
          ensure_space_card: 3,
          space_card: 2
        ],
        do: assert(f in functions, "#{inspect(f)} is not exported")

    # Goals 4/8: the page reads are in the iterated set.
    for f <- [describe_goals: 1, describe_goal: 2, list_audience_options: 2],
        do: assert(f in functions, "#{inspect(f)} is not exported")

    # Goals 5/8: the New goal conversation.
    for f <- [
          lead_agent: 1,
          start_goal_conversation: 2,
          current_proposal: 1,
          get_proposal: 2,
          list_proposals: 1,
          conversation: 2,
          say_in_conversation: 3,
          propose_goal: 3,
          confirm_proposal: 3,
          cancel_proposal: 2,
          subscribe_proposal: 2
        ],
        do: assert(f in functions, "#{inspect(f)} is not exported")

    for f <- [
          clock_status: 2,
          refresh_brief: 2,
          set_report_noted: 3,
          close_retro: 3,
          decide_retro_change: 4,
          get_retro: 3,
          list_retros: 2,
          list_retros: 3,
          prediction_states: 2,
          expected_pace: 2,
          expected_pace: 3,
          prepare_brief: 2,
          brief_items: 2,
          brief_summary: 2,
          ask_brief_date: 2,
          set_report_noted: 3,
          request_undo: 3,
          request_undo: 4,
          ask_coach: 3,
          ask_coach: 4,
          withdraw_answer: 2,
          record_practice: 3,
          practice_streak: 2,
          practice_streak: 3,
          get_ask: 2,
          refresh_brief: 2
        ],
        do: assert(f in functions, "#{inspect(f)} is not exported")

    refute Goals.enabled?()

    for {name, arity} <- functions do
      args = [nil | List.duplicate(%{}, arity - 1)] |> Enum.take(arity)

      assert apply(Goals, name, args) == {:error, :goals_disabled},
             "#{name}/#{arity} did not refuse"
    end

    assert counts() == before
  end

  defp counts,
    do:
      Enum.map(
        [
          Goal,
          Stop,
          Entry,
          Grant,
          Reading,
          WakeUp,
          Ask,
          AskAnswer,
          TaskLink,
          Platform.Goals.BriefItem,
          Platform.Goals.Proposal,
          Platform.Chat.Message,
          Platform.Chat.Space,
          Platform.Tasks.Task
        ],
        &Repo.aggregate(&1, :count)
      )

  test "Goals 7/8: with the switch off no space is claimed and no update is posted" do
    enable_goals!()
    org = org_id!()
    owner = member!(org)
    coach = agent!()
    goal = goal!(owner, org, %{coach_agent_id: coach.id})
    space = space!(org)
    join_space!(space.id, :user, owner.id)
    join_space!(space.id, :agent, coach.id)
    {:ok, _} = Goals.open_goal(owner, goal.id, {:space, space.id})
    assert Platform.Goals.SpaceClaim.claimed?(space.id)

    Application.put_env(:goals, :enabled, false)
    refute Platform.Goals.SpaceClaim.claimed?(space.id)
    refute Platform.Goals.Extension.claims_space_goal?(space.id)
    before = Repo.aggregate(Platform.Chat.Message, :count)

    wake = %WakeUp{id: Ecto.UUID.generate(), goal_id: goal.id, outcome: "do", reading_id: nil}
    assert Platform.Goals.SpaceUpdates.publish(coach, goal.id, wake, nil, []) == []
    assert Repo.aggregate(Platform.Chat.Message, :count) == before
  end
end

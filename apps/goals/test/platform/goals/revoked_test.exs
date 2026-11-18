defmodule Platform.Goals.RevokedTest do
  @moduledoc """
  Goals 9 (task 01a1e229): `goals.use` is checked inside `Platform.Goals` on
  every call (`Platform.Goals.Visibility.may_use?/1`), so a person who loses
  it gets nothing on their next call, with no page reload. Agents and the
  clock are unchanged. Modelled on `disabled_test.exs`: the sweep is driven
  from `Platform.Goals.__info__(:functions)`, so a new public function cannot
  be skipped silently.
  """
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals

  alias Platform.Goals.{
    Ask,
    Clock,
    AskAnswer,
    BriefItem,
    Entry,
    Goal,
    GoalClock,
    Grant,
    Proposal,
    Reading,
    Stop,
    TaskLink,
    WakeUp
  }

  setup do
    c = setup_brief()

    ask_goal = fn title, mode ->
      goal!(c.owner, c.org, %{
        title: title,
        coach_agent_id: c.coach.id,
        agent_mode: mode,
        outreach: "pushy",
        rhythm: "daily"
      })
    end

    offer_goal = ask_goal.("Write the outline", "advise")
    practice_goal = ask_goal.("Practise", "coach")
    ask = queued(%{c | goal: offer_goal}, %{kind: "offer", payload: %{"draft" => "An outline"}})

    practice =
      queued(%{c | goal: practice_goal}, %{kind: "practice", payload: %{"cards" => cards(1)}})

    {:ok, [stop]} =
      Goals.put_stops(c.owner, c.goal.id, [%{label: "First 100", target_value: 100}])

    {:ok, reading} = Goals.log_reading(c.owner, c.goal.id, %{value: 12})
    entry = action(c, %{details: %{"undo_note" => "Delete the draft"}})
    day = date()
    {:ok, _} = Goals.prepare_brief(c.owner, day)
    {:ok, items} = Goals.brief_items(c.owner, day)
    report = Enum.find(items, &(&1.kind == :report))
    assert report, "no report brief item was seeded"
    assert Enum.any?(items, &(&1.kind == :practice)), "no practice brief item was seeded"
    space = space!(c.org)
    join_space!(space.id, :user, c.owner.id)
    wake = Repo.one!(from(w in WakeUp, where: w.id == ^ask.wake_up_id))

    Map.merge(c, %{
      stop: stop,
      reading: reading,
      entry: entry,
      ask: ask,
      offer_goal: offer_goal,
      practice: practice,
      report: report,
      space: space,
      wake: wake,
      day: day
    })
  end

  # Full argument lists; a function with defaults is called at every arity
  # with the leading arguments.
  defp args(c) do
    u = c.owner
    g = c.goal.id
    missing = Ecto.UUID.generate()

    %{
      create_goal: [u, %{org_id: c.org, title: "A new one"}],
      list_goals: [u],
      get_goal: [u, g],
      update_goal: [u, g, %{title: "Changed"}],
      hand_off_coach: [u, g, c.goal.coach_agent_id || missing],
      open_goal: [u, g, {:team, c.org}],
      close_goal: [u, g, {:team, c.org}],
      list_audience: [u, g],
      put_stops: [u, g, [%{label: "Other", target_value: 5}]],
      update_stop: [u, g, c.stop.id, %{label: "Renamed"}],
      list_stops: [u, g],
      add_entry: [u, g, %{kind: "note", title: "A note", occurred_at: Clock.now()}],
      list_entries: [u, g, []],
      log_reading: [u, g, %{value: 40}],
      measure_goal: [u, g],
      goal_number: [u, g, []],
      expected_pace: [u, g, []],
      list_readings: [u, g, []],
      list_sources: [u],
      lead_agent: [u],
      start_goal_conversation: [u, "I want to run a marathon", []],
      list_coaches: [u],
      current_proposal: [u],
      get_proposal: [u, missing],
      list_proposals: [u],
      conversation: [u, missing],
      say_in_conversation: [u, missing, "More"],
      propose_goal: [u, missing, %{}],
      confirm_proposal: [u, missing, 1],
      cancel_proposal: [u, missing],
      subscribe_proposal: [u, missing],
      subscribe_proposals: [u],
      list_wake_ups: [u, c.offer_goal.id, []],
      get_wake_up: [u, c.wake.id],
      clock_status: [u, g],
      restart_clock: [u, g],
      close_wake_up: [u, c.wake.id, "wait", %{reason: "Not yet"}],
      close_retro: [u, c.wake.id, %{}],
      decide_retro_change: [u, g, c.entry.id, "keep"],
      get_retro: [u, g, c.entry.id],
      list_retros: [u, g, []],
      prediction_states: [u, g],
      list_asks: [u, c.offer_goal.id, []],
      list_my_asks: [u, []],
      answer_ask: [u, c.ask.id, "used", %{}],
      prepare_brief: [u, c.day],
      brief_items: [u, c.day],
      ask_brief_date: [u, c.ask.id],
      brief_summary: [u, c.day],
      set_report_noted: [u, c.report.id, true],
      request_undo: [u, g, c.entry.id, "undo"],
      ask_coach: [u, g, "Why this?", []],
      withdraw_answer: [u, c.ask.id],
      record_practice: [u, c.ask.id, results([0], [])],
      practice_streak: [u, g, []],
      get_ask: [u, c.ask.id],
      refresh_brief: [u, c.ask.id],
      list_goal_tasks: [u, g, []],
      link_task: [u, g, missing, %{}],
      describe_goals: [u],
      describe_goal: [u, g],
      list_audience_options: [u, g],
      entry_authors: [u, g],
      hand_goal_to_space: [u, g, c.space.id],
      take_goal_back: [u, g, c.space.id],
      list_contributors: [u, g],
      ensure_space_card: [u, g, c.space.id],
      space_card: [u, missing]
    }
  end

  # The reads whose answer must carry goal data while the permission is held.
  @reads [
    list_goals: 1,
    get_goal: 2,
    list_stops: 2,
    list_entries: 2,
    list_readings: 2,
    list_my_asks: 1,
    list_asks: 2,
    get_ask: 2,
    brief_items: 2,
    describe_goals: 1,
    describe_goal: 2,
    list_wake_ups: 2,
    clock_status: 2
  ]

  defp functions,
    do: Goals.__info__(:functions) |> Enum.reject(fn {name, _} -> name == :enabled? end)

  defp call(c, {name, arity}), do: apply(Goals, name, Enum.take(Map.fetch!(args(c), name), arity))

  # A refusal or an ok holding no goal data.
  defp empty?({:error, reason}), do: reason in [:not_found, :forbidden]
  defp empty?(:ok), do: true
  defp empty?({:ok, value}), do: blank?(value)
  defp empty?(_), do: false

  defp blank?(value) when value in [nil, [], 0, false], do: true
  defp blank?(%{__struct__: _}), do: false
  defp blank?(%{} = map), do: Enum.all?(map, fn {_k, v} -> blank?(v) end)
  defp blank?(_), do: false

  defp has_data?({:ok, value}), do: not blank?(value)
  defp has_data?(_), do: false

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
          GoalClock,
          Ask,
          AskAnswer,
          TaskLink,
          BriefItem,
          Proposal,
          Platform.Chat.Message,
          Platform.Chat.Space,
          Platform.Tasks.Task
        ],
        &{&1, Repo.aggregate(&1, :count)}
      )

  test "every public function gives a revoked person nothing and writes nothing", c do
    functions = functions()
    assert length(functions) >= 79
    table = args(c)

    # Every exported name has arguments, and the table names nothing stale.
    assert Enum.sort(Enum.uniq(for {name, _} <- functions, do: name)) ==
             Enum.sort(Map.keys(table))

    for {name, arity} <- functions,
        do: assert(length(Map.fetch!(table, name)) >= arity, "#{name}/#{arity} lacks arguments")

    # Positive control: the same user, before the revoke, reads goal data.
    for read <- @reads do
      assert read in functions, "#{inspect(read)} is not exported"
      assert has_data?(call(c, read)), "#{inspect(read)} returned no data while permitted"
    end

    revoke_goals_use!(c.owner)
    refute Goals.Visibility.may_use?(c.owner)
    before = counts()

    for f <- functions do
      result = call(c, f)
      assert empty?(result), "#{inspect(f)} answered a revoked person with #{inspect(result)}"
    end

    assert counts() == before
  end

  test "a revoked person gets the same answer as for a goal that does not exist", c do
    revoke_goals_use!(c.owner)
    missing = Ecto.UUID.generate()

    for {name, arity} <- [get_goal: 2, describe_goal: 2, list_stops: 2, list_entries: 2] do
      assert apply(Goals, name, Enum.take([c.owner, c.goal.id], arity)) ==
               apply(Goals, name, Enum.take([c.owner, missing], arity))
    end

    assert Goals.create_goal(c.owner, %{org_id: c.org, title: "x"}) == {:error, :forbidden}
  end

  test "a user who never held goals.use is answered as for an unknown id, even with a grant", c do
    never = user_without_goals_use!() |> join_org!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, never.id})
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:team, c.org})
    missing = Ecto.UUID.generate()

    assert Goals.get_goal(never, c.goal.id) == {:error, :not_found}
    assert Goals.get_goal(never, c.goal.id) == Goals.get_goal(never, missing)
    assert Goals.list_goals(never) == {:ok, []}
    assert Goals.list_my_asks(never, []) == {:ok, []}
    assert Goals.create_goal(never, %{org_id: c.org, title: "x"}) == {:error, :forbidden}

    # Positive control: the same grants with the permission open the goal.
    grant_goals_use!(never)
    assert {:ok, %Goal{}} = Goals.get_goal(never, c.goal.id)
  end

  test "revoked with no reload: each brief action is refused, then works after a re-grant", c do
    revoke_goals_use!(c.owner)
    before = counts()

    refused = [
      Goals.answer_ask(c.owner, c.ask.id, "used"),
      Goals.request_undo(c.owner, c.goal.id, c.entry.id),
      Goals.set_report_noted(c.owner, c.report.id, true),
      Goals.record_practice(c.owner, c.practice.id, results([0], [])),
      Goals.ask_coach(c.owner, c.goal.id, "Why these?"),
      Goals.withdraw_answer(c.owner, c.ask.id)
    ]

    assert refused == List.duplicate({:error, :not_found}, 6)
    assert counts() == before

    grant_goals_use!(c.owner)
    assert {:ok, _} = Goals.answer_ask(c.owner, c.ask.id, "used")
    assert {:ok, _} = Goals.request_undo(c.owner, c.goal.id, c.entry.id)
    assert {:ok, _} = Goals.set_report_noted(c.owner, c.report.id, true)
    assert {:ok, _} = Goals.record_practice(c.owner, c.practice.id, results([0], []))
    assert {:ok, _} = Goals.ask_coach(c.owner, c.goal.id, "Why these?")
    assert {:ok, _} = Goals.withdraw_answer(c.owner, c.ask.id)
    refute counts() == before
  end

  test "agents and the clock are unchanged for an owner who just lost goals.use", c do
    revoke_goals_use!(c.owner)
    assert Goals.Visibility.may_use?(c.coach)

    # The clock fires for the goal, and the coach closes the wake-up.
    open = fire(c.goal)

    assert {:ok, %{wake_up: %{status: "closed"}}} =
             Goals.close_wake_up(c.coach, open.id, "wait", %{reason: "Owner is away"})

    assert {:ok, %Goal{}} = Goals.get_goal(c.coach, c.goal.id)

    # The clock fires the next wake-up for that goal, and the coach can read it.
    next = fire(c.goal)
    assert next.goal_id == c.goal.id
    refute next.id == open.id
    assert {:ok, %{wake_up: %{id: id}}} = Goals.get_wake_up(c.coach, next.id)
    assert id == next.id
  end

  test "may_use? answers false for anything that is not a user or an agent" do
    for actor <- [nil, %{}, "user", %Platform.Accounts.User{}],
        do: refute(Goals.Visibility.may_use?(actor))
  end
end

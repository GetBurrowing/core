defmodule Platform.Goals.PracticeTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.{AskAnswer, Clock, Reading}
  setup do: setup_outcome()

  test "newly got cards accumulate one reading per pass and results persist", c do
    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: 10, measured_at: Clock.now()})
    ask = queued(c, %{kind: "practice", payload: %{"cards" => cards()}})
    {:ok, _} = Goals.prepare_brief(c.owner, date())
    assert Goals.record_practice(c.owner, ask.id, results([0], [])) == {:error, :incomplete}

    assert {:ok, %{got: 3, missed: 2, answer: answer, reading: reading}} =
             Goals.record_practice(c.owner, ask.id, results([0, 1, 2], [3, 4]))

    assert answer.answer == "used"
    assert length(answer.details["cards"]) == 5
    assert Decimal.equal?(reading.value, 13)
    assert reading.origin == "practice"
    before = Repo.aggregate(Reading, :count)
    assert Goals.record_practice(c.owner, ask.id, results([0, 4], [])) == {:error, :incomplete}
    assert Repo.aggregate(Reading, :count) == before
    put_now(DateTime.add(Clock.now(), 60, :second))

    assert {:ok, %{got: 5, missed: 0, reading: second}} =
             Goals.record_practice(c.owner, ask.id, results([3, 4], []))

    assert Decimal.equal?(second.value, 15)
    assert Repo.aggregate(AskAnswer, :count) == 1
    assert Goals.record_practice(c.owner, ask.id, []) == {:error, :already_answered}
    assert Goals.withdraw_answer(c.owner, ask.id) == {:error, :not_withdrawable}
    assert {:ok, {:reading, number}} = Goals.goal_number(c.owner, c.goal.id)
    assert Decimal.equal?(number.latest.value, 15)
  end

  test "a practice goal without a reading starts at zero", c do
    ask = queued(c, %{kind: "practice", payload: %{"cards" => cards(1)}})

    assert {:ok, %{got: 1, reading: reading}} =
             Goals.record_practice(c.owner, ask.id, results([0], []))

    assert Decimal.equal?(reading.value, 1)
  end

  test "a non-owner addressee records practice without changing the owner's number", c do
    reader = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})

    ask =
      queued(c, %{
        kind: "practice",
        addressed_user_ids: [reader.id],
        payload: %{"cards" => cards(1)}
      })

    assert {:ok, %{reading: nil, got: 1}} =
             Goals.record_practice(reader, ask.id, results([0], []))

    assert Repo.aggregate(Reading, :count) == 0
    assert Goals.record_practice(member!(c.org), ask.id, results([0], [])) == {:error, :not_found}
  end

  test "a measured source records answers without creating logged readings", c do
    goal =
      goal!(c.owner, c.org, %{
        coach_agent_id: c.coach.id,
        agent_mode: "do",
        outreach: "pushy",
        source_key: "task_count",
        source_config: %{"statuses" => ["done"]}
      })

    ask = queued(%{c | goal: goal}, %{kind: "practice", payload: %{"cards" => cards(1)}})
    assert {:ok, %{reading: nil}} = Goals.record_practice(c.owner, ask.id, results([0], []))
  end

  test "streaks count practice days, preserve yesterday and reset after a gap", c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{agent_mode: "coach"})
    c = %{c | goal: goal}

    for _ <- 1..7 do
      ask = queued(c, %{kind: "practice", payload: %{"cards" => cards(1)}})
      assert {:ok, _} = Goals.record_practice(c.owner, ask.id, results([0], []))
    end

    assert {:ok, 7} = Goals.practice_streak(c.owner, goal.id, today: date())
    assert {:ok, 7} = Goals.practice_streak(c.owner, goal.id, today: Date.add(date(), 1))
    assert {:ok, 0} = Goals.practice_streak(c.owner, goal.id, today: Date.add(date(), 2))
    advance(2)
    ask = queued(c, %{kind: "practice", payload: %{"cards" => cards(1)}})
    assert {:ok, %{streak: 1}} = Goals.record_practice(c.owner, ask.id, results([0], []))
  end
end

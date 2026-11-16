defmodule Platform.Goals.RetroWindowTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, Retro}
  setup do: setup_outcome()

  test "predictions use the deadline snapshot, finalize once and defer future predictions", c do
    {:ok, first} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 0, measured_at: ~U[2026-02-04 06:00:00Z]})

    for amount <- [40, 100] do
      wake = fire(c.goal)

      assert {:ok, _} =
               Goals.close_wake_up(
                 c.coach,
                 wake.id,
                 "do",
                 prediction(%{predicted_change: amount, predicted_by: ~D[2026-02-11]})
               )
    end

    {:ok, future} =
      Goals.add_entry(c.owner, c.goal.id, %{
        kind: "wait",
        prediction: "Later",
        predicted_change: 10,
        predicted_by: ~D[2026-02-20],
        occurred_at: ~U[2026-02-07 06:00:00Z],
        reading_id: first.id
      })

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 55, measured_at: ~U[2026-02-11 12:00:00Z]})

    now = ~U[2026-02-13 12:00:00Z]
    {:ok, before} = Retro.predictions(c.owner, c.goal.id, now)
    assert Enum.map(before, & &1["verdict"]) == ["came_true", "did_not", "too_early"]
    assert Enum.map(before, & &1["actual_change"]) == ["55", "55", nil]

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 500, measured_at: ~U[2026-02-12 12:00:00Z]})

    assert {:ok, ^before} = Retro.predictions(c.owner, c.goal.id, now)

    {:ok, _} =
      Goals.add_entry(c.owner, c.goal.id, %{
        kind: "retro",
        occurred_at: now,
        details: %{"verdicts" => before}
      })

    assert {:ok, [%{"entry_id" => id, "verdict" => "too_early"}]} =
             Retro.predictions(c.coach, c.goal.id, now)

    assert id == future.id
  end

  test "undated wait is not scored and is finalized without reading a number", c do
    {:ok, entry} =
      Goals.add_entry(c.owner, c.goal.id, %{
        kind: "wait",
        prediction: "Wait for a signal",
        predicted_change: 40,
        occurred_at: Clock.now()
      })

    assert {:ok, [row]} = Retro.predictions(c.owner, c.goal.id, Clock.now())
    assert row["entry_id"] == entry.id
    assert row["predicted_by"] == nil
    assert row["verdict"] == "not_scored"
    assert row["actual_change"] == nil

    {:ok, _} =
      Goals.add_entry(c.owner, c.goal.id, %{
        kind: "retro",
        occurred_at: Clock.now(),
        details: %{"verdicts" => [row]}
      })

    assert {:ok, []} = Retro.predictions(c.owner, c.goal.id, Clock.now())
  end

  test "cannot measure carries no actual number and hidden goals remain hidden", c do
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{source_key: nil})

    {:ok, _} =
      Goals.add_entry(c.owner, c.goal.id, %{
        kind: "action",
        prediction: "Grow",
        predicted_change: 40,
        predicted_by: ~D[2026-02-03],
        occurred_at: Clock.now()
      })

    assert {:ok, [%{"verdict" => "cannot_measure", "actual_change" => nil}]} =
             Retro.predictions(c.owner, c.goal.id, Clock.now())

    assert {:ok, %{change: nil, flat: false, flat_retros: 0}} =
             Retro.window(c.owner, c.goal.id, Clock.now())

    assert {:error, :not_found} = Retro.window(member!(c.org), c.goal.id, Clock.now())
  end

  test "window starts at the oldest current population reading and counts flat retros", c do
    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 10, measured_at: ~U[2026-02-01 06:00:00Z]})

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 10, measured_at: ~U[2026-02-02 06:00:00Z]})

    assert {:ok, window} = Retro.window(c.owner, c.goal.id, Clock.now())
    assert window.since == ~U[2026-02-01 06:00:00.000000Z]
    assert Decimal.equal?(window.change, 0)
    assert window.flat and window.flat_retros == 1
    refute window.goal_change_required
    assert window.answers == %{used: 0, declined: 0, ignored: 0}
  end

  test "as_of bounds latest, previous, first and baseline in the existing reader", c do
    for {day, value} <- [{1, 10}, {2, 20}, {3, 30}] do
      {:ok, _} =
        Goals.log_reading(c.owner, c.goal.id, %{
          value: value,
          measured_at: DateTime.add(~U[2026-02-01 06:00:00Z], (day - 1) * 86400)
        })
    end

    assert {:ok, {:reading, n}} =
             Goals.goal_number(c.owner, c.goal.id,
               as_of: ~U[2026-02-02 06:00:00Z],
               since: ~U[2026-02-01 06:00:00Z]
             )

    assert Decimal.equal?(n.latest.value, 20)
    assert n.first.id == n.previous.id and n.first.id == n.baseline.id
    assert Decimal.equal?(n.delta, 10) and Decimal.equal?(n.change_since, 10)
  end

  test "three consecutive flat windows require a goal change and use the answer store", c do
    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 10, measured_at: ~U[2026-02-04 06:00:00Z]})

    wake = fire(c.goal)
    {:ok, result} = Goals.close_wake_up(c.coach, wake.id, "ask", ask_attrs())
    {:ok, _} = Goals.answer_ask(c.owner, result.ask.id, "used")

    for _ <- 1..2 do
      wake = fire(c.goal)
      {:ok, result} = Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "No new signal"})
      # Stage 2 owns producing retros. Fixture a closed retro from a real clock wake.
      result.wake_up
      |> Platform.Goals.WakeUp.changeset(%{
        kind: "retro",
        outcome: "retro",
        briefing: %{"retro" => %{"flat" => true}}
      })
      |> Repo.update!()
    end

    now = DateTime.add(Clock.now(), 1)
    assert {:ok, window} = Retro.window(c.owner, c.goal.id, now)
    assert window.flat_retros == 3 and window.goal_change_required
    assert window.answers == %{used: 1, declined: 0, ignored: 0}
    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: 11, measured_at: now})

    assert {:ok, %{flat: false, flat_retros: 0, goal_change_required: false}} =
             Retro.window(c.owner, c.goal.id, now)
  end
end

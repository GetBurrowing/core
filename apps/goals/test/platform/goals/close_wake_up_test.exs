defmodule Platform.Goals.CloseWakeUpTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, Entry, WakeUp}
  setup do: setup_outcome()

  test "do, ask and wait each record exactly one outcome tied to the reading they saw", c do
    results =
      for {outcome, value} <- [{"do", "10"}, {"ask", "20"}, {"wait", "30"}] do
        assert {:ok, _} =
                 Goals.log_reading(c.owner, c.goal.id, %{value: value, measured_at: Clock.now()})

        wake = fire(c.goal)

        attrs =
          case outcome do
            "ask" -> ask_attrs()
            "wait" -> %{reason: "Wait for practice"}
            "do" -> prediction()
          end

        assert {:ok, result} = Goals.close_wake_up(c.coach, wake.id, outcome, attrs)
        assert result.wake_up.status == "closed"
        assert result.wake_up.outcome == outcome
        assert result.wake_up.entry_id == result.entry.id
        assert result.entry.reading_id == wake.reading_id
        assert result.entry.details["wake_up_id"] == wake.id

        if outcome == "wait" do
          assert result.entry.body == "Wait for practice"
        else
          assert result.entry.prediction == attrs.prediction
          assert result.entry.predicted_by == attrs.predicted_by
        end

        before = row_counts()

        for retry <- [outcome, if(outcome == "wait", do: "do", else: "wait")] do
          assert Goals.close_wake_up(c.coach, wake.id, retry, prediction(%{reason: "Again"})) ==
                   {:error, :wake_up_closed}

          assert row_counts() == before
        end

        result
      end

    assert Enum.map(results, & &1.entry.kind) == ~w(action ask wait)
    assert results |> Enum.map(& &1.entry.reading_id) |> Enum.uniq() |> length() == 3
    assert Repo.aggregate(from(e in Entry, where: e.goal_id == ^c.goal.id), :count) == 3
  end

  test "invalid outcome, missing predictions and blank wait leave the same wake-up open", c do
    wake = fire(c.goal)
    before = row_counts()

    for {outcome, attrs, reason} <- [
          {"invent", %{}, :unknown_outcome},
          {"do", %{title: "Work"}, :prediction_required},
          {"do", prediction(%{predicted_by: nil}), :prediction_required},
          {"ask", %{kind: "question", title: "Ask"}, :prediction_required},
          {"wait", %{reason: "  "}, :reason_required}
        ] do
      assert Goals.close_wake_up(c.coach, wake.id, outcome, attrs) == {:error, reason}
      assert row_counts() == before
      assert Repo.get!(WakeUp, wake.id).status == "open"
    end

    assert {:ok, _} = Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Need input"})
  end

  test "unanswered wake-up cannot be closed; cannot-measure outcome invents no reading", c do
    wake = fire(c.goal)
    assert is_nil(wake.reading_id)
    Clock.tick(wake.respond_by)
    before = row_counts()

    assert Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Too late"}) ==
             {:error, :wake_up_closed}

    assert row_counts() == before
    next = fire(c.goal)

    assert {:ok, result} =
             Goals.close_wake_up(c.coach, next.id, "wait", %{reason: "No measurement"})

    assert is_nil(result.entry.reading_id)
  end

  test "personal outcomes and task links hide existence and owners cannot coach", c do
    wake = fire(c.goal)

    for stranger <- [member!(c.org), root_admin!(), agent!()] do
      for id <- [wake.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert Goals.close_wake_up(stranger, id, "wait", %{reason: "x"}) == {:error, :not_found}
      end

      for id <- [c.goal.id, Ecto.UUID.generate()] do
        assert Goals.list_asks(stranger, id) == {:error, :not_found}
        assert Goals.list_goal_tasks(stranger, id) == {:error, :not_found}
        assert Goals.link_task(stranger, id, Ecto.UUID.generate()) == {:error, :not_found}
      end

      assert Goals.answer_ask(stranger, Ecto.UUID.generate(), "used") == {:error, :not_found}
    end

    assert Goals.close_wake_up(c.owner, wake.id, "wait", %{reason: "x"}) == {:error, :forbidden}
    assert Goals.link_task(c.owner, c.goal.id, Ecto.UUID.generate()) == {:error, :forbidden}
  end

  test "late invalid entry data rolls back an already-inserted ask or core task", c do
    project = project(c.org)
    wake = fire(c.goal)

    for {outcome, attrs} <- [
          {"ask", ask_attrs(%{predicted_change: "not-a-decimal"})},
          {"do",
           prediction(%{
             predicted_change: "not-a-decimal",
             task: %{
               "project_id" => project.id,
               "title" => "Work",
               "description" => "Useful work"
             }
           })}
        ] do
      before = row_counts()
      assert {:error, %Ecto.Changeset{}} = Goals.close_wake_up(c.coach, wake.id, outcome, attrs)
      assert row_counts() == before
      assert Repo.get!(WakeUp, wake.id).status == "open"
    end

    assert {:ok, result} =
             Goals.close_wake_up(c.coach, wake.id, "wait", %{
               reason: "Wait until ready",
               until: ~D[2026-03-01]
             })

    assert result.entry.details["until"] == "2026-03-01"
  end

  test "a prediction must be dated after the injected current day", c do
    wake = fire(c.goal)
    today = DateTime.to_date(Clock.now())
    before = row_counts()

    for date <- [today, Date.add(today, -1)] do
      assert Goals.close_wake_up(c.coach, wake.id, "do", prediction(%{predicted_by: date})) ==
               {:error, :prediction_required}

      assert row_counts() == before
      assert Repo.get!(WakeUp, wake.id).status == "open"
    end
  end
end

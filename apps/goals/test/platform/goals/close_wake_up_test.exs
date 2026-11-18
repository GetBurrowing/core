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

  # ── coach change (task 01a1eab7 stage 1) ──────────────────────────────────
  #
  # The ticket expected the old coach to get :forbidden. On a PERSONAL goal
  # it gets :not_found instead: `editable_wake/2` reads through
  # `Visibility.visible_goals(%Agent{})`, so an agent that is no longer the
  # coach no longer sees the goal at all. It gets :forbidden only while it
  # still sees the goal through a space grant (`check_coach/2`).

  defp new_coach!(owner) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: owner.id,
        runtime_id: "goal-new-coach-#{unique()}",
        display_name: "Goals new coach",
        status: "active"
      })

    agent!()
    |> Ecto.Changeset.change(runtime_type: "external", runtime_id: runtime.id)
    |> Repo.update!()
    |> grant_goals_tools!()
  end

  test "after a coach change the new coach closes the check-in; the old one gets :not_found",
       c do
    wake = fire(c.goal)
    b = new_coach!(c.owner)

    assert {:ok, updated} = Goals.update_goal(c.owner, c.goal.id, %{coach_agent_id: b.id})
    assert updated.coach_agent_id == b.id
    assert updated.kind == "personal"
    before = row_counts()

    assert Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Old coach"}) ==
             {:error, :not_found}

    assert row_counts() == before
    assert Repo.get!(WakeUp, wake.id).status == "open"

    assert {:ok, result} = Goals.close_wake_up(b, wake.id, "wait", %{reason: "New coach"})
    assert result.wake_up.status == "closed"
    assert result.entry.body == "New coach"
  end

  test "the old coach that still sees the goal through a space grant gets :forbidden", c do
    space = space!(c.org)
    join_space!(space.id, :user, c.owner.id)
    join_space!(space.id, :agent, c.coach.id)
    assert {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, space.id})

    wake = fire(c.goal)
    b = new_coach!(c.owner)
    assert {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{coach_agent_id: b.id})

    # The old coach still sees the goal, through the space.
    assert {:ok, _} = Goals.get_goal(c.coach, c.goal.id)
    before = row_counts()

    assert Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Old coach"}) ==
             {:error, :forbidden}

    assert row_counts() == before
    assert Repo.get!(WakeUp, wake.id).status == "open"

    assert {:ok, _} = Goals.close_wake_up(b, wake.id, "wait", %{reason: "New coach"})
    assert Repo.get!(WakeUp, wake.id).status == "closed"
  end
end

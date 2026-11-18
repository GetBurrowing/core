defmodule PlatformWeb.GoalsFlashCardsTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.{AskAnswer, Clock, Reading}
  alias Platform.Repo

  defmodule Recorder do
    def fan_out_to_user(id, payload) do
      send(self(), {:practice_brief, id, payload})
      :ok
    end
  end

  setup do
    c = setup_outcome()
    c
  end

  defp build do
    Platform.Memory.Insights.Disseminator.run(now: Clock.now(), notifications_module: Recorder)
  end

  defp open(conn, user) do
    live(Plug.Test.init_test_session(conn, current_user_id: user.id), "/inbox/briefing/#{date()}")
  end

  defp deck(ask), do: "[data-role=goals-flash-cards][data-ask-id='#{ask.id}']"
  defp flash_action(ask, name), do: deck(ask) <> " [data-action='#{name}']"

  defp play(view, ask, marks) do
    for mark <- marks do
      view |> element(flash_action(ask, "flip")) |> render_click()
      view |> element(flash_action(ask, mark)) |> render_click()
    end
  end

  defp practice(c, n \\ 5, attrs \\ %{}) do
    queued(c, Map.merge(%{kind: "practice", payload: %{"cards" => cards(n)}}, attrs))
  end

  defp six_day_goal(c) do
    {:ok, goal} =
      Goals.update_goal(c.owner, c.goal.id, %{agent_mode: "coach", unit: "words", retro_every: 60})

    c = %{c | goal: goal}

    for _ <- 1..6 do
      ask = practice(c)
      {:ok, _} = Goals.record_practice(c.owner, ask.id, results([0, 1, 2, 3, 4], []))
    end

    {:ok, _} = Goals.log_reading(c.owner, goal.id, %{value: 180, measured_at: Clock.now()})
    {c, practice(c)}
  end

  test "five cards play inside the brief, persist ordered results, readings and streak, then retry only misses",
       c do
    {c, ask} = six_day_goal(c)
    build()
    {:ok, view, _} = open(c.conn, c.owner)
    assert has_element?(view, "[data-role=goals-brief-card]", "6-day streak")
    assert has_element?(view, deck(ask), "Card 1 of 5")
    assert has_element?(view, deck(ask), "Front 0")
    refute has_element?(view, deck(ask), "Back 0")
    view |> element(deck(ask) <> " [data-role=flash-card]") |> render_keydown(%{"key" => "Enter"})
    assert has_element?(view, deck(ask), "Back 0")
    assert has_element?(view, flash_action(ask, "missed"), "Missed it")
    assert has_element?(view, flash_action(ask, "got"), "Got it")
    view |> element(flash_action(ask, "got")) |> render_click()
    play(view, ask, ["got", "missed", "got", "missed"])
    assert has_element?(view, deck(ask), "Done for today: 3 of 5")
    assert has_element?(view, deck(ask), "That makes 183 words.")
    assert has_element?(view, deck(ask), "7 days in a row.")
    assert has_element?(view, "[data-role=goals-brief-card]", "7-day streak")
    assert has_element?(view, flash_action(ask, "retry"), "Practise the 2 you missed")
    assert render(view) =~ "1 of 1 handled"
    {:ok, asks} = Goals.list_asks(c.owner, c.goal.id)
    stored = Enum.find(asks, &(&1.id == ask.id))
    assert [%{answer: "used", details: details}] = stored.answers

    assert Enum.map(details["cards"], &{&1["index"], &1["result"]}) == [
             {0, "got"},
             {1, "got"},
             {2, "missed"},
             {3, "got"},
             {4, "missed"}
           ]

    assert {:ok, {:reading, %{latest: latest}}} = Goals.goal_number(c.owner, c.goal.id)
    assert Decimal.equal?(latest.value, 183)
    assert latest.origin == "practice"
    assert {:ok, 7} = Goals.practice_streak(c.owner, c.goal.id, today: date())
    before = Repo.aggregate(Reading, :count)
    view |> element(flash_action(ask, "retry")) |> render_click()
    assert has_element?(view, deck(ask), "Front 2")
    assert has_element?(view, deck(ask), "Card 1 of 2")
    play(view, ask, ["got", "got"])
    assert has_element?(view, deck(ask), "Done for today: 5 of 5")
    assert has_element?(view, deck(ask), "That makes 185 words.")
    refute has_element?(view, flash_action(ask, "retry"))
    assert Repo.aggregate(Reading, :count) == before + 1
    {:ok, {:reading, %{latest: latest}}} = Goals.goal_number(c.owner, c.goal.id)
    assert Decimal.equal?(latest.value, 185)
    {:ok, asks} = Goals.list_asks(c.owner, c.goal.id)
    assert [%{details: details}] = Enum.find(asks, &(&1.id == ask.id)).answers
    assert Enum.all?(details["cards"], &(&1["result"] == "got"))
  end

  test "leaving mid-pass writes nothing and a reload starts the pass again", c do
    ask = practice(c, 2)
    build()
    {:ok, view, _} = open(c.conn, c.owner)
    view |> element(deck(ask) <> " [data-role=flash-card]") |> render_keydown(%{"key" => " "})
    view |> element(flash_action(ask, "got")) |> render_click()
    assert has_element?(view, deck(ask), "Front 1")
    assert Repo.aggregate(AskAnswer, :count) == 0
    assert Repo.aggregate(Reading, :count) == 0
    {:ok, reloaded, _} = open(c.conn, c.owner)
    assert has_element?(reloaded, deck(ask), "Front 0")
    assert has_element?(reloaded, deck(ask), "Card 1 of 2")
    refute has_element?(reloaded, flash_action(ask, "got"))
  end

  test "an addressed non-owner records results without changing the owner's number", c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{agent_mode: "coach", retro_every: 60})
    reader = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, goal.id, {:user, reader.id})
    ask = practice(%{c | goal: goal}, 1, %{addressed_user_ids: [reader.id]})
    build()
    {:ok, view, _} = open(c.conn, reader)
    play(view, ask, ["got"])
    assert [%{user_id: id, answer: "used"}] = Repo.all(AskAnswer)
    assert id == reader.id
    assert Repo.aggregate(Reading, :count) == 0
    assert has_element?(view, deck(ask), "Done for today: 1 of 1")
    refute has_element?(view, deck(ask), "That makes")
  end

  test "a task-count goal has no logged number sentence and a do-mode card has no streak", c do
    goal =
      goal!(c.owner, c.org, %{
        coach_agent_id: c.coach.id,
        agent_mode: "do",
        outreach: "pushy",
        source_key: "task_count",
        source_config: %{"statuses" => ["done"]}
      })

    ask = practice(%{c | goal: goal}, 1)
    build()
    {:ok, view, _} = open(c.conn, c.owner)
    refute has_element?(view, "[data-role=goals-brief-card]", "streak")
    play(view, ask, ["got"])
    assert Repo.aggregate(Reading, :count) == 0
    assert has_element?(view, deck(ask), "Done for today: 1 of 1")
    refute has_element?(view, deck(ask), "That makes")
    refute has_element?(view, "[data-role=goals-brief-card]", "streak")
  end

  test "Goals 9: revoking goals.use in the middle of a pass refuses the mark without a remount",
       c do
    ask = practice(c, 2)
    build()
    {:ok, view, _} = open(c.conn, c.owner)
    view |> element(flash_action(ask, "flip")) |> render_click()
    assert has_element?(view, deck(ask), "Front 0")

    # No remount and no access push: the deck learns from its own next call.
    revoke_goals_use!(c.owner, push: false)
    view |> element(flash_action(ask, "got")) |> render_click()
    refute has_element?(view, deck(ask))
    # The first refused click also takes the practice card around the deck
    # (its goal title and "made today's" line) off the page.
    html = render(view)
    refute has_element?(view, "[data-role=goals-brief-card]")
    refute html =~ "made today's"
    refute html =~ "Your goals"
    refute html =~ c.goal.title

    # The deck left the page with its card; any of its events still
    # reaching it are refused the same way.
    for event <- ["flip", "got", "missed"],
        has_element?(view, "[data-role=goals-flash-cards]"),
        do: view |> with_target("[data-role=goals-flash-cards]") |> render_click(event, %{})

    assert Repo.aggregate(AskAnswer, :count) == 0
    assert Repo.aggregate(Reading, :count) == 0
    refute render(view) =~ "Front 0"
    refute render(view) =~ "Back 0"
  end

  test "revoked visibility in the middle of a pass hides the deck and refuses the last mark", c do
    reader = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    ask = practice(c, 1, %{addressed_user_ids: [reader.id]})
    build()
    {:ok, view, _} = open(c.conn, reader)
    view |> element(flash_action(ask, "flip")) |> render_click()
    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:user, reader.id})
    view |> element(flash_action(ask, "got")) |> render_click()
    assert Repo.aggregate(AskAnswer, :count) == 0
    assert Repo.aggregate(Reading, :count) == 0
    refute has_element?(view, deck(ask), "Front 0")
    refute has_element?(view, deck(ask), "Back 0")
  end
end

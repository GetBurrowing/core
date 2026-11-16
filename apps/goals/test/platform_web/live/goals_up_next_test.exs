defmodule PlatformWeb.GoalsUpNextTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.Clock

  setup do
    c = setup_outcome()
    grant!(c.owner, c.org)
    c
  end

  defp grant!(user, org) do
    {:ok, _} =
      Platform.Access.Grants.grant(%{
        principal: user,
        permission: "goals.use",
        resource: {:space, space!(org).id}
      })
  end

  defp open(conn, user, goal, suffix \\ "") do
    {:ok, parent, _} =
      live(
        Plug.Test.init_test_session(conn, current_user_id: user.id),
        "/m/goals?goal=#{goal.id}" <> suffix
      )

    find_live_child(parent, "ext-page-goals")
  end

  test "Up next shows each queued kind and uses the actual delivering briefing date", c do
    for {kind, payload, tag, link_text} <- [
          {"offer",
           %{"idea" => %{"why" => "Useful", "measure" => "A result", "steps" => ["First"]}},
           "Idea", "Look at the idea"},
          {"question", %{}, "Check-in", "Open the check-in"},
          {"practice", %{"cards" => cards()}, "Practice", "Open your briefing"},
          {"offer", %{"draft" => "An outline"}, "Offer", "Open your briefing"}
        ] do
      goal =
        goal!(c.owner, c.org, %{
          title: "Next #{tag}",
          coach_agent_id: c.coach.id,
          rhythm: "daily",
          outreach: "pushy"
        })

      ask =
        queued(%{c | goal: goal}, %{
          kind: kind,
          title: "Queued #{tag}",
          body: "A useful next step",
          payload: payload
        })

      delivering_date = date()
      {:ok, _} = Goals.prepare_brief(c.owner, delivering_date)
      expected_kind = if tag == "Idea", do: "idea", else: kind
      child = open(c.conn, c.owner, goal)
      selector = "[data-role=goal-up-next][data-kind='#{expected_kind}']"
      assert has_element?(child, selector, tag)
      assert has_element?(child, selector <> " a", link_text)

      case expected_kind do
        "idea" ->
          assert has_element?(child, selector, "#{c.coach.name} has a new idea to try.")

          assert has_element?(
                   child,
                   selector <> " a[href='/m/goals?goal=#{goal.id}&idea=#{ask.id}']"
                 )

        "question" ->
          assert has_element?(
                   child,
                   selector,
                   "#{c.coach.name} drafted it. See what moved, and choose what to change."
                 )

          assert has_element?(
                   child,
                   selector <> " a[href='/m/goals?goal=#{goal.id}&check=#{ask.id}']"
                 )

        "practice" ->
          assert has_element?(child, selector, "Today's 5 cards are in your briefing")
          assert has_element?(child, selector <> " a[href='/inbox/briefing/#{delivering_date}']")

        "offer" ->
          assert has_element?(child, selector, ask.title)
          assert has_element?(child, selector, ask.body)
          assert has_element?(child, selector <> " a[href='/inbox/briefing/#{delivering_date}']")
      end
    end

    caught =
      goal!(c.owner, c.org, %{
        title: "No queued work",
        coach_agent_id: c.coach.id,
        rhythm: "daily"
      })

    :ok = Clock.tick(Clock.now())
    child = open(c.conn, c.owner, caught)

    assert has_element?(
             child,
             "[data-role=goal-up-next][data-kind=caught-up]",
             "You're all caught up"
           )

    assert has_element?(child, "[data-role=goal-up-next]", "The next check-in is ready on")
    refute render(child) =~ "Preview the retro"
  end

  test "the briefing note appears only for the from=brief address", c do
    child = open(c.conn, c.owner, c.goal)
    refute has_element?(child, "[data-role=goal-brief-note]")
    child = open(c.conn, c.owner, c.goal, "&from=brief")

    assert has_element?(
             child,
             "[data-role=goal-brief-note]",
             "You came here from today's briefing."
           )

    child = open(c.conn, c.owner, c.goal, "&from=elsewhere")
    refute has_element?(child, "[data-role=goal-brief-note]")
  end

  test "the notebook labels used, declined and ignored answers on their own ask entries", c do
    used = queued(c, %{kind: "offer", title: "Used offer"})
    {:ok, _} = Goals.answer_ask(c.owner, used.id, "used")
    declined = queued(c, %{kind: "offer", title: "Declined offer"})
    {:ok, _} = Goals.answer_ask(c.owner, declined.id, "declined")
    ignored = queued(c, %{kind: "offer", title: "Unanswered offer"})
    {:ok, _} = Goals.prepare_brief(c.owner, date())
    {:ok, %{ignored: 1}} = Goals.prepare_brief(c.owner, advance())
    child = open(c.conn, c.owner, c.goal)

    for {ask, label} <- [{used, "Used"}, {declined, "Not now"}, {ignored, "No answer"}] do
      assert has_element?(
               child,
               "[data-role=goal-notebook-entry][data-ask-id='#{ask.id}'] [data-role=goal-answer]",
               "#{c.owner.name}: #{label}"
             )
    end
  end

  test "the notebook shows real practice results and streak while another viewer sees only addressed answers",
       c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{agent_mode: "coach", unit: "words"})
    c = %{c | goal: goal}

    for _day <- 1..6 do
      ask = queued(c, %{kind: "practice", payload: %{"cards" => cards()}})
      {:ok, _} = Goals.record_practice(c.owner, ask.id, results([0, 1, 2, 3, 4], []))
    end

    {:ok, _} = Goals.log_reading(c.owner, goal.id, %{value: 180, measured_at: Clock.now()})

    ask =
      queued(c, %{
        kind: "practice",
        title: "Today's private practice",
        payload: %{"cards" => cards()}
      })

    {:ok, _} = Goals.record_practice(c.owner, ask.id, results([0, 1, 3], [2, 4]))
    child = open(c.conn, c.owner, goal)

    assert has_element?(
             child,
             "[data-role=goal-notebook-entry][data-ask-id='#{ask.id}'] [data-role=goal-answer]",
             "#{c.owner.name}: 3 of 5 cards"
           )

    assert has_element?(child, "[data-role=goal-notebook]", "7-day streak")

    assert has_element?(
             child,
             "[data-role=goal-up-next][data-kind=caught-up]",
             "You're all caught up"
           )

    assert {:ok, 7} = Goals.practice_streak(c.owner, goal.id, today: date())

    viewer = member!(c.org)
    grant!(viewer, c.org)
    {:ok, _} = Goals.open_goal(c.owner, goal.id, {:user, viewer.id})
    assert {:ok, []} = Goals.list_asks(viewer, goal.id)
    child = open(c.conn, viewer, goal)
    refute has_element?(child, "[data-role=goal-answer]")
    refute has_element?(child, "[data-role=goal-notebook]", "7-day streak")
    refute has_element?(child, "[data-role=goal-up-next]", "Today's private practice")
  end
end

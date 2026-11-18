defmodule PlatformWeb.GoalsCheckInTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.Clock

  defmodule Recorder do
    def fan_out_to_user(_, _), do: :ok
  end

  setup do
    c = setup_brief()

    c
  end

  defp open(conn, owner, goal, ask) do
    {:ok, parent, _} =
      live(
        Plug.Test.init_test_session(conn, current_user_id: owner.id),
        "/m/goals?goal=#{goal.id}&check=#{ask.id}"
      )

    find_live_child(parent, "ext-page-goals")
  end

  defp answers(c, ask) do
    {:ok, stored} = Goals.get_ask(c.owner, ask.id)
    stored.answers
  end

  defp fixture(c) do
    {:ok, takeaway} =
      Goals.add_entry(c.coach, c.goal.id, %{
        kind: "takeaway",
        title: "What viewers ask",
        sources: [%{"name" => "Notes"}],
        occurred_at: Clock.now()
      })

    ask =
      queued(c, %{
        title: "Choose the next three changes",
        body: "Here is what happened this week.",
        payload: %{
          "moved" => [
            %{"direction" => "up", "text" => "More viewers arrived"},
            %{"direction" => "down", "text" => "Long videos lost viewers"}
          ],
          "suggestions" => [
            %{
              "title" => "Make a short fix",
              "why" => "Answer one clear question",
              "takeaway_id" => takeaway.id
            },
            %{"title" => "Keep the weekly recap", "why" => "Keep a useful habit"},
            %{"title" => "Try a new thumbnail", "why" => "See what gets noticed"}
          ]
        }
      })

    {:ok, _} =
      Platform.Memory.Insights.Disseminator.run(now: Clock.now(), notifications_module: Recorder)

    {ask, takeaway}
  end

  test "the full check-in records choices only on Finish, reloads done and reaches the coach",
       c do
    assert PlatformWeb.GoalsCheckIn.weekday(~U[2026-11-16 01:00:00Z], "America/Los_Angeles") ==
             "Sunday"

    {ask, takeaway} = fixture(c)
    child = open(c.conn, c.owner, c.goal, ask)
    assert has_element?(child, "[data-role=goals-check-in]")
    assert has_element?(child, "a[href='/m/goals?goal=#{c.goal.id}']", "‹ #{c.goal.title}")

    for text <- [
          "Check-in",
          ask.title,
          "Drafted by #{c.coach.name}",
          "Here is what happened this week.",
          "What moved",
          "↑",
          "More viewers arrived",
          "↓",
          "Long videos lost viewers",
          "#{c.coach.name} suggests · 3",
          "Make a short fix",
          "Answer one clear question",
          "Keep the weekly recap",
          "Try a new thumbnail",
          "Finish check-in",
          "Your choices update the plan. Nothing changes until you finish."
        ] do
      assert render(child)
             |> Floki.parse_fragment!()
             |> Floki.text()
             |> String.replace(~r/\s+/u, " ") =~ text
    end

    assert has_element?(
             child,
             "a[href='/m/goals?goal=#{c.goal.id}&read=#{takeaway.id}']",
             "From: #{takeaway.title}"
           )

    assert length(
             child
             |> element("[data-role=goals-check-in]")
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.find("[data-action=check-choice]")
           ) == 6

    assert answers(c, ask) == []
    refute has_element?(child, "[data-action=check-choice][aria-pressed=true]")

    child
    |> element("[data-action=check-choice][phx-value-index='0'][phx-value-choice='do']")
    |> render_click()

    child
    |> element("[data-action=check-choice][phx-value-index='1'][phx-value-choice='not_now']")
    |> render_click()

    assert has_element?(
             child,
             "[data-action=check-choice][phx-value-index='0'][aria-pressed=true]"
           )

    assert has_element?(
             child,
             "[data-action=check-choice][phx-value-index='1'][aria-pressed=true]"
           )

    assert has_element?(
             child,
             "[data-action=check-choice][phx-value-index='2'][aria-pressed=false]"
           )

    assert answers(c, ask) == []
    child |> element("[data-action=check-finish]") |> render_click()
    assert [%{answer: "used", details: %{"choices" => choices}}] = answers(c, ask)

    assert choices == [
             %{"index" => 0, "choice" => "do"},
             %{"index" => 1, "choice" => "not_now"},
             %{"index" => 2, "choice" => "not_now"}
           ]

    assert has_element?(child, "[data-role=goals-check-done]", "Your choices are in.")

    for line <- [
          "Check-in done",
          "Do it: Make a short fix",
          "Not now: Keep the weekly recap",
          "Not now: Try a new thumbnail",
          "Back to the goal"
        ] do
      assert has_element?(child, "[data-role=goals-check-done]", line)
    end

    assert has_element?(child, "[data-role=goals-check-done]", c.coach.name)
    assert {:ok, %{total: 1, open: 0}} = Goals.brief_summary(c.owner, date())
    brief = Platform.Memory.Insights.Briefings.for_user_on(c.owner.id, date())
    view = Platform.Memory.Insights.Briefings.view(brief, Platform.Access.Scope.for_user(c.owner))
    assert %{handled: 1, open: 0} = view.counts
    before = answers(c, ask)
    render_click(child, "check_finish", %{})
    assert answers(c, ask) == before
    reloaded = open(c.conn, c.owner, c.goal, ask)
    assert has_element?(reloaded, "[data-role=goals-check-done]", "Your choices are in.")
    refute has_element?(reloaded, "[data-action=check-finish]")
    wake = fire(c.goal)
    {:ok, %{briefing: briefing, text: text}} = Goals.get_wake_up(c.coach, wake.id)

    assert Enum.any?(
             briefing["since_last"]["answers"],
             &(&1["ask_id"] == ask.id and &1["details"]["choices"] == choices)
           )

    assert text =~ "Make a short fix"
    assert text =~ "not_now"
  end

  # Task 01a1ecb3 stage 1: the open check-in renders inside the detail pane,
  # which pads its end clear of the phone's glass rail.
  test "an open check-in sits in the detail pane that clears the bottom rail", c do
    {ask, _takeaway} = fixture(c)
    child = open(c.conn, c.owner, c.goal, ask)

    assert has_element?(
             child,
             "[data-role=goals-detail-pane].clears-tab-bar [data-role=goals-check-in]"
           )
  end

  test "all suggestions declined and an empty check-in are both recorded correctly", c do
    {ask, _} = fixture(c)
    child = open(c.conn, c.owner, c.goal, ask)

    for i <- 0..2,
        do:
          render_click(child, "check_choice", %{
            "index" => Integer.to_string(i),
            "choice" => "not_now"
          })

    child |> element("[data-action=check-finish]") |> render_click()
    assert [%{answer: "declined"}] = answers(c, ask)
    empty = queued(c, %{title: "A simple check-in"})
    child = open(c.conn, c.owner, c.goal, empty)
    refute has_element?(child, "[data-action=check-choice]")
    child |> element("[data-action=check-finish]") |> render_click()
    assert [%{answer: "used", details: %{"choices" => []}}] = answers(c, empty)
  end

  test "foreign, wrongly typed, unaddressed, missing and malformed asks share the hidden goal 404",
       c do
    other =
      goal!(c.owner, c.org, %{coach_agent_id: c.coach.id, rhythm: "daily", outreach: "pushy"})

    foreign = queued(%{c | goal: other})
    offer = queued(c, %{kind: "offer"})
    viewer = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, viewer.id})
    unaddressed = queued(c, %{addressed_user_ids: [viewer.id]})
    conn = Plug.Test.init_test_session(c.conn, current_user_id: c.owner.id)

    {404, _, hidden_body} =
      assert_error_sent(404, fn -> get(conn, "/m/goals?goal=#{Ecto.UUID.generate()}") end)

    for id <- [foreign.id, offer.id, unaddressed.id, Ecto.UUID.generate(), "not-a-uuid"] do
      {404, _, body} =
        assert_error_sent(404, fn -> get(conn, "/m/goals?goal=#{c.goal.id}&check=#{id}") end)

      assert body == hidden_body
    end
  end
end

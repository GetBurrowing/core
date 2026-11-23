defmodule PlatformWeb.GoalsCheckInTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
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

  # ── the reply box (task 01a20939 stage 3) ─────────────────────────────────

  # An eligible external coach, so a reply's goals.reply signal reaches the
  # captured dispatcher.
  defp reply_setup(c) do
    previous = Application.fetch_env(:goals, :wake_up_dispatcher)
    parent = self()

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:signal, signal})
      :ok
    end)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :wake_up_dispatcher, value)
        :error -> Application.delete_env(:goals, :wake_up_dispatcher)
      end
    end)

    coach = coach_agent!(c.owner)
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{coach_agent_id: coach.id})
    %{c | coach: coach, goal: goal}
  end

  defp reply_signals do
    receive do
      {:signal, %{metadata: %{responsibility_key: "goals.reply"}} = s} -> [s | reply_signals()]
      {:signal, _} -> reply_signals()
    after
      0 -> []
    end
  end

  defp goal_messages(goal) do
    case Platform.Repo.get!(Platform.Goals.Goal, goal.id).conversation_space_id do
      nil ->
        []

      space_id ->
        Platform.Repo.all(
          from(m in Platform.Chat.Message,
            where: m.space_id == ^space_id,
            order_by: m.inserted_at
          )
        )
    end
  end

  defp type_reply(child, text),
    do: child |> element("#goal-check-in-reply-form") |> render_change(%{"reply" => text})

  test "finish with a reply records the choices, posts once, wakes the coach once, shows the excerpt",
       c do
    c = reply_setup(c)
    ask = queued(c, %{title: "Which days work?"})
    reply_signals()
    child = open(c.conn, c.owner, c.goal, ask)

    assert has_element?(
             child,
             "textarea[data-role=goal-check-in-reply][aria-label='Your reply to #{c.coach.name}'][maxlength='#{Platform.Goals.Limits.max_question_chars()}'][rows='5']"
           )

    refute has_element?(child, "textarea[data-role=goal-check-in-reply][required]")

    assert has_element?(
             child,
             "#goal-check-in-reply-hint",
             "Optional. Your reply goes to this goal's conversation, and #{c.coach.name} reads it straight away."
           )

    type_reply(child, "  Tuesdays work. Saturdays are out.  ")
    child |> element("[data-action=check-finish]") |> render_click()

    assert [%{answer: "used"}] = answers(c, ask)
    # Ryan's condition (2026-11-23): "a reply box is fine as long as the
    # conversation from that reply box finds its way to the goal space".
    # goal_messages/1 reads the goal's own conversation_space_id space.
    space_id = Platform.Repo.get!(Platform.Goals.Goal, c.goal.id).conversation_space_id
    assert is_binary(space_id)
    assert [msg] = goal_messages(c.goal)
    assert msg.space_id == space_id
    assert msg.content == "Tuesdays work. Saturdays are out."
    assert msg.metadata["source"] == "goals.reply"
    assert msg.metadata["ask_id"] == ask.id
    assert [_one] = reply_signals()

    assert has_element?(
             child,
             "[data-role=goal-check-in-replied] .line-clamp-2",
             "You replied: Tuesdays work. Saturdays are out."
           )

    assert has_element?(
             child,
             "[data-role=goal-check-in-talk][href='/m/goals?goal=#{c.goal.id}&talk=1']",
             "Conversation with #{c.coach.name}"
           )

    refute has_element?(child, "[data-role=goal-check-in-reply]")

    # A repeat Finish posts nothing more; a reload still shows the excerpt.
    render_click(child, "check_finish", %{})
    assert length(goal_messages(c.goal)) == 1
    assert reply_signals() == []
    reloaded = open(c.conn, c.owner, c.goal, ask)
    assert has_element?(reloaded, "[data-role=goal-check-in-replied]", "You replied:")
  end

  test "a blank or whitespace reply posts nothing and records the choices as before", c do
    c = reply_setup(c)

    for text <- ["", "   \n\t "] do
      ask = queued(c, %{title: "A check-in #{inspect(text)}"})
      reply_signals()
      child = open(c.conn, c.owner, c.goal, ask)
      type_reply(child, text)
      child |> element("[data-action=check-finish]") |> render_click()

      assert [%{answer: "used", details: %{"choices" => []}}] = answers(c, ask)
      assert has_element?(child, "[data-role=goals-check-done]", "Your choices are in.")
      refute has_element?(child, "[data-role=goal-check-in-reply-error]")
      refute has_element?(child, "[data-role=goal-check-in-replied]")
    end

    assert goal_messages(c.goal) == []
    assert reply_signals() == []
  end

  test "an addressee who is not the owner keeps the choices but gets no reply box", c do
    c = reply_setup(c)
    viewer = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, viewer.id})
    ask = queued(c, %{addressed_user_ids: [viewer.id]})
    child = open(c.conn, viewer, c.goal, ask)

    assert has_element?(child, "[data-action=check-finish]")
    refute has_element?(child, "[data-role=goal-check-in-reply]")
    refute has_element?(child, "#goal-check-in-reply-form")

    render_change(child, "check_reply", %{"reply" => "From the viewer"})
    child |> element("[data-action=check-finish]") |> render_click()
    assert [%{answer: "used"}] = answers(%{c | owner: viewer}, ask)
    assert goal_messages(c.goal) == []
  end

  test "a failed send keeps the text and the choices and shows one error line; Finish retries",
       c do
    c = reply_setup(c)
    ask = queued(c, %{title: "Which days work?"})
    reply_signals()
    child = open(c.conn, c.owner, c.goal, ask)
    too_long = String.duplicate("x", Platform.Goals.Limits.max_question_chars() + 1)

    type_reply(child, too_long)
    child |> element("[data-action=check-finish]") |> render_click()

    assert [%{answer: "used"}] = answers(c, ask)

    assert has_element?(
             child,
             "[data-role=goal-check-in-reply-error][role=alert]",
             "Couldn't send. Your reply and choices are still here. Try again."
           )

    assert child |> element("textarea[data-role=goal-check-in-reply]") |> render() =~ too_long
    refute has_element?(child, "[data-role=goals-check-done]")
    assert goal_messages(c.goal) == []

    type_reply(child, "Tuesdays work.")
    child |> element("[data-action=check-finish]") |> render_click()

    assert [%{answer: "used"}] = answers(c, ask)
    assert [%{content: "Tuesdays work."}] = goal_messages(c.goal)
    assert [_one] = reply_signals()
    assert has_element?(child, "[data-role=goals-check-done]")
    refute has_element?(child, "[data-role=goal-check-in-reply-error]")
  end
end

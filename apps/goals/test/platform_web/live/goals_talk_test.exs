defmodule PlatformWeb.GoalsTalkTest do
  @moduledoc """
  The goal's conversation screen (task 01a20939 stage 4), `?goal=<id>&talk=1`
  in GoalsLive. Signals are captured through the injectable
  `:wake_up_dispatcher`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures, only: [fire: 1, ask_attrs: 1]

  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.Goal
  alias Platform.Repo

  setup do
    enable_goals!()
    old = Map.new([:clock_now, :wake_up_dispatcher], &{&1, Application.fetch_env(:goals, &1)})
    parent = self()

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:signal, signal})
      :ok
    end)

    on_exit(fn ->
      for {key, previous} <- old do
        case previous do
          {:ok, value} -> Application.put_env(:goals, key, value)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end)

    org = org_id!()
    owner = member!(org)
    coach = coach_agent!(owner)

    goal =
      goal!(owner, org, %{
        coach_agent_id: coach.id,
        title: "Take an acting class",
        rhythm: "daily",
        outreach: "pushy"
      })

    %{org: org, owner: owner, coach: coach, goal: goal}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp open(conn, user, goal) do
    {:ok, parent, _} =
      live(
        Plug.Test.init_test_session(conn, current_user_id: user.id),
        "/m/goals?goal=#{goal.id}&talk=1"
      )

    find_live_child(parent, "ext-page-goals")
  end

  defp squash(html),
    do: html |> Floki.parse_fragment!() |> Floki.text() |> String.replace(~r/\s+/u, " ")

  defp space_id(goal), do: Repo.get!(Goal, goal.id).conversation_space_id

  defp messages(goal) do
    case space_id(goal) do
      nil -> []
      id -> Repo.all(from(m in Chat.Message, where: m.space_id == ^id, order_by: m.inserted_at))
    end
  end

  defp reply_signals do
    receive do
      {:signal, %{metadata: %{responsibility_key: "goals.reply"}} = s} -> [s | reply_signals()]
      {:signal, _} -> reply_signals()
    after
      0 -> []
    end
  end

  defp coach_says(goal, coach, text) do
    space_id = space_id(goal)
    row = Chat.get_agent_participant(space_id, coach.id)

    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: row.id,
        content_type: "text",
        content: text
      })

    msg
  end

  defp position(html, needle) do
    case :binary.match(html, needle) do
      {at, _} -> at
      :nomatch -> flunk("#{needle} not rendered")
    end
  end

  defp unread?(c) do
    {:ok, summary} = Goals.conversation_summary(c.owner, c.goal.id)
    summary.unread?
  end

  # ── the fold ──────────────────────────────────────────────────────────────

  test "the setup fold holds exactly the messages from before the goal was confirmed", c do
    lead = coach_agent!(c.owner)
    {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), lead.id)
    {:ok, proposal} = Goals.start_goal_conversation(c.owner, "SETUP-ONE run a class")
    row = Chat.get_agent_participant(proposal.space_id, lead.id)

    {:ok, _} =
      Chat.post_message(%{
        space_id: proposal.space_id,
        participant_id: row.id,
        content_type: "text",
        content: "SETUP-TWO which days?"
      })

    {:ok, _} = Goals.say_in_conversation(c.owner, proposal.id, "SETUP-THREE Tuesdays")

    {:ok, proposal} =
      Goals.propose_goal(lead, proposal.id, %{
        title: "Take an acting class",
        agent_mode: "coach",
        rhythm: "weekly",
        rhythm_weekday: 1,
        outreach: "gentle",
        ready: true
      })

    {:ok, %{goal: goal}} = Goals.confirm_proposal(c.owner, proposal.id, proposal.revision)
    {:ok, _} = Goals.say_in_goal(c.owner, goal.id, "AFTER-CONFIRM booked")

    child = open(c.conn, c.owner, goal)
    assert has_element?(child, "[data-role=goal-talk-fold]", "How this goal was set up")
    assert has_element?(child, "[data-role=goal-talk-fold]", "Show 3 messages")
    refute has_element?(child, "[data-role=goal-talk-setup-messages]")
    assert has_element?(child, "[data-role=goal-talk-thread]", "AFTER-CONFIRM booked")

    child |> element("[data-role=goal-talk-fold]") |> render_click()
    setup = child |> element("[data-role=goal-talk-setup-messages]") |> render() |> squash()

    for text <- ["SETUP-ONE", "SETUP-TWO", "SETUP-THREE"], do: assert(setup =~ text)
    refute setup =~ "AFTER-CONFIRM"
    assert has_element?(child, "[data-role=goal-talk-fold]", "Hide 3 messages")
  end

  # ── records ───────────────────────────────────────────────────────────────

  test "a check-in record shows the recorded choice, with the written reply directly under it",
       c do
    wake = fire(c.goal)

    {:ok, %{ask: ask}} =
      Goals.close_wake_up(
        c.coach,
        wake.id,
        "ask",
        ask_attrs(%{
          title: "What days would work?",
          payload: %{"suggestions" => [%{"title" => "Book a trial class"}]}
        })
      )

    {:ok, _} =
      Goals.answer_ask(c.owner, ask.id, "used", %{
        "choices" => [%{"index" => 0, "choice" => "do"}]
      })

    {:ok, _} = Goals.say_in_goal(c.owner, c.goal.id, "OPENING-WORDS hello")
    coach_says(c.goal, c.coach, "COACH-BETWEEN noted")
    {:ok, _} = Goals.say_in_goal(c.owner, c.goal.id, "REPLY-WORDS Tuesdays", ask_id: ask.id)

    child = open(c.conn, c.owner, c.goal)

    assert has_element?(
             child,
             "[data-role=goal-talk-record][data-record-id='#{ask.id}'][role=group]",
             "What days would work?"
           )

    assert has_element?(
             child,
             "[data-record-id='#{ask.id}'] [data-role=goal-talk-chose]",
             "You chose: Do it · Book a trial class"
           )

    html = render(child)
    record_at = position(html, "data-record-id=\"#{ask.id}\"")
    reply_at = position(html, "REPLY-WORDS")
    between_at = position(html, "COACH-BETWEEN")

    assert record_at < reply_at
    assert reply_at < between_at

    # Nothing but the record sits between it and its reply: the only
    # message wrapper opened in that stretch is the reply's own.
    between = binary_part(html, record_at, reply_at - record_at)
    assert length(String.split(between, "data-role=\"goal-talk-message\"")) == 2
  end

  # ── members ───────────────────────────────────────────────────────────────

  test "the members line comes from the space's members and follows a coach change", c do
    {:ok, _} = Goals.say_in_goal(c.owner, c.goal.id, "hello")
    child = open(c.conn, c.owner, c.goal)

    assert has_element?(
             child,
             "[data-role=goal-talk-members]",
             "You and #{c.coach.name} · private to this goal"
           )

    new_coach = coach_agent!(c.owner)
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{coach_agent_id: new_coach.id})
    child = open(c.conn, c.owner, c.goal)

    line = child |> element("[data-role=goal-talk-members]") |> render() |> squash()
    assert String.trim(line) == "You and #{new_coach.name} · private to this goal"
  end

  # ── sending ───────────────────────────────────────────────────────────────

  test "a send posts once and signals once; whitespace sends nothing", c do
    child = open(c.conn, c.owner, c.goal)
    reply_signals()

    child |> element("#goal-talk-composer") |> render_submit(%{"text" => "   \n "})
    assert messages(c.goal) == []
    assert reply_signals() == []

    child |> element("#goal-talk-composer") |> render_submit(%{"text" => "  Booked Tuesdays  "})
    assert [msg] = messages(c.goal)
    assert msg.content == "Booked Tuesdays"
    assert msg.metadata["source"] == "goals.reply"
    assert [_one] = reply_signals()

    assert has_element?(
             child,
             "[data-role=goal-talk-message][data-from=person]",
             "Booked Tuesdays"
           )

    refute has_element?(child, "[data-role=goal-talk-send-error]")
  end

  test "a failed send keeps the text and shows one error line", c do
    child = open(c.conn, c.owner, c.goal)
    too_long = String.duplicate("y", Platform.Goals.Limits.max_question_chars() + 1)

    child |> element("#goal-talk-composer") |> render_submit(%{"text" => too_long})

    assert has_element?(
             child,
             "[data-role=goal-talk-send-error][role=alert]",
             "Couldn't send. Your message is still here. Try again."
           )

    assert child |> element("[data-role=goal-talk-input]") |> render() =~ too_long
    assert messages(c.goal) == []
  end

  # ── changes ───────────────────────────────────────────────────────────────

  test "Apply changes the goal and Not now leaves it as it was; each shows its outcome", c do
    {:ok, apply_me} =
      Goals.propose_change(c.coach, c.goal.id, %{"rhythm" => "weekly", "rhythm_weekday" => 3})

    {:ok, skip_me} = Goals.propose_change(c.coach, c.goal.id, %{"outreach" => "off"}, "Quieter")
    child = open(c.conn, c.owner, c.goal)

    assert has_element?(
             child,
             "[data-entry-id='#{apply_me.id}']",
             "#{c.coach.name} proposes a change"
           )

    assert has_element?(child, "[data-entry-id='#{apply_me.id}']", "Check-in day: Wednesday")

    child
    |> element("[data-entry-id='#{apply_me.id}'] [data-action=goal-talk-apply]")
    |> render_click()

    goal = Repo.get!(Goal, c.goal.id)
    assert {goal.rhythm, goal.rhythm_weekday} == {"weekly", 3}

    assert has_element?(
             child,
             "[data-entry-id='#{apply_me.id}'] [data-role=goal-talk-change-outcome]",
             "Applied to the goal."
           )

    child
    |> element("[data-entry-id='#{skip_me.id}'] [data-action=goal-talk-dismiss]")
    |> render_click()

    assert Repo.get!(Goal, c.goal.id).outreach == "pushy"

    assert has_element?(
             child,
             "[data-entry-id='#{skip_me.id}'] [data-role=goal-talk-change-outcome]",
             "Not applied. Nothing changed."
           )

    refute has_element?(child, "[data-action=goal-talk-apply]")
  end

  # ── live ──────────────────────────────────────────────────────────────────

  test "a second open screen gets the coach's message live, and opening marks it read", c do
    {:ok, _} = Goals.say_in_goal(c.owner, c.goal.id, "first words")
    coach_says(c.goal, c.coach, "UNREAD-BEFORE open")
    assert unread?(c)

    one = open(c.conn, c.owner, c.goal)
    two = open(c.conn, c.owner, c.goal)
    refute unread?(c)

    coach_says(c.goal, c.coach, "LIVE-ARRIVAL logged it")
    assert render(one) =~ "LIVE-ARRIVAL logged it"
    assert render(two) =~ "LIVE-ARRIVAL logged it"
    refute unread?(c)

    # A record written elsewhere shows up live too.
    {:ok, _} = Goals.propose_change(c.coach, c.goal.id, %{"outreach" => "off"})
    assert render(one) =~ "proposes a change"
  end

  # ── access and the empty state ────────────────────────────────────────────

  test "a granted viewer and a stranger get the goal's not-found path", c do
    {:ok, _} = Goals.say_in_goal(c.owner, c.goal.id, "PRIVATE-WORDS")
    viewer = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, viewer.id})

    for user <- [viewer, member!(c.org)] do
      conn = Plug.Test.init_test_session(c.conn, current_user_id: user.id)

      {404, _, body} =
        assert_error_sent(404, fn -> get(conn, "/m/goals?goal=#{c.goal.id}&talk=1") end)

      refute body =~ "PRIVATE-WORDS"
    end
  end

  test "a goal with no space shows the empty state, and the composer creates the space", c do
    assert space_id(c.goal) == nil
    child = open(c.conn, c.owner, c.goal)

    assert has_element?(child, "[data-role=goal-talk-empty]", "No messages yet.")

    assert has_element?(
             child,
             "[data-role=goal-talk-empty]",
             "#{c.coach.name} gets anything you write here when you send it."
           )

    assert has_element?(
             child,
             "[data-role=goal-talk-input][aria-label='Message #{c.coach.name} about this goal']"
           )

    assert has_element?(
             child,
             "[data-role=goals-detail-pane].clears-tab-bar [data-role=goals-talk]"
           )

    child |> element("#goal-talk-composer") |> render_submit(%{"text" => "First words"})

    assert is_binary(space_id(c.goal))
    assert [%{content: "First words"}] = messages(c.goal)
    refute has_element?(child, "[data-role=goal-talk-empty]")
    assert has_element?(child, "[data-role=goal-talk-message]", "First words")

    # Its space is now subscribed: a coach message arrives live.
    coach_says(c.goal, c.coach, "LAZY-LIVE hello")
    assert render(child) =~ "LAZY-LIVE hello"
  end
end

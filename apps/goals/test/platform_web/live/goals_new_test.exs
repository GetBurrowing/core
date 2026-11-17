defmodule PlatformWeb.GoalsNewTest do
  @moduledoc """
  The New goal screen (task 01a1dfc1-7625, Goals 5/8 stage 3) against canvas
  01a15ef6 node `p` screen `create`. The agent is played by
  `Platform.Goals.ScriptedAgent`, which uses only the goals tools and core's
  public chat functions. Sets the global `:goals` env, so not async.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures

  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.ScriptedAgent
  alias Platform.Goals.Tools
  alias Platform.Repo

  @yt "I want How to Computer to be a big channel. Really big."
  @greeting "Hi Alex. What do you want to achieve? It can be anything. Say it however it comes to mind, and I'll help turn it into something we can steer by."
  @placeholder "For example: start a small woodworking business, run a half marathon by spring, or get our first 10 paying customers"

  setup do
    enable_goals!()
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

    org_id = org_id!()
    user = person!(org_id, "Alex Tester")
    {:ok, org_id: org_id, user: user}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp person!(org_id, name) do
    member!(org_id) |> Ecto.Changeset.change(name: name) |> Repo.update!()
  end

  defp lead!(owner) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: owner.id,
        runtime_id: "goals-new-#{unique()}",
        display_name: "Goals New test",
        status: "active"
      })

    agent =
      agent!()
      |> Ecto.Changeset.change(name: "Dalton", runtime_type: "external", runtime_id: runtime.id)
      |> Repo.update!()
      |> grant_goals_tools!()

    {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), agent.id)
    agent
  end

  defp open(conn, user, path \\ "/m/goals?new=1") do
    {:ok, view, _html} =
      live(Plug.Test.init_test_session(conn, current_user_id: user.id), path)

    find_live_child(view, "ext-page-goals")
  end

  defp texts(child, selector) do
    child
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find(selector)
    |> Enum.map(&(&1 |> Floki.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  defp goal_count, do: Repo.aggregate(Platform.Goals.Goal, :count)
  defp message_count, do: Repo.aggregate(Chat.Message, :count)

  defp proposal!(user) do
    {:ok, %{} = proposal} = Goals.current_proposal(user)
    proposal
  end

  defp send_text(child, text),
    do: child |> form("[data-role='goals-new-box']", %{"text" => text}) |> render_submit()

  defp turn!(lead, user, example) do
    {:ok, _turn} = ScriptedAgent.next_turn(lead, proposal!(user), example)
  end

  # The first reply is the default.
  defp tap_first!(child),
    do: child |> element("[data-role='goals-new-reply']:first-child") |> render_click()

  defp stop_texts(child) do
    child
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("[data-role='goals-new-journey'] [data-role='goal-stop']")
    |> Enum.map(&(&1 |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp propose!(lead, user, attrs) do
    {:ok, _} =
      Tools.execute(
        "goal_propose",
        Map.put(attrs, "proposal_id", proposal!(user).id),
        %{agent_id: lead.id}
      )
  end

  defp settled(child, setting),
    do: texts(child, "[data-role='goals-new-settled'][data-setting='#{setting}']")

  # A form control or chip that asks for a type or kind.
  defp type_controls(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(
      "input, select, textarea, button, [role='radio'], [data-role='goals-new-reply']"
    )
    |> Enum.filter(fn node ->
      attrs =
        for attr <- ~w(name aria-label id placeholder),
            value <- Floki.attribute(node, attr),
            do: value

      Enum.any?([Floki.text(node) | attrs], &Regex.match?(~r/\b(type|kind)\b/i, &1))
    end)
  end

  defp play_to_ready!(child, lead, user, example) do
    for _ <- 1..6 do
      turn!(lead, user, example)
      assert type_controls(render(child)) == []
      assert goal_count() == 0
      tap_first!(child)
    end

    turn!(lead, user, example)
  end

  # ── tests ─────────────────────────────────────────────────────────────────

  test "the New goal button and chip sit in member 4's slots and lead to ?new=1", %{
    conn: conn,
    user: user
  } do
    lead!(user)
    child = open(conn, user, "/m/goals")
    doc = child |> render() |> Floki.parse_fragment!()
    links = Floki.find(doc, "[data-goals-slot='new-goal'] a")

    assert length(Floki.find(doc, "[data-goals-slot='new-goal']")) == 2
    assert length(links) == 2
    assert Enum.all?(links, &(Floki.attribute(&1, "href") == ["/m/goals?new=1"]))
    assert Enum.map(links, &(&1 |> Floki.text() |> String.trim())) == ["New goal", "New goal"]
    assert Floki.find(doc, "[data-pane='goals'] [data-goals-slot] a.btn-primary") != []

    assert Floki.find(
             doc,
             "[data-role='goals-phone'] [data-goals-slot] a[data-role='goals-new-chip']"
           ) != []
  end

  test "before sending: header, greeting, box and examples; an example fills the box only", %{
    conn: conn,
    user: user
  } do
    lead!(user)
    child = open(conn, user)
    before = message_count()

    assert has_element?(child, "[data-role='goals-new'] h2", "New goal")

    assert texts(child, "[data-role='goals-new-meta']") == [
             "A conversation with Dalton. It can be anything."
           ]

    assert texts(child, "[data-role='goals-new-greeting'] .chat-markdown") == [@greeting]
    assert has_element?(child, "[data-role='goals-new-greeting'] .msg-agent-badge", "AI")

    assert has_element?(
             child,
             "input[aria-label='What do you want to achieve?'][placeholder='#{@placeholder}']"
           )

    assert has_element?(child, "[data-role='goals-new-send']", "Send")
    assert has_element?(child, "[data-role='goals-new-back']", "‹ Goals")
    assert has_element?(child, "[data-role='goals-new-examples']", "Try an example:")

    assert texts(child, "[data-role='goals-new-example']") == [
             "Grow How to Computer",
             "Learn Spanish"
           ]

    child |> element("[data-example='yt']") |> render_click()

    assert child
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.find("input[name='text']")
           |> Floki.attribute("value") ==
             [@yt]

    child |> element("[data-example='es']") |> render_click()

    assert child
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.find("input[name='text']")
           |> Floki.attribute("value") ==
             ["I want to learn Spanish."]

    assert Goals.current_proposal(user) == {:ok, nil}
    assert message_count() == before

    send_text(child, "   ")

    assert has_element?(
             child,
             "[data-role='goal-toast']",
             "Say what you want to achieve, or try an example"
           )

    assert Goals.current_proposal(user) == {:ok, nil}
    assert message_count() == before
    refute_received {:signal, _}
  end

  test "sending the opening text starts one conversation and keeps the box", %{
    conn: conn,
    user: user
  } do
    lead!(user)
    child = open(conn, user)
    before = message_count()

    send_text(child, @yt)

    proposal = proposal!(user)
    assert message_count() == before + 1
    assert {:ok, [%{from: :person, content: @yt}]} = Goals.conversation(user, proposal.id)

    assert texts(child, "[data-role='goals-new-message'][data-from='person'] .chat-markdown") == [
             @yt
           ]

    refute has_element?(child, "[data-role='goals-new-examples']")
    assert has_element?(child, "[data-role='goals-new-box'] input[name='text']")
    assert has_element?(child, "[data-role='goals-new-start-over']", "Start over")
    assert_received {:signal, _}
  end

  test "How to Computer: live turns, replies, journey, settled lines, summary and Create goal", %{
    conn: conn,
    user: user
  } do
    lead = lead!(user)
    child = open(conn, user)
    send_text(child, @yt)

    turn!(lead, user, :yt)

    assert texts(child, "[data-role='goals-new-message'][data-from='agent'] .chat-markdown") == [
             "Good one. “Big” is easiest to steer by with one number, and for a YouTube channel that's subscribers. How big is big?"
           ]

    assert texts(child, "[data-role='goals-new-reply']") == [
             "1 million",
             "100,000",
             "Not sure, you pick"
           ]

    tap_first!(child)
    refute has_element?(child, "[data-role='goals-new-reply']")
    assert List.last(texts(child, "[data-from='person'] .chat-markdown")) == "1 million"
    assert {:ok, msgs} = Goals.conversation(user, proposal!(user).id)
    assert List.last(msgs).content == "1 million"

    turn!(lead, user, :yt)
    assert has_element?(child, "[data-role='goals-new-journey'] [data-role='goal-stop']")

    assert stop_texts(child) == [
             "1k First 1,000 by 1 Dec",
             "30k 30,000 by 30 Jun",
             "1M 1 million the big one"
           ]

    assert child
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.find("[data-role='goals-new-journey'] [data-role='goal-stop']")
           |> Enum.map(&Floki.attribute(&1, "data-state")) == [
             ["current"],
             ["upcoming"],
             ["upcoming"]
           ]

    tap_first!(child)

    for _ <- 3..6 do
      turn!(lead, user, :yt)
      tap_first!(child)
    end

    assert settled(child, "source") == ["Number: subscribers, you enter it by hand"]

    assert settled(child, "agent_mode") == [
             "Dalton does the work and asks before anything goes public."
           ]

    assert settled(child, "rhythm") == ["Check-in: Mondays, in your briefing"]

    refute has_element?(child, "[data-role='goals-new-summary']")
    refute has_element?(child, "[data-role='goals-new-create']")

    turn!(lead, user, :yt)
    assert settled(child, "outreach") == ["Nudges: gentle, one line in your briefing"]

    assert texts(child, "[data-role='goals-new-summary-title']") == [
             "Grow How to Computer to 1M subscribers"
           ]

    assert texts(child, "[data-role='goals-new-first-stop']") == [
             "First stop: 1,000 subscribers by 1 Dec"
           ]

    assert texts(child, "[data-role='goals-new-summary-line']") == [
             "Number: subscribers, you enter it by hand",
             "Dalton does the work and asks before anything goes public.",
             "Check-in: Mondays, in your briefing",
             "Nudges: gentle, one line in your briefing"
           ]

    assert texts(child, "[data-role='goals-new-privacy']") == [
             "Only you can see it. You can open it up later."
           ]

    assert has_element?(child, "[data-role='goals-new-create']", "Create goal")
    assert type_controls(render(child)) == []
    assert goal_count() == 0

    proposal = proposal!(user)
    child |> element("[data-role='goals-new-create']") |> render_click()

    assert goal_count() == 1
    {:ok, [card]} = Goals.describe_goals(user)
    assert card.goal.owner_user_id == user.id
    assert card.goal.coach_agent_id == lead.id
    assert card.goal.title == "Grow How to Computer to 1M subscribers"

    assert has_element?(
             child,
             "[data-role='goals-new-settled'][data-setting='created']",
             "Goal created · only you can see it"
           )

    assert has_element?(
             child,
             "a[data-role='goals-new-open'][href='/m/goals?goal=#{card.goal.id}']",
             "Open the goal"
           )

    refute has_element?(child, "[data-role='goals-new-create']")
    assert has_element?(child, "[data-role='goals-row'][data-goal-id='#{card.goal.id}']")
    assert type_controls(render(child)) == []

    render_click(child, "new_create", %{"revision" => proposal.revision})
    render_click(child, "new_create", %{"revision" => proposal.revision + 1})
    assert goal_count() == 1
  end

  test "Spanish settles coach, daily and words", %{conn: conn, user: user} do
    lead = lead!(user)
    child = open(conn, user)
    send_text(child, "I want to learn Spanish.")
    play_to_ready!(child, lead, user, :es)

    assert texts(child, "[data-role='goals-new-summary-line']") == [
             "Number: words, you enter it by hand",
             "You practise. Dalton plans and prepares.",
             "Check-in: every day, in your briefing",
             "Nudges: gentle, one line in your briefing"
           ]

    assert texts(child, "[data-role='goals-new-first-stop']") == [
             "First stop: 300 words by 25 Dec"
           ]
  end

  test "every value of every setting has its settled line", %{conn: conn, user: user} do
    lead = lead!(user)
    child = open(conn, user)
    send_text(child, "Something")
    {:ok, sources} = Goals.list_sources(user)
    measured = Enum.find(sources, &(&1.kind == :measured))
    assert measured, "no measured source to show"

    propose!(lead, user, %{"source_key" => nil})
    assert settled(child, "source") == ["Number: none yet"]

    propose!(lead, user, %{"source_key" => "self_reported"})
    assert settled(child, "source") == ["Number: you enter it by hand"]

    propose!(lead, user, %{"unit" => "km"})
    assert settled(child, "source") == ["Number: km, you enter it by hand"]

    propose!(lead, user, %{"source_key" => measured.key})
    first = String.first(measured.label)

    assert settled(child, "source") == [
             "Number: km, " <> String.downcase(first) <> String.slice(measured.label, 1..-1//1)
           ]

    for {mode, line} <- [
          {"do", "Dalton does the work and asks before anything goes public."},
          {"advise", "Dalton advises. You do the work."},
          {"coach", "You practise. Dalton plans and prepares."}
        ] do
      propose!(lead, user, %{"agent_mode" => mode})
      assert settled(child, "agent_mode") == [line]
    end

    for {attrs, line} <- [
          {%{"rhythm" => "daily"}, "Check-in: every day, in your briefing"},
          {%{"rhythm" => "weekdays"}, "Check-in: on weekdays, in your briefing"},
          {%{"rhythm" => "weekly", "rhythm_weekday" => 3},
           "Check-in: Wednesdays, in your briefing"},
          {%{"rhythm" => "biweekly", "rhythm_weekday" => 5},
           "Check-in: every other Friday, in your briefing"}
        ] do
      propose!(lead, user, attrs)
      assert settled(child, "rhythm") == [line]
    end

    for {value, line} <- [
          {"gentle", "Nudges: gentle, one line in your briefing"},
          {"pushy", "Nudges: pushy, a message when something is overdue"},
          {"off", "Nudges: off. Dalton only reports."}
        ] do
      propose!(lead, user, %{"outreach" => value})
      assert settled(child, "outreach") == [line]
    end

    propose!(lead, user, %{"title" => "T", "kind" => "shared", "ready" => true})

    assert texts(child, "[data-role='goals-new-privacy']") == [
             "Only you can see it. Dalton suggests sharing it: use Open up on the goal page."
           ]

    refute has_element?(child, "[data-role='goals-new-first-stop']")
    propose!(lead, user, %{"stops" => [%{"label" => "Halfway"}]})
    assert texts(child, "[data-role='goals-new-first-stop']") == ["First stop: Halfway"]
  end

  test "a proposal rewritten after the page rendered it is not created", %{conn: conn, user: user} do
    lead = lead!(user)
    child = open(conn, user)
    send_text(child, "Run a half marathon")

    propose!(lead, user, %{
      "title" => "Half marathon",
      "agent_mode" => "coach",
      "rhythm" => "daily",
      "outreach" => "gentle",
      "ready" => true
    })

    rendered = proposal!(user).revision
    assert has_element?(child, "[data-role='goals-new-create'][phx-value-revision='#{rendered}']")

    propose!(lead, user, %{"title" => "Something else"})
    render_click(child, "new_create", %{"revision" => rendered})

    assert goal_count() == 0

    assert has_element?(
             child,
             "[data-role='goal-toast']",
             "The goal changed. Have another look before you create it."
           )

    assert texts(child, "[data-role='goals-new-summary-title']") == ["Something else"]

    child |> element("[data-role='goals-new-create']") |> render_click()
    assert goal_count() == 1
    {:ok, [card]} = Goals.describe_goals(user)
    assert card.goal.title == "Something else"
  end

  test "crafted events create and change nothing; another user sees an empty screen", %{
    conn: conn,
    user: user,
    org_id: org_id
  } do
    lead = lead!(user)
    other = person!(org_id, "Bea Other")
    {:ok, theirs} = Goals.start_goal_conversation(other, "ZEBRA-QUARTZ marathon")

    {:ok, _} =
      Tools.execute(
        "goal_propose",
        %{
          "proposal_id" => theirs.id,
          "title" => "VIOLET-ANVIL",
          "agent_mode" => "do",
          "rhythm" => "daily",
          "outreach" => "off",
          "replies" => ["Yes"],
          "ready" => true
        },
        %{agent_id: lead.id}
      )

    {:ok, theirs} = Goals.get_proposal(other, theirs.id)
    their_goal = goal!(other, org_id)
    goals_before = goal_count()
    messages_before = message_count()

    child = open(conn, user)
    html = render(child)
    refute html =~ "ZEBRA-QUARTZ"
    refute html =~ "VIOLET-ANVIL"
    refute html =~ theirs.id
    assert texts(child, "[data-role='goals-new-greeting'] .chat-markdown") == [@greeting]

    crafted = %{
      "proposal_id" => theirs.id,
      "id" => theirs.id,
      "goal_id" => their_goal.id,
      "revision" => theirs.revision,
      "index" => "0"
    }

    for event <- ~w(new_create new_reply new_start_over) do
      render_click(child, event, crafted)
    end

    assert goal_count() == goals_before
    assert message_count() == messages_before
    {:ok, after_events} = Goals.get_proposal(other, theirs.id)

    assert Map.take(after_events, [:status, :revision, :draft]) ==
             Map.take(theirs, [:status, :revision, :draft])

    assert Goals.current_proposal(user) == {:ok, nil}

    # Not ready yet: a create carrying the current revision writes nothing.
    send_text(child, "MINE-ONLY-TEXT")
    mine = proposal!(user)
    render_click(child, "new_create", Map.put(crafted, "revision", mine.revision))
    assert goal_count() == goals_before
    assert proposal!(user).status == "open"

    # The other person's screen shows their own conversation, never this one.
    their_child = open(build_conn(), other)
    refute render(their_child) =~ "MINE-ONLY-TEXT"
    assert render(their_child) =~ "ZEBRA-QUARTZ"
  end

  test "a quick reply sends the server's label, never one from the client", %{
    conn: conn,
    user: user
  } do
    lead = lead!(user)
    child = open(conn, user)
    send_text(child, @yt)
    turn!(lead, user, :yt)

    render_click(child, "new_reply", %{"index" => "1", "label" => "CRAFTED-LABEL"})
    {:ok, messages} = Goals.conversation(user, proposal!(user).id)
    assert List.last(messages).content == "100,000"
    refute render(child) =~ "CRAFTED-LABEL"

    # Once answered, the replies are gone and another tap posts nothing.
    render_click(child, "new_reply", %{"index" => "0"})
    {:ok, again} = Goals.conversation(user, proposal!(user).id)
    assert length(again) == length(messages)
  end

  test "core's system notices in the DM are not shown as the agent's words", %{
    conn: conn,
    user: user
  } do
    lead = lead!(user)
    child = open(conn, user)
    send_text(child, @yt)
    turn!(lead, user, :yt)
    proposal = proposal!(user)

    {:ok, system} =
      Platform.Orchestration.ExecutionSpace.ensure_system_participant(proposal.space_id)

    {:ok, _} =
      Chat.post_message(%{
        space_id: proposal.space_id,
        participant_id: system.id,
        content_type: "system",
        content: "SYSTEM-NOTICE-LINE couldn't reply to this message.",
        metadata: %{"kind" => "reply_failure"}
      })

    assert render(child) =~ "Good one."
    refute render(child) =~ "SYSTEM-NOTICE-LINE"
    {:ok, messages} = Goals.conversation(user, proposal.id)
    assert Enum.map(messages, & &1.from) == [:person, :agent]
    assert has_element?(child, "[data-role='goals-new-reply']")
  end

  test "no lead agent: the empty state and no box", %{conn: conn, user: user} do
    child = open(conn, user)

    assert has_element?(
             child,
             "[data-role='goals-new-no-lead']",
             "No agent leads this install yet"
           )

    assert has_element?(
             child,
             "[data-role='goals-new-no-lead']",
             "An admin can give an agent the agents leader role. Then come back and start again."
           )

    refute has_element?(child, "[data-role='goals-new-box']")
    refute has_element?(child, "input")
  end

  # Task 01a1eab6 stage 3: the lead's runtime lacks the Goals tools.
  test "a lead without the Goals tools: the refusal, the typed text kept, no message", %{
    conn: conn,
    user: user
  } do
    lead = user |> lead!() |> grant_goals_tools!(["messaging"])
    child = open(conn, user)
    before = message_count()

    refute has_element?(child, "[data-role='goals-new-refused']")
    send_text(child, @yt)

    assert has_element?(
             child,
             "[data-role='goals-new-refused']",
             "Dalton can't take new goals yet: its runtime doesn't have the Goals tools."
           )

    assert has_element?(
             child,
             "[data-role='goals-new-refused']",
             "Ask an admin to turn on Goals for Dalton."
           )

    assert child
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.find("[data-role='goals-new-box'] input[name='text']")
           |> Floki.attribute("value") == [@yt]

    refute has_element?(child, "[data-role='goals-new-message']")
    assert message_count() == before
    assert Goals.current_proposal(user) == {:ok, nil}
    refute_received {:signal, _}

    # After the grant the next send starts the conversation and the block goes.
    grant_goals_tools!(lead)
    send_text(child, @yt)

    refute has_element?(child, "[data-role='goals-new-refused']")
    assert {:ok, [%{from: :person, content: @yt}]} = Goals.conversation(user, proposal!(user).id)
    assert_received {:signal, _}
  end

  test "an offline agent: the offline line", %{conn: conn, user: user} do
    lead!(user)
    Application.put_env(:goals, :wake_up_dispatcher, fn _ -> {:error, :runtime_offline} end)
    child = open(conn, user)
    send_text(child, @yt)

    assert proposal!(user).delivery == "offline"

    assert has_element?(
             child,
             "[data-role='goals-new-offline']",
             "Dalton is offline and will answer when it is back."
           )
  end

  test "an agent with no runtime reads as offline too", %{conn: conn, user: user} do
    agent = agent!() |> Ecto.Changeset.change(name: "Dalton") |> Repo.update!()
    {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), agent.id)
    child = open(conn, user)
    send_text(child, @yt)

    assert proposal!(user).delivery == "no_runtime"
    assert has_element?(child, "[data-role='goals-new-offline']")
  end

  test "Start over cancels the open conversation", %{conn: conn, user: user} do
    lead!(user)
    child = open(conn, user)
    send_text(child, @yt)
    proposal = proposal!(user)

    child |> element("[data-role='goals-new-start-over']") |> render_click()
    assert Goals.current_proposal(user) == {:ok, nil}
    assert {:ok, %{status: "cancelled"}} = Goals.get_proposal(user, proposal.id)
    assert has_element?(child, "[data-role='goals-new-examples']")
  end

  # Task 01a1eab6 stage 5 (e2e case 01a1eabf-bd32-7007): a second window
  # already on ?new=1 when the person starts the goal in the first one.
  test "a screen open before the start shows the opening message and later turns live", %{
    conn: conn,
    user: user,
    org_id: org_id
  } do
    lead = lead!(user)
    other = person!(org_id, "Bea Other")
    one = open(conn, user)
    two = open(build_conn(), user)
    theirs = open(build_conn(), other)
    person = "[data-role='goals-new-message'][data-from='person'] .chat-markdown"
    agent = "[data-role='goals-new-message'][data-from='agent'] .chat-markdown"

    for view <- [one, two, theirs],
        do: assert(has_element?(view, "[data-role='goals-new-examples']"))

    send_text(one, @yt)

    # No remount: the same view process re-reads on the person's topic.
    assert texts(two, person) == [@yt]
    refute has_element?(two, "[data-role='goals-new-examples']")
    assert has_element?(two, "[data-role='goals-new-start-over']", "Start over")

    send_text(one, "AMBER-KESTREL second turn")
    turn!(lead, user, :yt)

    for view <- [one, two] do
      assert texts(view, person) == [@yt, "AMBER-KESTREL second turn"]
      assert [reply] = texts(view, agent)
      assert reply =~ "How big is big?"
    end

    # Another person's screen never refreshes onto this conversation.
    html = render(theirs)
    refute html =~ "AMBER-KESTREL"
    refute html =~ "How big is big?"
    refute html =~ proposal!(user).id
    assert has_element?(theirs, "[data-role='goals-new-examples']")
  end

  test "a refused or rolled-back start broadcasts nothing on the person's topic", %{
    user: user
  } do
    lead = user |> lead!() |> grant_goals_tools!(["messaging"])
    two = open(build_conn(), user)
    :ok = Goals.subscribe_proposals(user)

    # The lead lacks the Goals tools: the transaction writes nothing.
    assert Goals.start_goal_conversation(user, @yt) == {:error, :lead_missing_goals_tools}
    refute_received {:goal_proposal_changed, _}
    assert has_element?(two, "[data-role='goals-new-examples']")
    refute render(two) =~ @yt

    # Positive control: the same subscription hears a start that commits.
    grant_goals_tools!(lead)
    {:ok, started} = Goals.start_goal_conversation(user, @yt)
    id = started.id
    assert_received {:goal_proposal_changed, ^id}

    assert texts(two, "[data-role='goals-new-message'][data-from='person'] .chat-markdown") == [
             @yt
           ]

    # A second start rolls back (one open proposal per person): nothing more.
    assert {:error, :conversation_open} = Goals.start_goal_conversation(user, "PLUM-ORBIT again")
    refute_received {:goal_proposal_changed, _}
  end

  test "the type scan hits a planted control" do
    assert [_] = type_controls(~s(<div><select name="type"><option>a</option></select></div>))
    assert [_] = type_controls(~s(<div><button>Goal type</button></div>))
    assert [_] = type_controls(~s(<div><input aria-label="Kind" /></div>))

    assert type_controls(
             ~s(<div><input name="text" aria-label="What do you want to achieve?" /></div>)
           ) == []
  end
end

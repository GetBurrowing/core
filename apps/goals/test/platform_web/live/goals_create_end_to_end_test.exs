defmodule PlatformWeb.GoalsCreateEndToEndTest do
  @moduledoc """
  Both example goals created end to end (task 01a1dfc1-7625, Goals 5/8
  stage 4): from the New goal button, through every scripted turn, to Create
  goal, the coach's research and a cited suggestion at the first check-in.
  The agent is `Platform.Goals.ScriptedAgent` (goals tools and core's public
  chat functions only). Time is injected through `:goals, :clock_now`
  before the clock runs; the dispatcher is injected; no sleeps. Sets the
  global `:goals` env, so not async.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures, only: [put_now: 1, fire: 1]

  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.ScriptedAgent
  alias Platform.Goals.Tools
  alias Platform.Repo

  import Ecto.Query

  @examples %{
    yt: %{
      opening: "I want How to Computer to be a big channel. Really big.",
      title: "Grow How to Computer to 1M subscribers"
    },
    es: %{opening: "I want to learn Spanish.", title: "Get by in Spanish by June"}
  }

  setup do
    enable_goals!()
    parent = self()

    restore =
      for key <- [:wake_up_dispatcher, :clock_now],
          do: {key, Application.fetch_env(:goals, key)}

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:signal, signal})
      :ok
    end)

    on_exit(fn ->
      for {key, previous} <- restore do
        case previous do
          {:ok, value} -> Application.put_env(:goals, key, value)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end)

    # Injected time, a little ahead of the wall clock so message times and
    # proposal stamps read in the order they happened.
    put_now(DateTime.add(DateTime.utc_now(), 60, :second))

    org_id = org_id!()
    user = person!(org_id, "Ryan Tester")
    {:ok, org_id: org_id, user: user, lead: lead!(user)}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp person!(org_id, name) do
    user = member!(org_id) |> Ecto.Changeset.change(name: name) |> Repo.update!()
    space = space!(org_id)

    {:ok, _} =
      Platform.Access.Grants.grant(%{
        principal: user,
        permission: "goals.use",
        resource: {:space, space.id}
      })

    user
  end

  defp lead!(owner) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: owner.id,
        runtime_id: "goals-e2e-#{unique()}",
        display_name: "Goals end to end",
        status: "active"
      })

    agent =
      agent!()
      |> Ecto.Changeset.change(name: "Dalton", runtime_type: "external", runtime_id: runtime.id)
      |> Repo.update!()

    {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), agent.id)
    agent
  end

  defp open(conn, user, path) do
    {:ok, view, _html} =
      live(Plug.Test.init_test_session(conn, current_user_id: user.id), path)

    find_live_child(view, "ext-page-goals")
  end

  defp doc(child), do: child |> render() |> Floki.parse_fragment!()

  defp texts(child, selector) do
    child
    |> doc()
    |> Floki.find(selector)
    |> Enum.map(&(&1 |> Floki.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  defp href(child, selector) do
    assert [href] = child |> doc() |> Floki.find(selector) |> Floki.attribute("href")
    href
  end

  defp goal_count, do: Repo.aggregate(Platform.Goals.Goal, :count)

  defp proposal!(user) do
    {:ok, %{} = proposal} = Goals.current_proposal(user)
    proposal
  end

  defp entries(goal_id, kind),
    do:
      Repo.all(
        from(e in Goals.Entry,
          where: e.goal_id == ^goal_id and e.kind == ^kind,
          order_by: [asc: e.occurred_at, asc: e.id]
        )
      )

  # From the list's New goal button to a ready proposal, tapping the
  # default reply after every scripted turn and counting goals each time.
  defp converse!(conn, user, lead, example) do
    list = open(conn, user, "/m/goals")
    path = href(list, "[data-pane='goals'] [data-goals-slot='new-goal'] a")
    assert path == "/m/goals?new=1"

    child = open(conn, user, path)
    assert goal_count() == 0

    child
    |> form("[data-role='goals-new-box']", %{"text" => @examples[example].opening})
    |> render_submit()

    assert goal_count() == 0
    turns = length(ScriptedAgent.script(example))

    for turn <- 1..turns do
      assert {:ok, _} = ScriptedAgent.next_turn(lead, proposal!(user), example)
      assert goal_count() == 0

      if turn < turns do
        child |> element("[data-role='goals-new-reply']:first-child") |> render_click()
        assert goal_count() == 0
      end
    end

    assert ScriptedAgent.next_turn(lead, proposal!(user), example) == :done
    assert goal_count() == 0

    assert texts(child, "[data-role='goals-new-summary-title']") == [@examples[example].title]
    child
  end

  # Create goal, then the coach answers the confirmed signal.
  defp create_and_research!(child, user, lead, example) do
    proposal = proposal!(user)
    flush_signals()
    assert goal_count() == 0
    child |> element("[data-role='goals-new-create']") |> render_click()
    assert goal_count() == 1

    assert_received {:signal,
                     %{metadata: %{responsibility_key: "goals.research", prompt: prompt}}}

    {:ok, [card]} = Goals.describe_goals(user)
    goal = card.goal
    assert prompt =~ goal.id and prompt =~ proposal.id
    refute prompt =~ goal.title

    before = texts(child, "[data-role='goals-new-message'][data-from='agent'] .chat-markdown")
    assert {:ok, takeaways} = ScriptedAgent.research(lead, prompt, example)

    # The researching message arrives on the open screen, after the
    # "Goal created" line, with no reload.
    after_create =
      texts(
        child,
        "[data-role='goals-new-created'] [data-role='goals-new-message'][data-from='agent'] .chat-markdown"
      )

    assert after_create == [ScriptedAgent.researching(example)]

    assert texts(child, "[data-role='goals-new-message'][data-from='agent'] .chat-markdown") ==
             before ++ [ScriptedAgent.researching(example)]

    assert href(child, "a[data-role='goals-new-open']") == "/m/goals?goal=" <> goal.id
    {goal, takeaways}
  end

  defp flush_signals do
    receive do
      {:signal, _} -> flush_signals()
    after
      0 -> :ok
    end
  end

  defp assert_learned!(conn, user, goal, lead) do
    takeaways = entries(goal.id, "takeaway")
    assert length(takeaways) == 3

    for t <- takeaways do
      assert t.author_type == "agent" and t.author_agent_id == lead.id
      assert [%{"name" => name} | _] = t.sources
      assert is_binary(name) and name != ""
      assert is_binary(t.details["doing"])
    end

    page = open(conn, user, "/m/goals?goal=" <> goal.id)
    assert texts(page, "[data-role='goal-learned'] h3") == ["What we've learned"]
    assert length(texts(page, "[data-role='goal-takeaway']")) == 3
    assert has_element?(page, "[data-role='goal-learned']", "Read more")
    page
  end

  # The short read opened from a "From:" link focuses that takeaway's card.
  defp assert_focused_read!(conn, user, path, takeaway) do
    read = open(conn, user, path)

    assert has_element?(
             read,
             "[data-role='goal-read-card'][data-entry-id='#{takeaway.id}'][data-focused='true']",
             takeaway.title
           )

    assert length(read |> doc() |> Floki.find("[data-role='goal-read-card'][data-focused='true']")) ==
             1
  end

  defp call(tool, args, agent), do: Tools.execute(tool, args, %{agent_id: agent.id})

  defp predicted(extra) do
    Map.merge(
      %{
        "prediction" => "This will help",
        "predicted_by" => Date.to_iso8601(Date.add(DateTime.to_date(Goals.Clock.now()), 7))
      },
      extra
    )
  end

  # ── tests ─────────────────────────────────────────────────────────────────

  test "How to Computer end to end: create, research, cited goal_do", c do
    child = converse!(c.conn, c.user, c.lead, :yt)
    {goal, takeaways} = create_and_research!(child, c.user, c.lead, :yt)

    goal = Repo.one!(from(g in Goals.Goal, where: g.id == ^goal.id))
    assert goal.title == "Grow How to Computer to 1M subscribers"
    assert goal.unit == "subscribers"
    assert goal.source_key == "self_reported"
    assert goal.agent_mode == "do"
    assert {goal.rhythm, goal.rhythm_weekday} == {"weekly", 1}
    assert goal.outreach == "gentle"
    assert goal.kind == "personal"
    assert goal.owner_user_id == c.user.id
    assert goal.coach_agent_id == c.lead.id
    assert Repo.aggregate(from(g in Goals.Grant, where: g.goal_id == ^goal.id), :count) == 0
    assert {:ok, stops} = Goals.list_stops(c.user, goal.id)
    assert Enum.map(stops, & &1.label) == ["First 1,000", "30,000", "1 million"]
    assert length(takeaways) == 3

    assert_learned!(c.conn, c.user, goal, c.lead)

    # The first check-in: the coach acts, citing the second takeaway.
    cited = Enum.at(entries(goal.id, "takeaway"), 1)
    wake = fire(goal)

    assert {:ok, %{entry: action}} =
             call(
               "goal_do",
               predicted(%{
                 "wake_up_id" => wake.id,
                 "title" => "Scheduled Monday's video",
                 "takeaway_id" => cited.id
               }),
               c.lead
             )

    assert action.takeaway_id == cited.id

    page = open(c.conn, c.user, "/m/goals?goal=" <> goal.id)
    from = "From: " <> cited.title

    assert texts(page, "[data-role='goal-trying-card'] [data-role='goal-trying-from']") == [from]

    assert texts(
             page,
             "[data-role='goal-notebook-entry'][data-kind='action'] [data-role='goal-notebook-from']"
           ) == [from]

    trying = href(page, "a[data-role='goal-trying-from']")
    notebook = href(page, "[data-kind='action'] a[data-role='goal-notebook-from']")
    assert trying == "/m/goals?goal=#{goal.id}&read=#{cited.id}"
    assert notebook == trying
    assert_focused_read!(c.conn, c.user, trying, cited)
  end

  test "Spanish end to end: create, research, cited practice goal_ask", c do
    child = converse!(c.conn, c.user, c.lead, :es)
    {goal, _} = create_and_research!(child, c.user, c.lead, :es)

    goal = Repo.one!(from(g in Goals.Goal, where: g.id == ^goal.id))
    assert goal.title == "Get by in Spanish by June"
    assert goal.unit == "words"
    assert goal.source_key == "self_reported"
    assert goal.agent_mode == "coach"
    assert goal.rhythm == "daily"
    assert goal.kind == "personal"
    assert goal.coach_agent_id == c.lead.id
    assert {:ok, stops} = Goals.list_stops(c.user, goal.id)
    assert length(stops) == 3

    assert_learned!(c.conn, c.user, goal, c.lead)

    cited = hd(entries(goal.id, "takeaway"))
    wake = fire(goal)

    assert {:ok, %{entry: ask}} =
             call(
               "goal_ask",
               predicted(%{
                 "wake_up_id" => wake.id,
                 "kind" => "practice",
                 "title" => "Five new words",
                 "payload" => %{
                   "cards" => [
                     %{"front" => "la playa", "back" => "the beach"},
                     %{"front" => "el tren", "back" => "the train"}
                   ]
                 },
                 "takeaway_id" => cited.id
               }),
               c.lead
             )

    assert ask.kind == "ask" and ask.takeaway_id == cited.id

    page = open(c.conn, c.user, "/m/goals?goal=" <> goal.id)

    assert texts(
             page,
             "[data-role='goal-notebook-entry'][data-kind='ask'] [data-role='goal-notebook-from']"
           ) == ["From: " <> cited.title]

    path = href(page, "[data-kind='ask'] a[data-role='goal-notebook-from']")
    assert path == "/m/goals?goal=#{goal.id}&read=#{cited.id}"
    assert_focused_read!(c.conn, c.user, path, cited)

    # Rows that cite nothing carry no link.
    for row <- page |> doc() |> Floki.find("[data-role='goal-notebook-entry']"),
        Floki.attribute(row, "data-kind") != ["ask"],
        do: assert(Floki.find(row, "[data-role='goal-notebook-from']") == [])
  end

  test "a takeaway with no source is refused and the page keeps three rows", c do
    child = converse!(c.conn, c.user, c.lead, :yt)
    {goal, _} = create_and_research!(child, c.user, c.lead, :yt)
    before = Repo.aggregate(Goals.Entry, :count)

    args = %{"title" => "Unsourced", "body" => "No source given."}

    for extra <- [%{}, %{"sources" => []}, %{"sources" => [%{"url" => "https://example.com"}]}] do
      assert {:error, %{code: :source_required}} =
               ScriptedAgent.add_takeaway(c.lead, goal.id, Map.merge(args, extra))
    end

    assert Repo.aggregate(Goals.Entry, :count) == before
    page = assert_learned!(c.conn, c.user, goal, c.lead)
    refute has_element?(page, "[data-role='goal-takeaway']", "Unsourced")
  end
end

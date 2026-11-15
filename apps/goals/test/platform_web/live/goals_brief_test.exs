defmodule PlatformWeb.GoalsBriefTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.{AskAnswer, Clock, Entry}
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Repo

  defmodule Recorder do
    def fan_out_to_user(id, payload) do
      send(self(), {:brief_push, id, payload})
      :ok
    end
  end

  setup do
    c = setup_brief()
    grant!(c.owner, c.org)
    c
  end

  defp grant!(user, org) do
    space = space!(org)

    {:ok, _} =
      Platform.Access.Grants.grant(%{
        principal: user,
        permission: "goals.use",
        resource: {:space, space.id}
      })
  end

  defp build do
    Disseminator.run(now: Clock.now(), notifications_module: Recorder)
  end

  defp open(conn, user) do
    live(Plug.Test.init_test_session(conn, current_user_id: user.id), "/inbox/briefing/#{date()}")
  end

  defp card(item), do: "[data-role=goals-brief-card][data-item-id='#{item.id}']"
  defp button(item, action), do: card(item) <> " [data-action='#{action}']"

  defp items(c) do
    {:ok, rows} = Goals.brief_items(c.owner, date())
    rows
  end

  defp full(c) do
    ask_goal = fn title ->
      goal!(c.owner, c.org, %{
        title: title,
        coach_agent_id: c.coach.id,
        agent_mode: "advise",
        outreach: "pushy",
        rhythm: "daily"
      })
    end

    offer_goal = ask_goal.("Write the outline")
    idea_goal = ask_goal.("Try a new format")
    check_goal = ask_goal.("Review progress")

    offer =
      queued(%{c | goal: offer_goal}, %{
        kind: "offer",
        title: "Want the outline?",
        body: "I drafted the outline.",
        payload: %{"draft" => "First line\nSecond line"}
      })

    idea =
      queued(%{c | goal: idea_goal}, %{
        kind: "offer",
        title: "Try short videos",
        payload: %{
          "idea" => %{
            "why" => "Less work",
            "measure" => "More viewers",
            "steps" => ["Draft", "Publish"]
          }
        }
      })

    question = queued(%{c | goal: check_goal}, %{title: "Review the week"})

    {:ok, takeaway} =
      Goals.add_entry(c.coach, c.goal.id, %{
        kind: "takeaway",
        title: "Short videos bring viewers",
        occurred_at: Clock.now()
      })

    undoable =
      action(c, %{
        title: "Drafted three videos",
        takeaway_id: takeaway.id,
        details: %{"undo_note" => "Remove the drafts"}
      })

    action(c, %{title: "Reviewed the comments"})
    action(c, %{title: "Prepared the next outline"})
    {:ok, _} = Goals.put_stops(c.owner, c.goal.id, [%{label: "First 1,000", target_value: 1000}])
    build()

    %{
      offer: offer,
      idea: idea,
      question: question,
      takeaway: takeaway,
      undoable: undoable,
      idea_goal: idea_goal,
      check_goal: check_goal
    }
  end

  test "queued cards build one briefing and render the report, offer, idea and check-in inventory",
       c do
    f = full(c)

    assert Repo.one(
             from(b in Platform.Memory.Briefing,
               where: b.user_id == ^c.owner.id and b.digest_date == ^date()
             )
           )

    assert Repo.one(
             from(i in Platform.Inbox.Item,
               where: i.user_id == ^c.owner.id and i.kind == "briefing"
             )
           )

    {:ok, view, html} = open(c.conn, c.owner)
    assert has_element?(view, "[data-role=goals-brief]", "Your goals · 4")
    assert html =~ "0 of 4 handled"
    assert html =~ "3 need your call"
    assert html =~ "Goal · progress report"
    assert html =~ "Goal · offer"
    assert html =~ "Goal · idea"
    assert html =~ "Goal · check-in"

    for title <- ["Drafted three videos", "Reviewed the comments", "Prepared the next outline"],
        do: assert(html =~ title)

    assert has_element?(
             view,
             "a[href='/m/goals?goal=#{c.goal.id}&read=#{f.takeaway.id}']",
             "From: Short videos bring viewers"
           )

    assert has_element?(
             view,
             "a[href='/m/goals?goal=#{f.idea_goal.id}&idea=#{f.idea.id}']",
             "Look at the idea"
           )

    assert has_element?(
             view,
             "a[href='/m/goals?goal=#{f.check_goal.id}&check=#{f.question.id}']",
             "Open the check-in"
           )

    assert has_element?(
             view,
             "a[href='/m/goals?goal=#{c.goal.id}&from=brief']",
             "See the journey"
           )

    assert html =~ "Each goal sends what fits it:"
    refute html =~ "Where we are:"
  end

  test "offer use, withdrawal and decline update signals, progress and the Inbox call count", c do
    full(c)
    item = Enum.find(items(c), &(&1.kind == :offer))
    {:ok, view, _} = open(c.conn, c.owner)
    view |> element(button(item, "answer") <> "[phx-value-answer=used]") |> render_click()
    assert [%{answer: "used"}] = Repo.all(AskAnswer)
    assert has_element?(view, card(item), "Used")
    assert has_element?(view, card(item), "First line")
    assert render(view) =~ "1 of 4 handled"
    assert render(view) =~ "2 need your call"
    view |> element(button(item, "withdraw")) |> render_click()
    assert Repo.aggregate(AskAnswer, :count) == 0
    view |> element(button(item, "answer") <> "[phx-value-answer=declined]") |> render_click()
    assert [%{answer: "declined"}] = Repo.all(AskAnswer)
    assert has_element?(view, card(item), "Not now.")
  end

  test "report acknowledgement, undo requests and questions are persisted without pretending an instant action",
       c do
    f = full(c)
    item = Enum.find(items(c), &(&1.kind == :report))
    {:ok, view, _} = open(c.conn, c.owner)
    view |> element(button(item, "noted")) |> render_click()
    assert has_element?(view, card(item), "Noted")
    view |> element(button(item, "noted")) |> render_click()
    refute has_element?(view, card(item) <> " [data-role=goals-brief-receipt]", "Noted")
    undo = button(item, "undo") <> "[phx-value-entry_id='#{f.undoable.id}']"
    view |> element(undo) |> render_click()
    assert has_element?(view, card(item), "Undo asked for.")
    # Repeating the identical crafted event is idempotent.
    view
    |> with_target("[data-role=goals-brief]")
    |> render_hook("undo", %{item_id: item.id, entry_id: f.undoable.id, request: "undo"})

    assert Repo.aggregate(
             from(e in Entry, where: fragment("?->>'undo_of'", e.details) == ^f.undoable.id),
             :count
           ) == 1

    view |> element(undo) |> render_click()
    refute has_element?(view, card(item), "Undo asked for.")
    before = Repo.aggregate(Entry, :count)
    view |> element(button(item, "ask-open")) |> render_click()
    view |> form(card(item) <> " form", %{question: "  "}) |> render_submit()
    assert Repo.aggregate(Entry, :count) == before
    assert has_element?(view, "[placeholder='Type a question first']")
    view |> form(card(item) <> " form", %{question: "What comes next?"}) |> render_submit()
    assert Repo.aggregate(Entry, :count) == before + 1
    assert has_element?(view, card(item), "answers at the next check-in.")
    assert has_element?(view, card(item), "What comes next?")
  end

  test "forged foreign item and ask events change no rows", c do
    stranger = member!(c.org)
    grant!(stranger, c.org)

    foreign =
      goal!(stranger, c.org, %{coach_agent_id: c.coach.id, outreach: "pushy", rhythm: "daily"})

    ask = queued(%{c | goal: foreign, owner: stranger}, %{kind: "offer"})
    {:ok, _} = Goals.prepare_brief(stranger, date())
    {:ok, [item]} = Goals.brief_items(stranger, date())
    full(c)
    {:ok, view, _} = open(c.conn, c.owner)
    counts = fn -> {Repo.aggregate(Entry, :count), Repo.aggregate(AskAnswer, :count)} end
    before = counts.()

    for {event, attrs} <- [
          {"noted", %{noted: "true"}},
          {"answer", %{answer: "used", ask_id: ask.id}},
          {"undo", %{entry_id: Ecto.UUID.generate(), request: "undo"}},
          {"ask-send", %{question: "Forged question"}},
          {"withdraw", %{}}
        ] do
      view
      |> with_target("[data-role=goals-brief]")
      |> render_hook(event, Map.put(attrs, :item_id, item.id))
    end

    assert counts.() == before
  end

  test "empty, disabled and unpermitted readers receive no Goals heading", c do
    build()
    assert Repo.aggregate(Platform.Memory.Briefing, :count) == 0
    full(c)
    {:ok, _, html} = open(c.conn, c.owner)
    assert html =~ "Your goals"
    Application.put_env(:goals, :enabled, false)
    {:ok, _, html} = open(c.conn, c.owner)
    refute html =~ "Your goals"
    Application.put_env(:goals, :enabled, true)
    other = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, other.id})

    Platform.InsightFixtures.insight!(
      addressee: other,
      action_type: "question",
      body: "Which host?"
    )

    build()

    assert Repo.one(
             from(b in Platform.Memory.Briefing,
               where: b.user_id == ^other.id and b.digest_date == ^date()
             )
           )

    # Sharing alone is insufficient to receive an addressed item or the section.
    {:ok, _, html} = open(c.conn, other)
    refute html =~ "Your goals"
    assert Platform.Extensions.validate() == :ok
  end
end

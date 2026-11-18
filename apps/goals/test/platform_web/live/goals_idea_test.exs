defmodule PlatformWeb.GoalsIdeaTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Platform.Goals.BriefFixtures
  alias Platform.Goals
  alias Platform.Goals.Clock

  setup do
    c = setup_brief()

    c
  end

  defp open(c, ask) do
    {:ok, parent, _} =
      live(
        Plug.Test.init_test_session(c.conn, current_user_id: c.owner.id),
        "/m/goals?goal=#{c.goal.id}&idea=#{ask.id}"
      )

    find_live_child(parent, "ext-page-goals")
  end

  defp stored(c, ask) do
    {:ok, result} = Goals.get_ask(c.owner, ask.id)
    result
  end

  defp actions(c) do
    {:ok, entries} = Goals.list_entries(c.owner, c.goal.id, kind: "action")
    entries
  end

  defp fixture(c) do
    {:ok, takeaway} =
      Goals.add_entry(c.coach, c.goal.id, %{
        kind: "takeaway",
        title: "Use viewers' questions",
        sources: [%{"name" => "Notes"}],
        occurred_at: Clock.now()
      })

    ask =
      queued(c, %{
        kind: "offer",
        title: "Try a weekly question video",
        payload: %{
          "idea" => %{
            "why" => "Viewers already tell us what they need.",
            "measure" => "Two subscribers per hundred views.",
            "steps" => ["Pick one question", "Draft a short answer", "Publish and measure"],
            "takeaway_id" => takeaway.id
          }
        }
      })

    {ask, takeaway}
  end

  test "the idea inventory records acceptance without starting work, Undo restores it and decline persists",
       c do
    {ask, takeaway} = fixture(c)
    child = open(c, ask)
    assert has_element?(child, "[data-role=goals-idea]")
    assert has_element?(child, "a[href='/m/goals?goal=#{c.goal.id}']", "‹ #{c.goal.title}")

    text =
      child
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.text()
      |> String.replace(~r/\s+/u, " ")

    for line <- [
          "Idea",
          ask.title,
          "An idea from #{c.coach.name}",
          "Why",
          "Viewers already tell us what they need.",
          "How we'll know it works",
          "Two subscribers per hundred views.",
          "What #{c.coach.name} would do first",
          "Pick one question",
          "Draft a short answer",
          "Publish and measure"
        ] do
      assert text =~ line
    end

    assert has_element?(
             child,
             "a[href='/m/goals?goal=#{c.goal.id}&read=#{takeaway.id}']",
             "From: #{takeaway.title}"
           )

    assert has_element?(child, "[data-action=idea-used]", "Start trying it")
    assert has_element?(child, "[data-action=idea-declined]", "Not now")
    assert stored(c, ask).answers == []
    before = actions(c)
    child |> element("[data-action=idea-used]") |> render_click()
    assert [%{answer: "used"}] = stored(c, ask).answers
    assert actions(c) == before

    assert has_element?(
             child,
             "[role=status]",
             "#{c.coach.name} starts on it at the next check-in"
           )

    assert length(
             child
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.find("[data-role=goal-trying-card]")
           ) == length(before)

    assert has_element?(child, "[data-role=goal-up-next][data-kind=caught-up]")

    # The nested page returns to its goal view; the address is retained.
    receipt = open(c, ask)
    assert has_element?(receipt, "[data-role=goals-idea]", "Trying it")
    refute has_element?(receipt, "[data-action=idea-used]")
    refute has_element?(receipt, "[data-action=idea-declined]")
    saved = stored(c, ask).answers
    render_click(receipt, "idea_answer", %{"answer" => "declined"})
    assert stored(c, ask).answers == saved
    child |> element("[role=status] button", "Undo") |> render_click()
    assert stored(c, ask).answers == []
    assert has_element?(child, "[data-role=goal-up-next][data-kind=idea]", ask.title)
    assert actions(c) == before

    child = open(c, ask)
    child |> element("[data-action=idea-declined]") |> render_click()
    assert [%{answer: "declined"}] = stored(c, ask).answers
    assert has_element?(child, "[role=status]", "Saved for later")
    receipt = open(c, ask)
    assert has_element?(receipt, "[data-role=goals-idea]", "Saved for later")
    refute has_element?(receipt, "[data-action=idea-used]")
    refute has_element?(receipt, "[data-action=idea-declined]")
    assert actions(c) == before
  end

  test "plain offers, questions, another goal's idea, unaddressed and missing ideas share the hidden goal 404",
       c do
    {foreign, _} = fixture(c)

    other =
      goal!(c.owner, c.org, %{coach_agent_id: c.coach.id, rhythm: "daily", outreach: "pushy"})

    target = %{c | goal: other}
    plain = queued(target, %{kind: "offer"})
    question = queued(target)
    viewer = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, other.id, {:user, viewer.id})

    unaddressed =
      queued(target, %{
        kind: "offer",
        addressed_user_ids: [viewer.id],
        payload: %{"idea" => %{"why" => "Why", "measure" => "Measure", "steps" => ["First"]}}
      })

    conn = Plug.Test.init_test_session(c.conn, current_user_id: c.owner.id)

    {404, _, hidden_body} =
      assert_error_sent(404, fn -> get(conn, "/m/goals?goal=#{Ecto.UUID.generate()}") end)

    for id <- [
          plain.id,
          question.id,
          foreign.id,
          unaddressed.id,
          Ecto.UUID.generate(),
          "not-a-uuid"
        ] do
      {404, _, body} =
        assert_error_sent(404, fn -> get(conn, "/m/goals?goal=#{other.id}&idea=#{id}") end)

      assert body == hidden_body
    end
  end
end

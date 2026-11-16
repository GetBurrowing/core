defmodule PlatformWeb.GoalsSpaceCardTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Ecto.Query
  alias Platform.{Chat, Goals, Repo}
  alias Platform.Goals.CanvasKinds.GoalSpaceCard

  setup do
    enable_goals!()
    org = org_id!()
    owner = root_admin!()
    join_org!(owner, org)
    viewer = member!(org)
    coach = agent!()
    x = agent!()
    y = agent!()
    space = space!(org)
    for user <- [owner, viewer], do: join_space!(space.id, :user, user.id)
    for agent <- [coach, x, y], do: join_space!(space.id, :agent, agent.id)

    goal =
      goal!(owner, org, %{
        title: "Shared writing",
        coach_agent_id: coach.id,
        agent_mode: "do",
        source_key: "self_reported",
        unit: "words",
        target_value: 300
      })

    {:ok, _} = Goals.log_reading(owner, goal.id, %{value: 100})
    {:ok, _} = Goals.open_goal(owner, goal.id, {:space, space.id})
    {:ok, grant} = Goals.ensure_space_card(owner, goal.id, space.id)
    message = Repo.one!(from(m in Chat.Message, where: m.canvas_id == ^grant.card_canvas_id))

    %{
      org: org,
      owner: owner,
      viewer: viewer,
      coach: coach,
      x: x,
      y: y,
      space: space,
      goal: goal,
      grant: grant,
      message: message
    }
  end

  defp html(c, user),
    do:
      render_component(PlatformWeb.GoalsSpaceCardComponent,
        id: "test-card",
        canvas_id: c.grant.card_canvas_id,
        viewer: {:user, user.id}
      )

  defp open(c, user) do
    conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(current_user_id: user.id)
    {:ok, view, _} = live(conn, "/chat/#{c.space.id}", on_error: :warn)
    render_hook(view, "inline_canvas_mount", %{"message_id" => c.message.id})
    view
  end

  defp target(view) do
    card = view |> element("[data-role=goal-space-card]") |> render()
    [_, id] = Regex.run(~r/id="(goal-card-[^"]+)"/, card)
    with_target(view, "##{id}")
  end

  test "shared pieces, number, progress, agents and goal link", c do
    h = html(c, c.owner)

    for copy <- [
          c.goal.title,
          "Shared by",
          c.coach.name,
          "Self-reported",
          "Shown in ##{c.space.name}",
          "100",
          "300",
          "words",
          "Agents on this goal",
          "leads",
          "Not handed to this space's agents yet",
          "Hand to this space's agents",
          "Open goal"
        ],
        do: assert(h =~ copy)

    assert h =~ "width: 33%"
    assert h =~ ~s(href="/m/goals?goal=#{c.goal.id}")
    assert h =~ ~s(class="tabular-nums")
  end

  test "non-admin sees no control and crafted event refuses without mutation", c do
    view = open(c, c.viewer)
    refute has_element?(view, "[data-role=goal-space-card] button", "Hand to this space's agents")

    render_click(target(view), "goal_card_hand", %{})

    assert has_element?(
             view,
             "[data-role=goal-card-notice]",
             "You can't hand this goal to the agents here."
           )

    assert has_element?(view, "[data-role=goal-card-notice][role=alert]")
    assert Repo.one!(from(gr in Goals.Grant, where: gr.id == ^c.grant.id)).handed_at == nil
  end

  test "admin hand lists two contributors and take back clears it", c do
    view = open(c, c.owner)

    view
    |> element("[data-role=goal-space-card] button", "Hand to this space's agents")
    |> render_click()

    assert has_element?(view, "[data-role=goal-card-agents]", c.x.name)
    assert has_element?(view, "[data-role=goal-card-agents]", c.y.name)
    assert has_element?(view, "[data-role=goal-card-controls]", "Handed to this space's agents")
    view |> element("[data-role=goal-space-card] button", "Take back") |> render_click()

    assert has_element?(
             view,
             "[data-role=goal-card-agents]",
             "Not handed to this space's agents yet"
           )

    assert Repo.one!(from(gr in Goals.Grant, where: gr.id == ^c.grant.id)).handed_at == nil
  end

  test "no coach, unavailable coach, no number and cannot-measure states", c do
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{coach_agent_id: nil})
    h = html(c, c.owner)
    assert h =~ "Pick a coach on the goal page first"
    refute h =~ " and " <> c.coach.name
    other = agent!()
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{coach_agent_id: other.id, source_key: nil})
    h = html(c, c.owner)
    assert h =~ "Add #{other.name} to this space first"
    assert h =~ "Target: 300 words."
    refute h =~ "goal-card-progress"
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{target_value: nil, unit: nil})
    assert html(c, c.owner) =~ "No number to follow yet"
  end

  test "closed and lookalike cards disclose no goal content", c do
    {:ok, _} = Goals.close_goal(c.owner, c.goal.id, {:space, c.space.id})

    for user <- [c.owner, c.viewer] do
      h = html(c, user)
      assert h =~ "This goal isn't shown here."
      refute h =~ c.goal.title
      refute Floki.text(Floki.parse_fragment!(h)) =~ "100"
    end
  end

  test "kind restricts props and disabled document uses core fallback", c do
    assert :ok = GoalSpaceCard.validate_props(%{"goal_id" => c.goal.id})

    for props <- [%{}, %{"goal_id" => "invalid"}, %{"goal_id" => c.goal.id, "title" => "bad"}],
        do: assert(match?({:error, _}, GoalSpaceCard.validate_props(props)))

    refute GoalSpaceCard.inline_opens_canvas?()
    Application.put_env(:goals, :enabled, false)
    assert Goals.Extension.canvas_kinds() == []
    refute "goal_space_card" in Chat.Canvas.Kinds.names()

    h =
      render_component(&PlatformWeb.Chat.CanvasRenderer.canvas_document/1,
        canvas: Chat.get_canvas(c.grant.card_canvas_id),
        viewer: {:user, c.owner.id}
      )

    assert is_binary(h)
    refute h =~ c.goal.title
  end
end

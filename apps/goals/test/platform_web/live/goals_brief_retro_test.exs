defmodule PlatformWeb.GoalsBriefRetroTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  import Platform.Goals.PaceFixtures
  alias Platform.Goals
  alias Platform.Goals.Clock
  alias Platform.Memory.Insights.Disseminator

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
    {:ok, _} =
      Platform.Access.Grants.grant(%{
        principal: user,
        permission: "goals.use",
        resource: {:space, space!(org).id}
      })
  end

  defp build, do: Disseminator.run(now: Clock.now(), notifications_module: Recorder)

  defp open(conn, user),
    do:
      live(
        Plug.Test.init_test_session(conn, current_user_id: user.id),
        "/inbox/briefing/#{date()}"
      )

  defp card(kind), do: "[data-role=goals-brief-card][data-kind='#{kind}']"
  defp action_button(kind, action), do: card(kind) <> " [data-action='#{action}']"

  defp change(c, kind \\ :check_in) do
    proposal =
      if kind == :check_in,
        do: %{
          "check_in_change" => %{
            "summary" => "Make room for practice",
            "set" => %{"rhythm" => "weekdays"}
          }
        },
        else: %{
          "goal_change" => %{
            "summary" => "Choose a smaller target",
            "kind" => "target",
            "set" => %{"target_value" => 600}
          },
          "stalled" => true,
          "window" => %{"flat_retros" => 3}
        }

    retro(c, proposal)
  end

  test "retro shows scored predictions, link, noted receipt and Undo", c do
    entry =
      retro(c, %{
        "verdicts" => [
          %{"entry_id" => Ecto.UUID.generate(), "verdict" => "came_true"},
          %{"entry_id" => Ecto.UUID.generate(), "verdict" => "did_not"},
          %{"entry_id" => Ecto.UUID.generate(), "verdict" => "too_early"},
          %{"entry_id" => Ecto.UUID.generate(), "verdict" => "not_scored"}
        ]
      })

    build()
    {:ok, view, html} = open(c.conn, c.owner)
    assert html =~ "Goal · retro"
    assert has_element?(view, card(:retro), "Looked back")
    assert has_element?(view, card(:retro), "A useful review")
    assert has_element?(view, card(:retro), "1 of 2 predictions came true.")

    assert has_element?(
             view,
             "a[href='/m/goals?goal=#{c.goal.id}&retro=#{entry.id}']",
             "Read the retro"
           )

    view |> element(action_button(:retro, "retro_noted"), "Looks good") |> render_click()
    assert has_element?(view, card(:retro) <> " [data-role=goals-brief-receipt]", "Noted")
    view |> element(action_button(:retro, "retro_noted"), "Undo") |> render_click()
    assert has_element?(view, action_button(:retro, "retro_noted"), "Looks good")
    assert has_element?(view, card(:retro) <> " a", "See the journey ›")
  end

  test "Switch changes settings, shows receipt and removes the call; a second event writes nothing",
       c do
    entry = change(c)
    build()
    {:ok, view, html} = open(c.conn, c.owner)
    assert html =~ "1 need your call"
    assert has_element?(view, card(:retro_change), "Change how we check in?")
    assert has_element?(view, card(:retro_change), "Switch changes:")

    assert has_element?(
             view,
             card(:retro_change),
             "The check-in stays as it is until you choose."
           )

    view |> element(action_button(:retro_change, "retro_switch"), "Switch") |> render_click()
    assert {:ok, goal} = Goals.get_goal(c.owner, c.goal.id)
    assert goal.rhythm == "weekdays"
    assert has_element?(view, card(:retro_change), "Switched")
    refute render(view) =~ "1 need your call"
    {:ok, before} = Goals.list_entries(c.owner, c.goal.id)
    render_click(view, "retro_switch", %{item_id: note_id(c, entry), entry_id: entry.id})
    assert {:ok, ^before} = Goals.list_entries(c.owner, c.goal.id)
  end

  test "Keep it leaves the goal equal and a crafted foreign entry changes nothing", c do
    entry = change(c)
    other = member!(c.org)
    foreign_goal = goal!(other, c.org, %{coach_agent_id: c.coach.id})
    foreign = change(%{c | owner: other, goal: foreign_goal})
    build()
    {:ok, view, _} = open(c.conn, c.owner)
    {:ok, before} = Goals.get_goal(c.owner, c.goal.id)
    {:ok, foreign_before} = Goals.get_goal(other, foreign_goal.id)
    render_click(view, "retro_switch", %{item_id: note_id(c, entry), entry_id: foreign.id})
    assert {:ok, ^before} = Goals.get_goal(c.owner, c.goal.id)
    assert {:ok, ^foreign_before} = Goals.get_goal(other, foreign_goal.id)
    view |> element(action_button(:retro_change, "retro_keep"), "Keep it") |> render_click()
    assert {:ok, ^before} = Goals.get_goal(c.owner, c.goal.id)
    assert has_element?(view, card(:retro_change), "The check-in stays as it is.")
    refute has_element?(view, action_button(:retro_change, "retro_switch"))
    {:ok, before_entries} = Goals.list_entries(c.owner, c.goal.id)
    render_click(view, "retro_keep", %{item_id: note_id(c, entry), entry_id: entry.id})
    assert {:ok, ^before_entries} = Goals.list_entries(c.owner, c.goal.id)
  end

  test "flat goal change card has exact controls and changed receipt", c do
    change(c, :goal)
    build()
    {:ok, view, _} = open(c.conn, c.owner)
    assert has_element?(view, card(:retro), "The number has not moved across 3 retros.")
    assert has_element?(view, card(:retro_change), "Change the goal?")
    assert has_element?(view, card(:retro_change), "The number has not moved across 3 retros.")
    assert has_element?(view, card(:retro_change), "This would:")
    assert has_element?(view, action_button(:retro_change, "retro_keep"), "Keep the goal")

    view
    |> element(action_button(:retro_change, "retro_switch"), "Change the goal")
    |> render_click()

    assert has_element?(view, card(:retro_change), "Changed")
    assert {:ok, %{target_value: value}} = Goals.get_goal(c.owner, c.goal.id)
    assert Decimal.equal?(value, 600)
  end

  test "kept goal copy and unscored predictions do not count a miss", c do
    change(c, :goal)
    build()
    {:ok, view, _} = open(c.conn, c.owner)
    refute has_element?(view, card(:retro), "predictions came true")
    view |> element(action_button(:retro_change, "retro_keep"), "Keep the goal") |> render_click()
    assert has_element?(view, card(:retro_change), "The goal stays as it is.")
  end

  test "slowdown notice has no button and arrives only in its original brief", c do
    for _ <- 1..3, do: ignore_brief(c)
    day = date()
    build()
    {:ok, view, html} = open(c.conn, c.owner)
    assert has_element?(view, card(:notice), "Goal · slowed down")
    assert has_element?(view, card(:notice), "Nothing from the last 3 briefs was answered")
    assert has_element?(view, card(:notice), "about once a week")
    assert has_element?(view, card(:notice), "keeps one thing waiting at most")
    assert has_element?(view, card(:notice), "the usual rhythm comes back.")
    refute has_element?(view, card(:notice) <> " button")
    assert html =~ "handled"
    assert {:ok, %{calls: 0}} = Goals.brief_summary(c.owner, day)
    advance()
    build()
    {:ok, tomorrow, _} = open(c.conn, c.owner)
    refute has_element?(tomorrow, card(:notice))
    assert {:ok, old} = Goals.brief_items(c.owner, day)
    assert Enum.count(old, &(&1.kind == :notice)) == 1
  end

  test "override pacing uses less often rather than false calendar words", c do
    with_limits(%{paced_every: %{"daily" => 3}})

    {:ok, _} =
      Goals.add_entry(c.coach, c.goal.id, %{
        kind: "wait",
        title: "Slowed down to match you",
        body: "Notice",
        occurred_at: Clock.now(),
        details: %{"pace" => "slowed", "ignored_briefs" => 3, "every" => 3}
      })

    build()
    {:ok, view, _} = open(c.conn, c.owner)
    assert has_element?(view, card(:notice), "check-ins now come less often")
  end

  test "report pace behind, on track and absent including cannot measure", c do
    today = DateTime.to_date(Clock.now())

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{
        value: 500,
        measured_at: DateTime.add(Clock.now(), -40, :day)
      })

    {:ok, [stop]} =
      Goals.put_stops(c.owner, c.goal.id, [
        %{label: "Finish", target_value: 1000, due_on: Date.add(today, 60)}
      ])

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{
        value: 699,
        measured_at: DateTime.add(Clock.now(), -1, :day)
      })

    action(c)
    build()
    {:ok, view, _} = open(c.conn, c.owner)
    assert has_element?(view, card(:report), "A little behind the hoped-for pace.")
    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: 700, measured_at: Clock.now()})
    {:ok, view, _} = open(c.conn, c.owner)
    assert has_element?(view, card(:report), "On the hoped-for pace.")
    Goals.update_stop(c.owner, c.goal.id, stop.id, %{due_on: nil})
    {:ok, view, _} = open(c.conn, c.owner)
    refute has_element?(view, card(:report), "hoped-for pace")
    Goals.update_goal(c.owner, c.goal.id, %{source_key: nil})
    {:ok, view, _} = open(c.conn, c.owner)
    refute has_element?(view, card(:report), "Where we are:")
  end

  test "flag, permission and ownership gates hide the cards with a granted-owner control", c do
    retro(c)
    viewer = member!(c.org)
    grant!(viewer, c.org)
    Goals.open_goal(c.owner, c.goal.id, {:user, viewer.id})
    build()
    {:ok, view, _} = open(c.conn, c.owner)
    assert has_element?(view, card(:retro))
    Goals.prepare_brief(viewer, date())
    {:ok, view, _} = open(c.conn, viewer)
    refute has_element?(view, card(:retro))
    old = Application.get_env(:goals, :enabled)
    Application.put_env(:goals, :enabled, false)
    on_exit(fn -> Application.put_env(:goals, :enabled, old) end)
    {:ok, view, _} = open(c.conn, c.owner)
    refute has_element?(view, card(:retro))
  end

  defp note_id(c, entry) do
    {:ok, items} = Goals.brief_items(c.owner, date())
    Enum.find(items, &(&1.kind == :retro && &1.entry_id == entry.id)).id
  end
end

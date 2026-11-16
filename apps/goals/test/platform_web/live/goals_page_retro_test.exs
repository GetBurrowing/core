defmodule PlatformWeb.GoalsPageRetroTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Platform.Goals.BriefFixtures
  import Platform.Goals.PaceFixtures
  alias Platform.Goals
  alias Platform.Goals.Clock

  setup do
    c = setup_brief()
    Platform.Goals.OutcomeFixtures.put_now(~U[2026-02-10 12:00:00.000000Z])

    {:ok, _} =
      Platform.Access.Grants.grant(%{
        principal: c.owner,
        permission: "goals.use",
        resource: {:space, space!(c.org).id}
      })

    c
  end

  defp page(c) do
    {:ok, parent, _} =
      live(
        Plug.Test.init_test_session(c.conn, current_user_id: c.owner.id),
        "/m/goals?goal=#{c.goal.id}"
      )

    find_live_child(parent, "ext-page-goals")
  end

  test "retro links cover the caught-up card, notebook and reached journey stop", c do
    view = page(c)
    refute render(view) =~ "Read the last retro"

    {:ok, stops} =
      Goals.put_stops(c.owner, c.goal.id, [
        %{label: "First", target_value: 100, reached_on: ~D[2026-02-03]}
      ])

    {:ok, entry} =
      Goals.add_entry(c.coach, c.goal.id, %{
        kind: "retro",
        title: "Reached it",
        stop_id: hd(stops).id
      })

    view = page(c)
    assert has_element?(view, "[data-role=goal-up-next] a", "Read the last retro")

    assert has_element?(
             view,
             "[data-role=goal-notebook] a[href='/m/goals?goal=#{c.goal.id}&retro=#{entry.id}']",
             "Read the retro"
           )

    assert has_element?(view, "[data-role=goal-stop] a", "Read the retro")
    assert render(view) =~ "looks back every"
  end

  test "trying pills show every verdict state and stopped dates", c do
    actions =
      for i <- 1..6 do
        {:ok, e} = Goals.add_entry(c.coach, c.goal.id, %{kind: "action", title: "Action #{i}"})
        e
      end

    [working, failed, early, none, stopped, _started] = actions

    retro(c, %{
      "dropped" => [%{"entry_id" => stopped.id}],
      "verdicts" =>
        for(
          {e, verdict} <- [
            {working, "came_true"},
            {failed, "did_not"},
            {early, "too_early"},
            {none, "not_scored"}
          ],
          do: %{"entry_id" => e.id, "verdict" => verdict}
        )
    })

    view = page(c)

    for text <- ["Working", "Not working", "Too early to tell", "Just started", "Stopped 10 Feb"],
        do: assert(render(view) =~ text)

    refute has_element?(view, "[data-entry-id='#{none.id}'] [data-role=goal-prediction-state]")
  end

  test "pace sentence and both list pills come from expected pace; missing due and source omit them",
       c do
    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{
        value: 500,
        measured_at: DateTime.add(Clock.now(), -40, :day)
      })

    {:ok, _} =
      Goals.put_stops(c.owner, c.goal.id, [
        %{
          label: "Thousand",
          target_value: 1000,
          due_on: Date.add(DateTime.to_date(Clock.now()), 60)
        }
      ])

    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: 699, measured_at: Clock.now()})
    view = page(c)

    assert has_element?(
             view,
             "[data-role=goal-pace]",
             "We'd hoped for about 700 by today, so we're a little behind."
           )

    assert has_element?(view, "[data-role=goal-pace-pill]", "A little behind")

    {:ok, _} =
      Goals.log_reading(c.owner, c.goal.id, %{
        value: 700,
        measured_at: DateTime.add(Clock.now(), 1, :microsecond)
      })

    view = page(c)
    assert has_element?(view, "[data-role=goal-pace]", "so we're on track.")
    assert has_element?(view, "[data-role=goal-pace-pill]", "On track")
    {:ok, _} = Goals.put_stops(c.owner, c.goal.id, [%{label: "Thousand", target_value: 1000}])
    refute has_element?(page(c), "[data-role=goal-pace]")
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{source_key: nil})
    refute has_element?(page(c), "[data-role=goal-pace-pill]")
  end

  test "retro settings use the existing writer and round trip usual, more and less", c do
    view = page(c)

    for {value, expected} <- [{"3", 3}, {"14", 14}, {"", nil}] do
      render_click(view, "open_settings")
      assert render(view) =~ "Usual (every 7 check-ins)"
      render_click(view, "settings_select", %{"field" => "retro_every", "value" => value})
      render_click(view, "save_settings")
      assert {:ok, goal} = Goals.get_goal(c.owner, c.goal.id)
      assert goal.retro_every == expected
    end
  end
end

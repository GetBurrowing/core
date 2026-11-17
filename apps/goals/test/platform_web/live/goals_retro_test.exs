defmodule PlatformWeb.GoalsRetroTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures
  import Platform.Goals.BriefFixtures
  import Platform.Goals.PaceFixtures
  alias Platform.Goals

  setup do
    c = setup_brief()
    Platform.Goals.OutcomeFixtures.put_now(~U[2026-02-10 12:00:00.000000Z])
    c
  end

  defp open(conn, user, goal, entry) do
    {:ok, parent, _} =
      live(
        Plug.Test.init_test_session(conn, current_user_id: user.id),
        "/m/goals?goal=#{goal.id}&retro=#{entry.id}"
      )

    find_live_child(parent, "ext-page-goals")
  end

  defp change, do: %{"summary" => "Weekdays fit better", "set" => %{"rhythm" => "weekdays"}}

  test "full retro renders stored sections, predictions and next push without a second answer path",
       c do
    {:ok, stops} =
      Goals.put_stops(c.owner, c.goal.id, [
        %{label: "First hundred", target_value: 100, reached_on: ~D[2026-02-03]},
        %{label: "Next hundred", target_value: 200}
      ])

    {:ok, takeaway} =
      Goals.add_entry(c.coach, c.goal.id, %{
        kind: "takeaway",
        title: "Make it small",
        sources: [%{"name" => "Notes"}]
      })

    {:ok, action} = Goals.add_entry(c.coach, c.goal.id, %{kind: "action", title: "Long sessions"})

    details = %{
      "worked" => [
        %{"label" => "Small sessions", "percent" => 70, "note" => "Easy to repeat"},
        %{"label" => "A useful habit"}
      ],
      "didnt_work" => [%{"text" => "Long sessions did not fit"}],
      "dropped" => [%{"entry_id" => action.id, "reason" => "Too much"}],
      "learned" => ["Consistency helps"],
      "next_push" => %{
        "title" => "Keep going",
        "suggestions" =>
          for(
            tag <- ~w(keep start stop),
            do: %{
              "tag" => tag,
              "title" => tag <> " a habit",
              "why" => "A useful step",
              "takeaway_id" => takeaway.id
            }
          )
      },
      "check_in_change" => change(),
      "verdicts" => [
        %{
          "prediction" => "Small work helps",
          "verdict" => "came_true",
          "predicted_change" => "20",
          "actual_change" => "30",
          "predicted_by" => "2026-02-03"
        },
        %{
          "prediction" => "Long work helps",
          "verdict" => "did_not",
          "predicted_change" => "40",
          "actual_change" => "30",
          "predicted_by" => "2026-02-03"
        },
        %{
          "prediction" => "We cannot know",
          "verdict" => "cannot_measure",
          "predicted_change" => "9",
          "actual_change" => nil
        }
      ]
    }

    {:ok, entry} =
      Goals.add_entry(c.coach, c.goal.id, %{
        kind: "retro",
        title: "First hundred: reached",
        body: "A useful review",
        stop_id: hd(stops).id,
        details: details
      })

    view = open(c.conn, c.owner, c.goal, entry)

    for text <- [
          "Looking back",
          "Written by",
          "A useful review",
          "Where the 100 came from",
          "70%",
          "What didn't work",
          "Dropped: Long sessions",
          "What we learned",
          "Consistency helps",
          "How the predictions did",
          "Came true",
          "Didn't happen",
          "Couldn't measure",
          "Expected 20",
          "It moved 30",
          "Next push: Keep going",
          "Keep",
          "Start",
          "Stop",
          "From: Make it small",
          "Change how we check in?",
          "Switch changes:",
          "Weekdays fit better",
          "The check-in stays as it is until you choose."
        ] do
      assert render(view) |> Floki.parse_fragment!() |> Floki.text() =~ text
    end

    assert has_element?(view, "[data-role=goal-journey]", "next push")
    refute has_element?(view, "[data-verdict=cannot_measure] [data-role=retro-prediction-number]")
    assert has_element?(view, "[data-verdict=came_true] [data-role=retro-prediction-number]")
    refute render(view) =~ "Agree"
    refute render(view) =~ "Start the next push"
    view |> element("button[phx-click=retro_switch]") |> render_click()
    assert {:ok, goal} = Goals.get_goal(c.owner, c.goal.id)
    assert goal.rhythm == "weekdays"
    assert has_element?(view, "[data-role=retro-change-result]", "Switched.")

    assert has_element?(
             view,
             "[data-role=retro-change-result]",
             "Check-ins: every day -> weekdays"
           )

    reloaded = open(c.conn, c.owner, c.goal, entry)

    assert has_element?(
             reloaded,
             "[data-role=retro-change-result]",
             "Check-ins: every day -> weekdays"
           )

    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{rhythm: "weekly"})
    later = open(c.conn, c.owner, c.goal, entry)

    assert has_element?(
             later,
             "[data-role=retro-change-result]",
             "Check-ins: every day -> weekdays"
           )

    view
    |> form("[data-role=goals-brief-ask]", %{question: "What helped most?"})
    |> render_submit()

    assert render(view) =~ "Sent."
  end

  test "target change is grouped without decimal zeros in the retro and brief receipts", c do
    {:ok, _} =
      Goals.update_goal(c.owner, c.goal.id, %{target_value: "1000.000", unit: "subscribers"})

    entry =
      retro(c, %{
        "goal_change" => %{
          "kind" => "target",
          "summary" => "Aim for 600",
          "set" => %{"target_value" => "600.000"}
        }
      })

    expected = "Target: 1,000 -> 600 subscribers"
    view = open(c.conn, c.owner, c.goal, entry)
    assert render(view) |> Floki.parse_fragment!() |> Floki.text() =~ expected
    assert {:ok, _} = Goals.prepare_brief(c.owner, date())
    assert {:ok, items} = Goals.brief_items(c.owner, date())
    assert Enum.find(items, &(&1.kind == :retro_change)).change.lines == [expected]
    view |> element("button[phx-click=retro_switch]") |> render_click()
    assert has_element?(view, "[data-role=retro-change-result]", expected)
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{target_value: 900, unit: "people"})
    reloaded = open(c.conn, c.owner, c.goal, entry)
    assert has_element?(reloaded, "[data-role=retro-change-result]", expected)
    assert {:ok, items} = Goals.brief_items(c.owner, date())
    assert Enum.find(items, &(&1.kind == :retro_change)).change.lines == [expected]
  end

  test "Spanish shape omits empty sections; Keep changes no goal setting and cannot be repeated",
       c do
    entry = retro(c, %{"learned" => ["Small steps"], "check_in_change" => change()})
    {:ok, before} = Goals.get_goal(c.owner, c.goal.id)
    view = open(c.conn, c.owner, c.goal, entry)

    for role <- ~w(retro-worked retro-didnt-work retro-next-push),
        do: refute(has_element?(view, "[data-role=#{role}]"))

    view |> element("button[phx-click=retro_keep]") |> render_click()
    assert {:ok, ^before} = Goals.get_goal(c.owner, c.goal.id)
    assert has_element?(view, "[data-role=retro-change-result]", "The check-in stays as it is.")
    render_click(view, "retro_switch", %{"entry_id" => entry.id})
    assert {:ok, ^before} = Goals.get_goal(c.owner, c.goal.id)
  end

  test "viewers read without decision pills or ask box and stalled proposals name the goal change",
       c do
    viewer = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, viewer.id})

    entry =
      retro(c, %{
        "stalled" => true,
        "window" => %{"flat_retros" => 3},
        "goal_change" => %{
          "kind" => "target",
          "summary" => "Aim smaller",
          "set" => %{"target_value" => 600}
        }
      })

    view = open(c.conn, viewer, c.goal, entry)
    assert render(view) =~ "The number has not moved across 3 retros."
    assert render(view) =~ "Change the goal?"
    refute has_element?(view, "button[phx-click=retro_switch]")
    refute has_element?(view, "[data-role=retro-ask]")
    {:ok, before} = Goals.get_goal(c.owner, c.goal.id)
    render_click(view, "retro_switch", %{"entry_id" => entry.id})
    assert {:ok, ^before} = Goals.get_goal(c.owner, c.goal.id)
  end

  test "wrong goal, wrong kind and malformed retro ids have the hidden goal response", c do
    other = goal!(c.owner, c.org)
    {:ok, entry} = Goals.add_entry(c.owner, other.id, %{kind: "retro", title: "Elsewhere"})
    {:ok, action} = Goals.add_entry(c.owner, c.goal.id, %{kind: "action", title: "Not a retro"})
    conn = Plug.Test.init_test_session(c.conn, current_user_id: c.owner.id)

    {404, _, hidden} =
      assert_error_sent(404, fn -> get(conn, "/m/goals?goal=#{Ecto.UUID.generate()}") end)

    for id <- [entry.id, action.id, "not-a-uuid"] do
      {404, _, body} =
        assert_error_sent(404, fn -> get(conn, "/m/goals?goal=#{c.goal.id}&retro=#{id}") end)

      assert body == hidden
    end
  end
end

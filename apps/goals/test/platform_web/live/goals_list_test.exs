defmodule PlatformWeb.GoalsListTest do
  @moduledoc """
  The Goals list (task 01a1dfc1, Goals 4/8 stage 2), against canvas 01a15ef6
  node `p` screen `list`. Every number is a REAL `goal_readings` row written
  through `Platform.Goals.log_reading/3` or `measure_goal/2`; nothing about
  how the number is read is stubbed. Sets the global `:goals, :enabled`, so
  not async.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures

  alias Platform.Goals

  setup do
    enable_goals!()
    org_id = org_id!()
    user = member!(org_id)

    {:ok, org_id: org_id, user: user}
  end

  defp open(conn, user, path \\ "/m/goals") do
    {:ok, view, _html} =
      live(Plug.Test.init_test_session(conn, current_user_id: user.id), path)

    find_live_child(view, "ext-page-goals")
  end

  defp row(id), do: "[data-role='goals-row'][data-goal-id='#{id}']"

  defp number(child, id),
    do: child |> element(row(id) <> " [data-role='goals-row-number']") |> render() |> text()

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text() |> String.trim()

  describe "the list screen" do
    test "desktop header, empty detail pane, phone header and the New goal slots", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      goal!(user, org_id)
      child = open(conn, user)

      assert has_element?(child, "[data-pane='goals'] h1", "Goals")

      assert has_element?(
               child,
               "[data-pane='goals'] p",
               "What you're working towards, and how it's going. Only you see your goals until you open them up."
             )

      assert has_element?(child, "[data-role='goals-detail-empty']", "Select a goal")
      assert has_element?(child, "[data-role='goals-phone'] h1", "Goals")
      assert has_element?(child, "[data-role='goals-back'][aria-label='Back to More']")

      assert child
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.find("[data-goals-slot='new-goal']")
             |> length() == 2
    end

    test "with no goals shows the minimal empty state", %{conn: conn, user: user} do
      child = open(conn, user)
      assert has_element?(child, "[data-role='goals-empty-title']", "No goals yet")

      assert has_element?(
               child,
               "[data-role='goals-empty-body']",
               "Goals you create, and goals other people open up to you, show up here."
             )

      refute has_element?(child, "[data-role='goals-row']")
    end

    test "rows link to ?goal=, and a goal the user cannot see is absent", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      mine = goal!(user, org_id, %{title: "Mine"})
      hidden = goal!(member!(org_id), org_id, %{title: "Not yours"})
      child = open(conn, user)

      assert has_element?(child, row(mine.id) <> " a[href='/m/goals?goal=#{mine.id}']")

      assert has_element?(
               child,
               "a[data-role='goals-phone-row'][href='/m/goals?goal=#{mine.id}']"
             )

      refute has_element?(child, row(hidden.id))
      refute render(child) =~ "Not yours"
    end

    test "the open goal's row is selected", %{conn: conn, user: user, org_id: org_id} do
      a = goal!(user, org_id, %{title: "A"})
      b = goal!(user, org_id, %{title: "B"})
      child = open(conn, user, "/m/goals?goal=#{a.id}")

      assert has_element?(child, row(a.id) <> "[data-selected='true'] a[aria-current='page']")
      assert has_element?(child, row(b.id) <> "[data-selected='false']")
      refute has_element?(child, "[data-role='goals-detail-empty']")
      # The phone list steps aside for the goal view.
      refute has_element?(child, "[data-role='goals-phone']")
    end
  end

  describe "the kind line and the privacy chip" do
    test "coach in mode do leads, mode coach coaches; private goals say Only you", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      coach = agent!()
      lead = goal!(user, org_id, %{agent_mode: "do"})
      {:ok, _} = Goals.update_goal(user, lead.id, %{coach_agent_id: coach.id})
      practice = goal!(user, org_id, %{agent_mode: "coach"})
      {:ok, _} = Goals.update_goal(user, practice.id, %{coach_agent_id: coach.id})
      alone = goal!(user, org_id)

      child = open(conn, user)

      assert has_element?(
               child,
               row(lead.id) <> " [data-role='goals-row-kind']",
               "Goal · #{coach.name} leads"
             )

      assert has_element?(
               child,
               row(practice.id) <> " [data-role='goals-row-kind']",
               "Goal · #{coach.name} coaches"
             )

      [first | _] = String.split(user.name)

      assert has_element?(
               child,
               row(alone.id) <> " [data-role='goals-row-kind']",
               "Goal · #{first}"
             )

      assert has_element?(
               child,
               row(alone.id) <> " [data-role='goal-privacy'][data-shared='false']",
               "Only you"
             )
    end

    test "an opened goal reads Shared with {names}", %{conn: conn, user: user, org_id: org_id} do
      goal = goal!(user, org_id)
      {:ok, _} = Goals.open_goal(user, goal.id, {:team, org_id})
      team = Platform.Repo.get!(Platform.Tenancy.Org, org_id).name

      child = open(conn, user)

      assert has_element?(
               child,
               row(goal.id) <> " [data-role='goals-row-kind']",
               "Goal · Shared with #{team}"
             )

      assert has_element?(
               child,
               row(goal.id) <> " [data-role='goal-privacy'][data-shared='true']",
               "Shared: #{team}"
             )
    end

    test "someone else's goal reads Shared by {owner}", %{conn: conn, user: user, org_id: org_id} do
      owner = member!(org_id)
      goal = goal!(owner, org_id)
      {:ok, _} = Goals.open_goal(owner, goal.id, {:user, user.id})

      child = open(conn, user)

      assert has_element?(
               child,
               row(goal.id) <> " [data-role='goals-row-kind']",
               "Goal · Shared by #{owner.name}"
             )

      assert has_element?(
               child,
               row(goal.id) <> " [data-role='goal-privacy']",
               "Shared by #{owner.name}"
             )
    end
  end

  describe "the number line" do
    test "a self-reported goal: Target before a reading, then the reading, formatted", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      goal =
        goal!(user, org_id, %{source_key: "self_reported", unit: "words", target_value: 300})

      child = open(conn, user)
      assert number(child, goal.id) == "Target: 300 words"
      assert has_element?(child, row(goal.id) <> " [data-role='goals-row-time']", "Added ")
      assert has_element?(child, row(goal.id) <> "[data-numberless='false']")

      {:ok, _} = Goals.log_reading(user, goal.id, %{value: 180})
      child = open(conn, user)
      assert number(child, goal.id) == "180 of 300 words"
      assert has_element?(child, row(goal.id) <> " [data-role='goals-row-time']", "Updated ")
      assert has_element?(child, "a[data-goal-id='#{goal.id}']", "180 of 300 words")

      {:ok, _} = Goals.update_goal(user, goal.id, %{target_value: 2000})
      {:ok, _} = Goals.log_reading(user, goal.id, %{value: Decimal.new("1250.50")})
      child = open(conn, user)
      assert number(child, goal.id) == "1,250.5 of 2,000 words"
    end

    test "the current stop's target wins over the goal's", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      goal =
        goal!(user, org_id, %{
          source_key: "self_reported",
          unit: "subscribers",
          target_value: 1_000_000
        })

      {:ok, _} =
        Goals.put_stops(user, goal.id, [
          %{label: "First 1,000", target_value: 1000},
          %{label: "1M"}
        ])

      {:ok, _} = Goals.log_reading(user, goal.id, %{value: 640})

      assert number(open(conn, user), goal.id) == "640 of 1,000 subscribers"
    end

    test "no source and an unregistered source read Target only, with no other digit", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      none = goal!(user, org_id, %{title: "No source", unit: "pages", target_value: 24})

      unknown =
        goal!(user, org_id, %{
          title: "Odd source",
          source_key: "not_a_source",
          unit: "pages",
          target_value: 24
        })

      child = open(conn, user)

      for goal <- [none, unknown] do
        line = number(child, goal.id)
        assert line == "Target: 24 pages"
        assert Regex.scan(~r/\d+/, line) == [["24"]]

        kind_and_title =
          child |> element(row(goal.id) <> " [data-role='goals-row-title']") |> render() |> text()

        refute kind_and_title =~ ~r/\d/
      end
    end

    test "a task-count goal shows its measured number", %{conn: conn, user: user, org_id: org_id} do
      project =
        Platform.Repo.insert!(%Platform.Tasks.Project{
          org_id: org_id,
          name: "Redesign",
          slug: "redesign-#{unique()}"
        })

      for i <- 1..3 do
        Platform.Repo.insert!(%Platform.Tasks.Task{
          project_id: project.id,
          title: "piece #{i}",
          status: "backlog"
        })
      end

      goal =
        goal!(user, org_id, %{
          source_key: "task_count",
          source_settings: %{"project_id" => project.id, "count" => "open"},
          unit: "pieces",
          target_value: 24
        })

      {:ok, {:reading, _}} = Goals.measure_goal(user, goal.id)
      assert number(open(conn, user), goal.id) == "3 of 24 pieces"
    end

    test "no unit or no target: No number to follow yet, with the muted tile", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      bare = goal!(user, org_id, %{title: "Hire a second designer"})
      no_unit = goal!(user, org_id, %{target_value: 5})
      child = open(conn, user)

      for goal <- [bare, no_unit] do
        assert number(child, goal.id) == "No number to follow yet"

        assert has_element?(
                 child,
                 row(goal.id) <>
                   "[data-numberless='true'] [data-role='goal-tile'][data-muted='true']"
               )

        assert has_element?(child, row(goal.id) <> " [data-role='goals-row-title'].font-normal")
      end
    end

    test "a viewer who is not the owner sees the same number line", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      owner = member!(org_id)

      goal =
        goal!(owner, org_id, %{source_key: "self_reported", unit: "words", target_value: 300})

      {:ok, _} = Goals.log_reading(owner, goal.id, %{value: 180})
      {:ok, _} = Goals.open_goal(owner, goal.id, {:user, user.id})

      assert number(open(conn, user), goal.id) == "180 of 300 words"
    end
  end

  test "format_number/1 groups thousands and drops trailing zeros" do
    f = &PlatformWeb.GoalsComponents.format_number/1
    assert f.(Decimal.new("1250.50")) == "1,250.5"
    assert f.(Decimal.new("1000000")) == "1,000,000"
    assert f.(Decimal.new("300.00")) == "300"
    assert f.(Decimal.new("-1234.5")) == "-1,234.5"
    assert f.(Decimal.new("0.25")) == "0.25"
    assert f.(999) == "999"
  end
end

defmodule PlatformWeb.GoalsShellTest do
  @moduledoc """
  Goals in the app shell (task 01a1dfc1, Goals 4/8 stage 1): the rail row,
  `/m/goals` through core's generic extension page, the `goals.use` gate,
  and one 404 for every goal a user may not open. Sets the global
  `:goals, :enabled`, so not async.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures

  alias Platform.Access.Scope
  alias Platform.Goals
  alias PlatformWeb.Components.IconRail

  setup do
    previous = Application.fetch_env(:goals, :enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :enabled, value)
        :error -> Application.delete_env(:goals, :enabled)
      end
    end)

    org_id = org_id!()
    {:ok, org_id: org_id, user: user_without_goals_use!() |> join_org!(org_id)}
  end

  defp set_enabled(value), do: Application.put_env(:goals, :enabled, value)
  defp login(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp keys(rows), do: Enum.map(rows, & &1.key)

  describe "with GOALS_ENABLED off" do
    setup do
      set_enabled(false)
    end

    test "/m/goals is a 404", %{conn: conn, user: user} do
      assert_error_sent(404, fn -> get(login(conn, user), "/m/goals") end)
    end

    test "another page's desktop sidebar has no Goals link", %{conn: conn, user: user} do
      {:ok, _view, html} = live(login(conn, user), "/tasks")
      assert html =~ ~s(href="/tasks")
      refute html =~ ~s(href="/m/goals")
    end
  end

  describe "with GOALS_ENABLED on, without goals.use" do
    setup do
      set_enabled(true)
    end

    test "/m/goals redirects to access denied for goals", %{conn: conn, user: user} do
      assert {:error, {:redirect, %{to: "/access-denied?module=goals"}}} =
               live(login(conn, user), "/m/goals")
    end

    test "no rail lists Goals", %{user: user} do
      scope = Scope.for_user(user)
      refute :goals in keys(IconRail.desktop_more_rows(scope, false))
      refute :goals in keys(IconRail.more_sheet_rows(scope, false))
    end
  end

  describe "with GOALS_ENABLED on and goals.use" do
    setup %{user: user} do
      set_enabled(true)
      %{user: grant_goals_use!(user)}
    end

    test "the page mounts and the desktop sidebar links to it", %{conn: conn, user: user} do
      {:ok, view, html} = live(login(conn, user), "/m/goals")
      child = find_live_child(view, "ext-page-goals")

      assert has_element?(child, "[data-role='goals-page']")
      assert has_element?(child, "[data-role='goals-empty']")
      assert html =~ ~s(href="/m/goals")

      {:ok, _view, tasks_html} = live(login(conn, user), "/tasks")
      assert tasks_html =~ ~s(href="/m/goals")
    end

    test "Goals follows Inbox on desktop, and Voice and Tasks on phone", %{user: user} do
      scope = Scope.for_user(user)
      assert [:inbox, :goals | _] = keys(IconRail.desktop_more_rows(scope, false))
      assert [:voice, :tasks, :goals | _] = keys(IconRail.more_sheet_rows(scope, false))
    end

    test "lists the user's goals and opens one by ?goal=", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      goal = goal!(user, org_id, %{title: "Learn Spanish"})
      other = goal!(member!(org_id), org_id, %{title: "Somebody else's"})

      {:ok, view, _html} = live(login(conn, user), "/m/goals")
      child = find_live_child(view, "ext-page-goals")
      assert has_element?(child, "a[href='/m/goals?goal=#{goal.id}']", "Learn Spanish")
      refute render(child) =~ other.id
      refute has_element?(child, "[data-role='goal-view']")

      {:ok, view, _html} = live(login(conn, user), "/m/goals?goal=#{goal.id}")
      child = find_live_child(view, "ext-page-goals")
      assert has_element?(child, "[data-role='goal-view'][data-goal-id='#{goal.id}']")
      assert has_element?(child, "[data-role='goal-view'] h2", "Learn Spanish")
      assert has_element?(child, "[data-role='goal-meta']", "'s goal")
    end

    # Task 01a1ecb3 stage 1: below lg the detail pane is the scroller every
    # Goals screen ends in, so it pads its end clear of the glass rail.
    test "the detail pane with a goal open clears the bottom rail", %{
      conn: conn,
      user: user,
      org_id: org_id
    } do
      goal = goal!(user, org_id, %{title: "Learn Spanish"})

      {:ok, view, _html} = live(login(conn, user), "/m/goals?goal=#{goal.id}")
      child = find_live_child(view, "ext-page-goals")

      assert has_element?(child, "[data-role='goals-detail-pane'].clears-tab-bar")
      assert has_element?(child, "[data-role='goals-detail-pane'] [data-role='goal-view']")
    end

    test "a viewer sees the goal without its audience", %{conn: conn, user: user, org_id: org_id} do
      owner = member!(org_id)
      goal = goal!(owner, org_id, %{title: "Ship the redesign"})
      {:ok, _} = Goals.open_goal(owner, goal.id, {:user, user.id})

      {:ok, view, _html} = live(login(conn, user), "/m/goals?goal=#{goal.id}")
      child = find_live_child(view, "ext-page-goals")
      assert has_element?(child, "[data-role='goal-meta']", "Shared by")
    end

    test "another user's private goal, a random id and a malformed id are the same 404",
         %{conn: conn, user: user, org_id: org_id} do
      private = goal!(member!(org_id), org_id, %{title: "Private plans"})

      bodies =
        for id <- [private.id, Ecto.UUID.generate(), "not-a-uuid"] do
          {404, _headers, body} =
            assert_error_sent(404, fn ->
              get(login(conn, user), "/m/goals?goal=" <> URI.encode_www_form(id))
            end)

          refute body =~ "Private plans"
          body
        end

      assert [one] = Enum.uniq(bodies)
      assert is_binary(one)
    end
  end
end

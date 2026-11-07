defmodule PlatformWeb.SetupGoalsLiveTest do
  @moduledoc """
  `/setup/goals` (task 01a1b6de stage 1): the setup goal question.

  Mutants these name:

    * drop the `length(@goals) < @max` guard on "+ add another" → "the add
      control stops at 3";
    * push_navigate before saving in "save" → "Continue saves and redirects";
    * drop the root-admin check → "a non-admin is refused".
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat
  alias Platform.Roles
  alias Platform.VaultFixtures

  setup %{conn: conn} do
    :ok = Roles.unassign_role("agents_leader")
    admin = VaultFixtures.admin!()
    %{conn: Plug.Test.init_test_session(conn, %{"current_user_id" => admin.id}), admin: admin}
  end

  test "renders the question, one field, the add control, the helper and one Continue", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/setup/goals")

    assert has_element?(view, "#setup-goals-question", "What should your team get done first?")
    assert has_element?(view, "#setup-goal-0")
    refute has_element?(view, "#setup-goal-1")
    assert has_element?(view, "#setup-goals-add", "+ add another (up to 3)")

    assert has_element?(
             view,
             "#setup-goals-helper",
             "Burrow will keep everyone pointed at these and tell you what's in the way."
           )

    html = render(view)
    doc = LazyHTML.from_document(html)
    assert doc |> LazyHTML.query(".btn-primary") |> Enum.count() == 1
    assert has_element?(view, "#setup-goals-continue.btn-primary", "Continue")
    assert has_element?(view, "#setup-goals-skip", "Skip for now")
  end

  test "the add control stops at 3", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/goals")

    view |> element("#setup-goals-add") |> render_click()
    assert has_element?(view, "#setup-goal-1")
    view |> element("#setup-goals-add") |> render_click()
    assert has_element?(view, "#setup-goal-2")

    refute has_element?(view, "#setup-goals-add")
    assert render_click(view, "add", %{}) =~ "setup-goal-2"
    refute has_element?(view, "#setup-goal-3")
  end

  test "Continue saves the goals and redirects", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/goals")

    assert {:error, {:live_redirect, %{to: "/chat"}}} =
             view
             |> form("#setup-goals-form", %{
               "setup" => %{
                 "goals" => [
                   "Launch the new booking site by December",
                   "",
                   "Answer every customer email within a day"
                 ]
               }
             })
             |> render_submit()

    space = AgentsGoalHeartbeat.agents_space()

    assert space.goals == [
             "Launch the new booking site by December",
             "Answer every customer email within a day"
           ]

    assert space.goal == "Launch the new booking site by December"
  end

  test "a 4th goal posted anyway is refused with a plain line and nothing is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/goals")

    html = render_submit(view, "save", %{"setup" => %{"goals" => ["a", "b", "c", "d"]}})

    assert html =~ "You can set up to 3 goals."
    assert has_element?(view, "#setup-goals-error")
    assert AgentsGoalHeartbeat.agents_space() == nil
  end

  test "Continue with nothing typed is a skip: nothing is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/goals")

    assert {:error, {:live_redirect, %{to: "/chat"}}} =
             render_submit(view, "save", %{"setup" => %{"goals" => [""]}})

    assert Repo.aggregate(from(s in Space, where: s.goals != ^[]), :count) == 0
  end

  test "existing goals are shown for editing", %{conn: conn} do
    {:ok, _} = Platform.Agents.Lead.save_setup_goals(["One", "Two"])
    {:ok, view, _html} = live(conn, ~p"/setup/goals")

    assert has_element?(view, ~s(#setup-goal-0[value="One"]))
    assert has_element?(view, ~s(#setup-goal-1[value="Two"]))
  end

  test "a non-admin is refused", %{conn: conn} do
    user = VaultFixtures.non_admin!()
    conn = Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})

    assert {:error, {_kind, %{to: to}}} = live(conn, ~p"/setup/goals")
    assert to =~ "access-denied"
  end
end

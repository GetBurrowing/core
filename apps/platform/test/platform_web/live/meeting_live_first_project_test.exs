defmodule PlatformWeb.MeetingLiveFirstProjectTest do
  @moduledoc """
  A fresh install has no project (core task 01a1b7ed stage 3). Its owner's
  first "+ New meeting" -> Start meeting used to dead-end: the Space list was
  empty and `start_room` answered "Create a project before starting a
  meeting." A ROOT member with no project in sight now gets the install's
  first project, "General", and the meeting starts in it. A member of another
  org with no project is still refused: a root-org project is not theirs to
  make.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  setup do
    Repo.delete_all(Meeting)
    Repo.delete_all(Project)
    :ok
  end

  defp user_in!(org_id) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "first_project_#{n}@example.com",
        name: "First Project #{n}",
        oidc_sub: "oidc-first-project-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    user
  end

  defp start_room(conn, user) do
    {:ok, view, _html} =
      conn |> init_test_session(current_user_id: user.id) |> live(~p"/meetings")

    render_click(view, "open_new_room", %{})
    {view, render_submit(view, "start_room", %{"title" => "First call"})}
  end

  test "a root member with no project starts the meeting in a new General project",
       %{conn: conn} do
    user = user_in!(Platform.TenancyFixtures.acme_org_id())
    assert Tasks.list_projects_for_user(user) == []

    {_view, result} = start_room(conn, user)

    assert [%Project{name: "General", slug: "general"} = project] = Repo.all(Project)
    assert project.org_id == Platform.TenancyFixtures.acme_org_id()
    assert [%Meeting{name: "First call", project_id: project_id}] = Repo.all(Meeting)
    assert project_id == project.id
    refute match?(html when is_binary(html), result) and result =~ "Create a project"
  end

  test "a member of another org with no project is still refused, and nothing is created",
       %{conn: conn} do
    user = user_in!(Platform.TenancyFixtures.tenant_org_id("initech"))
    refute Platform.Tenancy.root_member?(user)

    {_view, html} = start_room(conn, user)

    assert html =~ "Create a project before starting a meeting."
    assert Repo.all(Project) == []
    assert Repo.all(Meeting) == []
  end

  test "ensure_first_project reuses an existing project instead of making another" do
    user = user_in!(Platform.TenancyFixtures.acme_org_id())
    {:ok, first} = Tasks.ensure_first_project(user)
    assert {:ok, %Project{id: id}} = Tasks.ensure_first_project(user)
    assert id == first.id
    assert Repo.aggregate(Project, :count) == 1
  end
end

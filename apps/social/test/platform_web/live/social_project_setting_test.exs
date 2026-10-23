defmodule PlatformWeb.SocialProjectSettingTest do
  @moduledoc """
  Task 01a16532 stage 3: the "Project for renders" row in Settings
  (design direction canvas 01a16763-cfb1). An approver chooses from the
  org's own projects and it saves at once; a non-approver sees plain text;
  forged and cross-org events write nothing; unset and zero-project states
  say so; a profile created from the empty state already has a project.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.Profile

  defp project!(org_id, name) do
    {:ok, project} =
      Platform.Tasks.create_project(%{name: name, org_id: org_id, slug: "p-#{unique()}"})

    project
  end

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    child = find_live_child(view, "ext-page-social")
    child |> element("[data-role='social-tab-button'][data-tab='settings']") |> render_click()
    child
  end

  defp world(project_names, profile_attrs \\ %{}) do
    org_id = org_id!()
    projects = Enum.map(project_names, &project!(org_id, &1))
    approver = member!(user!(), org_id)
    viewer = member!(user!(), org_id)

    {:ok, profile} =
      Social.create_profile(
        org_id,
        Map.merge(%{name: "Show #{unique()}", approver_user_ids: [approver.id]}, profile_attrs)
      )

    %{org_id: org_id, projects: projects, approver: approver, viewer: viewer, profile: profile}
  end

  defp option_names(child) do
    child
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='social-project-select'] option")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp project_id(profile), do: Repo.get!(Profile, profile.id).project_id

  test "an approver chooses from own-org projects only, sorted by name; it saves at once",
       %{conn: conn} do
    w = world(["Zulu", "Alpha"])
    foreign = project!(org_id!(), "Foreign")
    [zulu, alpha] = w.projects
    assert w.profile.project_id == alpha.id

    child = open(conn, w.approver)

    assert has_element?(child, "[data-role='social-project-label']", "Project for renders")
    assert has_element?(child, "[data-role='social-project-select']")
    assert option_names(child) == ["Alpha", "Zulu"]
    refute render(child) =~ foreign.name

    assert has_element?(
             child,
             "[data-role='social-project-helper']",
             "Clip renders and uploaded covers are stored as files in this project."
           )

    refute has_element?(child, "[data-role='social-project-unset']")
    refute has_element?(child, "[data-role='social-project-setting'] button")
    refute has_element?(child, "[data-role='social-project-saved']")

    child |> form("#social-project-setting-form", %{project_id: zulu.id}) |> render_change()

    assert project_id(w.profile) == zulu.id
    assert has_element?(child, "[data-role='social-project-saved']", "Saved")

    send(child.pid, :project_saved_clear)
    refute has_element?(child, "[data-role='social-project-saved']")
  end

  test "with exactly one project the select is still shown", %{conn: conn} do
    w = world(["Only"])
    child = open(conn, w.approver)
    assert option_names(child) == ["Only"]
  end

  test "a non-approver sees plain text, with no select", %{conn: conn} do
    w = world(["Alpha"])
    child = open(conn, w.viewer)

    assert has_element?(
             child,
             "[data-role='social-settings-readonly'] [data-role='social-project-readonly']",
             "Project for renders:"
           )

    assert has_element?(child, "[data-role='social-project-readonly']", "Alpha")
    refute has_element?(child, "[data-role='social-project-select']")
    refute has_element?(child, "[data-role='social-project-setting']")
  end

  test "a forged event from a non-approver writes nothing", %{conn: conn} do
    w = world(["Alpha", "Bravo"])
    [alpha, bravo] = w.projects
    child = open(conn, w.viewer)

    render_hook(child, "set_profile_project", %{"project_id" => bravo.id})

    assert project_id(w.profile) == alpha.id
    assert render(child) =~ "Only an approver of this profile can change it."
  end

  test "a cross-org or unknown project id from an approver is refused", %{conn: conn} do
    w = world(["Alpha"])
    [alpha] = w.projects
    foreign = project!(org_id!(), "Foreign")
    child = open(conn, w.approver)

    render_hook(child, "set_profile_project", %{"project_id" => foreign.id})
    assert project_id(w.profile) == alpha.id

    render_hook(child, "set_profile_project", %{"project_id" => Ecto.UUID.generate()})
    assert project_id(w.profile) == alpha.id

    render_hook(child, "set_profile_project", %{"project_id" => ""})
    assert project_id(w.profile) == alpha.id
    refute has_element?(child, "[data-role='social-project-saved']")
  end

  test "unset shows the warning and the prompt", %{conn: conn} do
    w = world(["Alpha"], %{project_id: nil})
    child = open(conn, w.approver)

    assert has_element?(child, "[data-role='social-project-unset-icon']")

    assert has_element?(
             child,
             "[data-role='social-project-unset']",
             "Clips can't render until a project is chosen."
           )

    assert has_element?(
             child,
             "[data-role='social-project-select'] option[value='']",
             "Choose a project"
           )

    refute has_element?(child, "[data-role='social-project-helper']")
  end

  test "an org with no projects shows Create a project first", %{conn: conn} do
    w = world([])
    assert w.profile.project_id == nil
    child = open(conn, w.approver)

    assert has_element?(child, "[data-role='social-project-none'] a", "Create a project first")
    refute has_element?(child, "[data-role='social-project-select']")
  end

  test "a profile created through the create_profile event has the default project",
       %{conn: conn} do
    org_id = org_id!()
    project!(org_id, "Zulu")
    alpha = project!(org_id, "Alpha")
    human = member!(user!(), org_id)
    conn = Plug.Test.init_test_session(conn, current_user_id: human.id)
    {:ok, view, _html} = live(conn, "/m/social")
    child = find_live_child(view, "ext-page-social")

    child
    |> form("#social-create-form", profile: %{name: "Fresh", home_url: ""})
    |> render_submit()

    assert [%Profile{project_id: id}] = Social.list_profiles(org_id)
    assert id == alpha.id
  end
end

defmodule PlatformWeb.SocialStudioDisabledShellReviewTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialStudioFixtures
  alias Platform.Social

  test "Calendar removes the Today tab and pane when Studio is switched off", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Visible after re-enable"})
    conn = Plug.Test.init_test_session(conn, current_user_id: w.approver.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{w.profile.id}")
    view = find_live_child(parent, "ext-page-social")
    assert has_element?(view, "[data-role='social-tab-button'][data-tab='today']")
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    assert {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    render_click(view, "week_this", %{})
    refute has_element?(view, "[data-role='social-tab-button'][data-tab='today']")
    refute has_element?(view, "[data-pane='today']")
    assert {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)
    render_click(view, "week_this", %{})
    assert has_element?(view, "[data-role='social-tab-button'][data-tab='today']")
    view |> element("[data-role='social-tab-button'][data-tab='today']") |> render_click()

    assert has_element?(
             view,
             "[data-role='studio-post'][data-post-id='#{post.id}']",
             "Visible after re-enable"
           )
  end

  test "All brands keeps Today available while another visible profile is enabled", %{conn: conn} do
    w = studio_world!()

    {:ok, second} =
      Social.create_profile(w.org_id, %{
        name: "Second",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id]
      })

    {:ok, second} = Social.Studio.set_enabled(w.org_id, second.id, w.approver.id, true)
    conn = Plug.Test.init_test_session(conn, current_user_id: w.approver.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{w.profile.id}")
    view = find_live_child(parent, "ext-page-social")
    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    render_click(view, "week_this", %{})
    assert has_element?(view, "[data-role='social-tab-button'][data-tab='today']")
    {:ok, _} = Social.Studio.set_enabled(w.org_id, second.id, w.approver.id, false)
    render_click(view, "week_this", %{})
    refute has_element?(view, "[data-role='social-tab-button'][data-tab='today']")
  end

  test "All brands loads a newly enabled profile without switching scope", %{conn: conn} do
    w = studio_world!()

    {:ok, second} =
      Social.create_profile(w.org_id, %{
        name: "Newly enabled",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id]
      })

    {:ok, second} = Social.Studio.set_enabled(w.org_id, second.id, w.approver.id, true)
    {:ok, account} = Social.create_account(w.org_id, second, %{platform: "youtube"})

    post =
      studio_post!(%{w | profile: second}, account, "needs_approval", %{
        body: "Newly enabled work"
      })

    draft = studio_post!(w, w.tiktok, "draft", %{body: "Original draft"})
    {:ok, _} = Social.Studio.set_enabled(w.org_id, second.id, w.approver.id, false)
    conn = Plug.Test.init_test_session(conn, current_user_id: w.approver.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{w.profile.id}")
    view = find_live_child(parent, "ext-page-social")
    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()

    view
    |> element("[data-role='studio-post-open'][data-post-id='#{draft.id}']")
    |> render_click()

    force!(draft, %{body: "Changed elsewhere", version: draft.version + 1})
    view |> form("#studio-edit-form", %{body: "Keep this draft"}) |> render_submit()
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    refute render(view) =~ "Newly enabled work"
    {:ok, _} = Social.Studio.set_enabled(w.org_id, second.id, w.approver.id, true)
    render_click(view, "week_this", %{})
    view |> element("[data-role='social-tab-button'][data-tab='today']") |> render_click()

    assert has_element?(
             view,
             "[data-role='studio-post'][data-post-id='#{post.id}']",
             "Newly enabled work"
           )

    assert has_element?(view, "#studio-edit-body", "Keep this draft")
  end
end

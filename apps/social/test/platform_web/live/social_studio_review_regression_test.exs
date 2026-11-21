defmodule PlatformWeb.SocialStudioDReviewTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures
  alias Platform.Social

  defp open(conn, user, profile) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{profile.id}")
    find_live_child(parent, "ext-page-social")
  end

  defp open_post(view, post) do
    view
    |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']")
    |> render_click()
  end

  test "successful submit refreshes the UI to approval instead of reporting failure", %{
    conn: conn
  } do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "draft")
    view = open(conn, w.approver, w.profile)
    open_post(view, post)
    assert has_element?(view, "[data-role='studio-submit']")
    view |> element("[data-role='studio-submit']") |> render_click()
    assert Social.get_post(w.org_id, post.id).status == "needs_approval"
    refute has_element?(view, "[role='alert']", "could not be submitted")
    assert has_element?(view, "[data-role='studio-approve']")
    refute has_element?(view, "[data-role='studio-submit']")
  end

  test "planning accepts the minute precision supplied by datetime-local", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "approved")
    view = open(conn, w.approver, w.profile)
    open_post(view, post)

    local =
      DateTime.utc_now()
      |> DateTime.add(86_400, :second)
      |> DateTime.shift_zone!(w.profile.timezone)
      |> Calendar.strftime("%Y-%m-%dT%H:%M")

    view |> form("#studio-plan-form", %{planned_at: local}) |> render_submit()
    assert Social.get_post(w.org_id, post.id).status == "planned"
    assert has_element?(view, "[data-role='studio-post-detail']", "Planned in Burrow")
  end

  for change <- [:disabled, :project_denied] do
    test "Calendar rechecks #{change} before retaining cached Studio content", %{conn: conn} do
      w = studio_world!()
      post = studio_post!(w, w.tiktok, "approved", %{body: "Restricted Studio work"})
      view = open(conn, w.approver, w.profile)
      view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()

      assert has_element?(
               view,
               "[data-role='studio-calendar-unscheduled'][data-post-id='#{post.id}']"
             )

      case unquote(change) do
        :disabled ->
          assert {:ok, _} =
                   Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)

        :project_denied ->
          assert {:ok, _} =
                   Platform.Access.Grants.deny(%{
                     principal: {:user, w.approver.id},
                     permission: "social.use",
                     resource: {:project, w.project.id}
                   })

          assert {:error, :no_social_access} =
                   Social.Studio.require_social_use(w.approver.id, w.profile)
      end

      render_click(view, "week_this", %{})

      refute has_element?(
               view,
               "[data-role='studio-calendar-unscheduled'][data-post-id='#{post.id}']"
             )

      refute render(view) =~ "Restricted Studio work"
    end
  end

  test "Calendar's All brands toggle also hides that brand's Studio posts", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "approved")
    view = open(conn, w.approver, w.profile)
    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    selector = "[data-role='studio-calendar-unscheduled'][data-post-id='#{post.id}']"
    assert has_element?(view, selector)

    view
    |> element("[data-role='social-calendar-brand-toggle'][data-brand-id='#{w.profile.id}']")
    |> render_click()

    assert has_element?(
             view,
             "[data-role='social-calendar-brand-toggle'][data-brand-id='#{w.profile.id}'][data-hidden='true']"
           )

    refute has_element?(view, selector)
  end

  test "opening Calendar rechecks Studio access after project permission changes", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "approved", %{body: "Revoked calendar content"})
    view = open(conn, w.approver, w.profile)

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, w.project.id}
      })

    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    refute render(view) =~ "Revoked calendar content"
  end

  test "even a rejected Calendar event removes content when Studio was disabled", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "approved", %{body: "No longer available"})
    view = open(conn, w.approver, w.profile)
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    render_click(view, "calendar_zone", %{"zone" => "invalid-zone"})
    refute render(view) =~ "No longer available"
  end

  test "Calendar navigation preserves an authorized user's unsaved text after a stale save", %{
    conn: conn
  } do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "draft", %{body: "Original"})
    view = open(conn, w.approver, w.profile)
    open_post(view, post)
    force!(post, %{body: "Changed elsewhere", version: post.version + 1})
    view |> form("#studio-edit-form", %{body: "My unsaved text"}) |> render_submit()
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    render_click(view, "week_next", %{})
    view |> element("[data-role='social-tab-button'][data-tab='today']") |> render_click()
    assert has_element?(view, "#studio-edit-body", "My unsaved text")
  end

  test "refreshing a planned post for a new owner clears the plan and preserves history", %{
    conn: conn
  } do
    w = studio_world!()
    new_owner = user!() |> member!(w.org_id)
    {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, w.approver.id)
    post = studio_post!(w, w.tiktok, "planned")
    {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, new_owner.id)
    view = open(conn, new_owner, w.profile)
    open_post(view, post)
    refute has_element?(view, "#studio-plan-form")
    view |> element("[data-role='studio-approve']") |> render_click()
    updated = Social.get_post(w.org_id, post.id)
    assert updated.status == "approved"
    assert updated.version == post.version
    assert is_nil(updated.scheduled_at)
    assert has_element?(view, "[data-role='studio-receipt']", "Superseded")
    assert has_element?(view, "[data-role='studio-receipt']", "Current")
  end

  test "new owner sees the same-version approval refresh action before planning", %{conn: conn} do
    w = studio_world!()
    new_owner = user!() |> member!(w.org_id)
    {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, w.approver.id)
    post = studio_post!(w, w.tiktok, "approved")
    {:ok, account} = Social.set_account_owner(w.org_id, w.tiktok, new_owner.id)
    profile = Social.get_profile(w.org_id, w.profile.id)
    assert :ok = Social.post_approver_check(w.org_id, profile, account, new_owner.id)

    assert {:error, :not_the_owner} =
             Social.post_approver_check(w.org_id, profile, account, w.approver.id)

    view = open(conn, new_owner, w.profile)
    open_post(view, post)
    assert has_element?(view, "[data-role='studio-post-detail']")
    assert has_element?(view, "[data-role='studio-approve']")
  end

  test "an archived account is explained alongside the escape route", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "approved")
    {:ok, _} = Social.archive_account(w.org_id, w.tiktok)
    view = open(conn, w.approver, w.profile)
    open_post(view, post)
    assert has_element?(view, "#studio-edit-account")
    assert has_element?(view, "[data-role='studio-post-detail']", "archived")
    refute has_element?(view, "[data-role='studio-approve']")
    refute has_element?(view, "#studio-plan-form")
    view |> form("#studio-edit-form", %{body: post.body, account_id: w.x.id}) |> render_submit()
    changed = Social.get_post(w.org_id, post.id)
    assert changed.account_id == w.x.id
    assert changed.status == "needs_approval"
  end

  test "post approval previews its bound render even after the clip gets a newer render", %{
    conn: conn
  } do
    w = studio_world!()
    clip = w |> pending_clip!() |> make_studio_clip!()
    {:ok, [original]} = Social.ClipVersions.recent(w.org_id, w.profile.id, clip.id)

    {:ok, %{posts: [post]}} =
      Social.Studio.accept_render(w.org_id, clip.id, w.approver.id, %{
        render_id: original.id,
        account_ids: [w.tiktok.id]
      })

    newer_file = stored_file!(w.project, "new render bytes", "newer.mp4", "video/mp4")

    assert {:ok, _} =
             Platform.Repo.transaction(fn ->
               Social.ClipVersions.append!(clip.id, newer_file, %{}, %{})
             end)

    assert Social.get_post(w.org_id, post.id).media_file_ids == [original.file_id]
    view = open(conn, w.approver, w.profile)
    open_post(view, post)

    assert has_element?(
             view,
             "[data-role='studio-clip'] video[src='/files/blob/#{newer_file.id}#t=0.1']"
           )

    assert has_element?(
             view,
             "[data-role='studio-post-detail'] video[src='/files/blob/#{original.file_id}']"
           )
  end
end

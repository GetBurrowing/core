defmodule PlatformWeb.SocialWorkflowClarityTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialStudioFixtures

  alias Platform.Social

  defp open(conn, user, query) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, parent, _} = live(conn, "/m/social" <> query)
    find_live_child(parent, "ext-page-social")
  end

  test "one work list drives Today and Queue while planned work stays on Calendar", %{conn: conn} do
    w = studio_world!()
    draft = studio_post!(w, w.tiktok, "draft", %{body: "Draft item"})
    pending = studio_post!(w, w.tiktok, "needs_approval", %{body: "Pending item"})
    approved = studio_post!(w, w.x, "approved", %{body: "Approved item"})
    planned = studio_post!(w, w.x, "planned", %{body: "Planned item"})
    planned = force!(planned, %{scheduled_at: DateTime.utc_now()})
    clip = w |> pending_clip!() |> make_studio_clip!()
    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    assert has_element?(view, "[data-role='social-studio-today'] h2", "Prepare and review (4)")

    for post <- [draft, pending, approved] do
      assert has_element?(view, "[data-role='studio-post'][data-post-id='#{post.id}']")
    end

    refute has_element?(view, "[data-role='studio-post'][data-post-id='#{planned.id}']")
    assert has_element?(view, "[data-role='studio-clip'][data-clip-id='#{clip.id}']")

    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()
    assert has_element?(view, "[data-role='queue-heading']", "Awaiting approval")

    assert has_element?(
             view,
             "[data-role='social-queue-pane']",
             "This is the publishing queue for posts intended for connected accounts."
           )

    assert has_element?(
             view,
             "[data-role='social-queue-pane']",
             "4 items to prepare or review on Today"
           )

    refute has_element?(view, "[data-role='social-empty']", "is caught up")
    refute has_element?(view, "[data-role='social-empty'] [class*='hero-check-circle']")

    view |> element("[data-role='queue-open-today']") |> render_click()

    assert has_element?(
             view,
             "[data-role='social-tab-button'][data-tab='today'][aria-selected='true']"
           )

    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()

    assert has_element?(
             view,
             "[data-role='studio-calendar']",
             "Studio plans (not published from Burrow)"
           )

    assert has_element?(
             view,
             "[data-role='studio-calendar-planned'][data-post-id='#{planned.id}']",
             "Plan only · does not publish"
           )

    assert has_element?(
             view,
             "[data-role='studio-calendar-unscheduled'][data-post-id='#{approved.id}']",
             "Approved, needs a time"
           )

    view
    |> element("[data-role='studio-calendar-planned'][data-post-id='#{planned.id}'] button")
    |> render_click()

    assert has_element?(view, "[data-role='studio-post-detail']", "Planned item")
    assert has_element?(view, "[data-role='studio-cancel-plan']")
  end

  test "Queue says one item when singular and omits the link at zero", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "draft")
    view = open(conn, w.approver, "?profile=#{w.profile.id}&tab=queue")

    assert has_element?(
             view,
             "[data-role='social-queue-pane']",
             "1 item to prepare or review on Today"
           )

    assert has_element?(view, "[data-role='queue-open-today']")
    assert {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()
    refute has_element?(view, "[data-role='queue-open-today']")
    refute render(view) =~ "1 item to prepare or review on Today"
    assert Social.get_post(w.org_id, post.id)
  end

  test "an empty Studio work list has truthful empty states and no Queue link", %{conn: conn} do
    w = studio_world!()
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='social-studio-today'] h2", "Prepare and review (0)")

    assert has_element?(
             view,
             "[data-role='social-studio-today']",
             "Nothing to prepare or review yet."
           )

    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()
    assert has_element?(view, "[data-role='social-empty']", "Nothing is awaiting approval.")
    assert has_element?(view, "[data-role='social-empty'] [class*='hero-check-circle']")

    refute has_element?(
             view,
             "[data-role='social-queue-pane']",
             "Approval submits to the connected account immediately"
           )

    refute has_element?(view, "[data-role='queue-open-today']")
  end

  test "Queue keeps the Today link for a clip when there are no accounts", %{conn: conn} do
    w = studio_world!()
    _clip = w |> pending_clip!() |> make_studio_clip!()
    assert {:ok, _} = Social.archive_account(w.org_id, w.tiktok)
    assert {:ok, _} = Social.archive_account(w.org_id, w.x)
    view = open(conn, w.approver, "?profile=#{w.profile.id}&tab=queue")

    assert has_element?(view, "[data-role='social-empty']", "Connect an account to start.")

    assert has_element?(
             view,
             "[data-role='social-empty']",
             "1 item to prepare or review on Today"
           )

    assert has_element?(view, "[data-role='queue-open-today']")
  end

  test "a denied profile is not counted after entering Queue", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "draft")
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='social-studio-today'] h2", "Prepare and review (1)")

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, w.project.id}
      })

    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()
    refute has_element?(view, "[data-role='queue-open-today']")
    refute render(view) =~ "1 item to prepare or review on Today"
  end

  test "Queue drops an already-loaded count when access is revoked", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "draft")
    view = open(conn, w.approver, "?profile=#{w.profile.id}&tab=queue")
    assert has_element?(view, "[data-role='queue-open-today']")

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, w.project.id}
      })

    # Trigger an unrelated rerender without selecting Queue again.
    render_click(view, "ideas_vote", %{"id" => Ecto.UUID.generate(), "action" => "vote"})
    refute has_element?(view, "[data-role='queue-open-today']")
    refute render(view) =~ "1 item to prepare or review on Today"
  end

  test "Queue drops a cached clip count after access is revoked", %{conn: conn} do
    w = studio_world!()
    _clip = w |> pending_clip!() |> make_studio_clip!()
    view = open(conn, w.approver, "?profile=#{w.profile.id}&tab=queue")

    assert has_element?(
             view,
             "[data-role='social-empty']",
             "1 item to prepare or review on Today"
           )

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, w.project.id}
      })

    render_click(view, "ideas_vote", %{"id" => Ecto.UUID.generate(), "action" => "vote"})
    refute has_element?(view, "[data-role='queue-open-today']")
    refute render(view) =~ "1 item to prepare or review on Today"
  end

  test "entering Queue loads work after profile access is restored", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "draft")

    {:ok, deny} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, w.project.id}
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}&tab=queue")
    refute has_element?(view, "[data-role='queue-open-today']")
    assert {:ok, _} = Platform.Access.Grants.revoke(deny)
    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()

    assert has_element?(
             view,
             "[data-role='social-empty']",
             "1 item to prepare or review on Today"
           )

    assert has_element?(view, "[data-role='queue-open-today']")
  end

  test "planning removes the post from both work counts and keeps it on Calendar", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "approved", %{body: "Plan this"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='social-studio-today'] h2", "Prepare and review (1)")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    future = DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.truncate(:second)
    local_time = future |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    view |> form("#studio-plan-form", %{planned_at: local_time}) |> render_submit()
    assert Social.get_post(w.org_id, post.id).status == "planned"
    assert has_element?(view, "[data-role='social-studio-today'] h2", "Prepare and review (0)")
    refute has_element?(view, "[data-role='studio-post'][data-post-id='#{post.id}']")
    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()
    refute has_element?(view, "[data-role='queue-open-today']")
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()

    if Date.beginning_of_week(Date.utc_today()) !=
         Date.beginning_of_week(DateTime.to_date(future)) do
      view |> element("[data-role='week-next']") |> render_click()
    end

    assert has_element?(
             view,
             "[data-role='studio-calendar-planned'][data-post-id='#{post.id}']",
             "Plan only · does not publish"
           )
  end

  test "All brands count includes only authorized, enabled profiles", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "draft", %{body: "First allowed"})
    second_project = Platform.SocialFixtures.project!(w.org_id)

    {:ok, second} =
      Social.create_profile(w.org_id, %{
        name: "Second profile",
        project_id: second_project.id,
        approver_user_ids: [w.approver.id]
      })

    {:ok, second} = Social.Studio.set_enabled(w.org_id, second.id, w.approver.id, true)
    {:ok, second_account} = Social.create_account(w.org_id, second, %{platform: "youtube"})

    studio_post!(%{w | profile: second, project: second_project}, second_account, "draft", %{
      body: "Second denied"
    })

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, second_project.id}
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    assert has_element?(view, "[data-role='social-studio-today'] h2", "Prepare and review (1)")
    assert render(view) =~ "First allowed"
    refute render(view) =~ "Second denied"
    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()

    assert has_element?(
             view,
             "[data-role='social-queue-pane']",
             "1 item to prepare or review on Today"
           )
  end
end

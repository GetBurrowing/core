defmodule PlatformWeb.SocialStudioTodayTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social

  defp open(conn, user, query) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, parent, _} = live(conn, "/m/social" <> query)
    find_live_child(parent, "ext-page-social")
  end

  test "Today appears for a Studio profile and disappears when switching to a disabled profile",
       %{conn: conn} do
    w = studio_world!()
    {:ok, disabled} = Social.create_profile(w.org_id, %{name: "Other profile"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    assert has_element?(view, "[data-role='social-tab-button'][data-tab='today']")

    assert has_element?(
             view,
             "[data-role='social-tab-button'][data-tab='today'][aria-selected='true']"
           )

    view |> form("#social-profile-switcher", %{profile_id: disabled.id}) |> render_change()
    refute has_element?(view, "[data-role='social-tab-button'][data-tab='today']")
    refute has_element?(view, "[data-pane='today']")

    view |> form("#social-profile-switcher", %{profile_id: w.profile.id}) |> render_change()
    assert has_element?(view, "[data-role='social-tab-button'][data-tab='today']")
  end

  test "All brands includes only enabled Studio profiles and never legacy posts", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Studio pending"})
    {:ok, disabled} = Social.create_profile(w.org_id, %{name: "Disabled"})
    {:ok, disabled_account} = Social.create_account(w.org_id, disabled, %{platform: "youtube"})
    {:ok, legacy} = Social.create_post(w.org_id, disabled_account, %{body: "Legacy only"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    assert has_element?(view, "[data-role='studio-post'][data-post-id='#{post.id}']")
    refute has_element?(view, "[data-role='studio-post'][data-post-id='#{legacy.id}']")

    {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    refute has_element?(view, "[data-pane='today']")
    refute has_element?(view, "[data-role='studio-post'][data-post-id='#{post.id}']")
  end

  test "Today shows real account goals and keeps empty results explicit", %{conn: conn} do
    w = studio_world!()
    {:ok, _} = Social.update_account_schedule(w.org_id, w.tiktok, %{weekly_goal: 5})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='studio-weekly-goal']", "0 / 5")
    assert has_element?(view, "[data-role='studio-results']", "No measured results")
    assert has_element?(view, "[data-role='studio-trends']", "No trend data")
  end

  test "displays Wikipedia reporting date and pageviews rather than unrelated metrics", %{
    conn: conn
  } do
    w = studio_world!()

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               reporting_date: ~D[2026-11-13],
               observed_at: ~U[2026-11-15 10:00:00Z],
               items: [
                 %{
                   id: "Example",
                   rank: 3,
                   title: "Example",
                   url: "https://en.wikipedia.org/wiki/Example",
                   pageviews: 123
                 }
               ]
             })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='studio-trends']", "Most viewed on Wikipedia")
    assert has_element?(view, "[data-role='studio-trends']", "2026-11-13")
    assert has_element?(view, "[data-role='studio-trends']", "123 pageviews")
    refute has_element?(view, "[data-role='studio-trends']", "points")
  end

  test "old reporting data stays stale even when observed just now", %{conn: conn} do
    w = studio_world!()

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               reporting_date: Date.add(Date.utc_today(), -7),
               observed_at: DateTime.utc_now(),
               items: [
                 %{
                   id: "Example",
                   rank: 1,
                   title: "Example",
                   url: "https://en.wikipedia.org/wiki/Example",
                   pageviews: 123
                 }
               ]
             })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='studio-trends']", "stale")
  end

  test "an empty topic filter explains that no titles matched", %{conn: conn} do
    w = studio_world!()

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               reporting_date: Date.add(Date.utc_today(), -1),
               observed_at: DateTime.utc_now(),
               items: [
                 %{
                   id: "Example",
                   rank: 1,
                   title: "A bicycle story",
                   url: "https://en.wikipedia.org/wiki/Example",
                   pageviews: 123
                 }
               ]
             })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='trends-ai-filter']") |> render_click()
    assert has_element?(view, "[data-role='studio-trends']", "No matching article titles")
  end

  test "cached data says when automatic source updates are switched off", %{conn: conn} do
    old = Application.get_env(:social, :trends)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:social, :trends),
        else: Application.put_env(:social, :trends, old)
    end)

    Application.put_env(:social, :trends, enabled: false)
    w = studio_world!()

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               reporting_date: Date.add(Date.utc_today(), -1),
               observed_at: DateTime.utc_now(),
               items: [
                 %{
                   id: "Example",
                   rank: 1,
                   title: "Example",
                   url: "https://en.wikipedia.org/wiki/Example",
                   pageviews: 123
                 }
               ]
             })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='studio-trends']", "Trend updates are switched off")
    assert has_element?(view, "[data-role='studio-trends']", "Example")
    Application.put_env(:social, :trends, enabled: true, source: nil)
    view |> element("[data-role='trends-ai-filter']") |> render_click()
    assert has_element?(view, "[data-role='studio-trends']", "Trend source is not configured")
  end

  test "shows that the next Wikipedia dataset has not arrived while keeping the last one", %{
    conn: conn
  } do
    w = studio_world!()

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               reporting_date: Date.add(Date.utc_today(), -1),
               observed_at: DateTime.utc_now(),
               items: [
                 %{
                   id: "Example",
                   rank: 1,
                   title: "Example",
                   url: "https://en.wikipedia.org/wiki/Example",
                   pageviews: 123
                 }
               ]
             })

    Platform.Repo.insert!(%Social.Trends.SourceState{
      source: "wikimedia_pageviews",
      status: "not_yet_available",
      last_attempt_at: DateTime.utc_now()
    })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='studio-trends']", "Example")

    assert has_element?(
             view,
             "[data-role='studio-trends']",
             "Next daily dataset is unavailable"
           )
  end

  test "a source failure before the first dataset does not claim old data is shown", %{conn: conn} do
    w = studio_world!()

    Platform.Repo.insert!(%Social.Trends.SourceState{
      source: "wikimedia_pageviews",
      status: "unavailable",
      last_attempt_at: DateTime.utc_now()
    })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    assert has_element?(
             view,
             "[data-role='studio-trends']",
             "The source is currently unavailable"
           )

    refute has_element?(view, "[data-role='studio-trends']", "last successful data is shown")
  end

  test "shows observed Wikipedia ranks and creates one idea on replay", %{conn: conn} do
    w = studio_world!()

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 20,
               complete: true,
               observed_at: ~U[2026-11-15 10:00:00Z],
               reporting_date: ~D[2026-11-13],
               items: [
                 %{
                   id: "7",
                   rank: 2,
                   title: "Synthetic story",
                   url: "https://example.com/story",
                   pageviews: 20
                 }
               ]
             })

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 20,
               complete: true,
               observed_at: ~U[2026-11-15 11:00:00Z],
               reporting_date: ~D[2026-11-14],
               items: [
                 %{
                   id: "7",
                   rank: 1,
                   title: "Synthetic story",
                   url: "https://example.com/story",
                   pageviews: 21
                 }
               ]
             })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='studio-trends']", "Wikipedia")
    assert has_element?(view, "[data-role='studio-trends']", "Synthetic story")
    assert has_element?(view, "[data-role='studio-trends']", "Up 1")
    assert has_element?(view, "[data-role='studio-trends']", "Stored data")
    assert has_element?(view, "[data-role='trends-refresh']", "Refresh list")
    view |> element("[data-role='trend-to-idea'][data-story-id='7']") |> render_click()
    assert has_element?(view, "[data-role='trend-to-idea'][data-story-id='7']", "Already saved")
    view |> element("[data-role='trend-to-idea'][data-story-id='7']") |> render_click()

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='trend-to-idea'][data-story-id='7']", "Already saved")

    assert Platform.Repo.aggregate(
             from(i in Social.Idea, where: i.profile_id == ^w.profile.id),
             :count
           ) == 1
  end

  test "filters the watchlist without changing source rank and requires a brand to save", %{
    conn: conn
  } do
    w = studio_world!()

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 20,
               complete: true,
               observed_at: ~U[2026-11-15 10:00:00Z],
               reporting_date: ~D[2026-11-13],
               items: [
                 %{
                   id: "a",
                   rank: 1,
                   title: "AI research",
                   url: "https://example.com/a",
                   pageviews: 4
                 },
                 %{
                   id: "b",
                   rank: 2,
                   title: "A bicycle story",
                   url: "https://example.com/b",
                   pageviews: 2
                 }
               ]
             })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='trends-ai-filter']") |> render_click()
    assert has_element?(view, "[data-role='studio-trends']", "AI research")
    refute has_element?(view, "[data-role='studio-trends']", "A bicycle story")
    assert has_element?(view, "[data-role='studio-trends']", "Rank 1")
    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    refute has_element?(view, "[data-role='trend-to-idea']")

    render_click(view, "studio_trend_to_idea", %{
      "id" => "a",
      "snapshot_id" => Social.Trends.latest("wikimedia_pageviews").current.id
    })

    assert Platform.Repo.aggregate(
             from(i in Social.Idea, where: i.profile_id == ^w.profile.id),
             :count
           ) == 0
  end

  test "labels stories missing from the next comparable observed list", %{conn: conn} do
    w = studio_world!()

    old = %{
      source: "wikimedia_pageviews",
      limit: 20,
      complete: true,
      observed_at: ~U[2026-11-15 10:00:00Z],
      reporting_date: ~D[2026-11-13],
      items: [
        %{
          id: "a",
          rank: 1,
          title: "Previous story",
          url: "https://example.com/a",
          pageviews: 4
        }
      ]
    }

    new = %{
      old
      | observed_at: ~U[2026-11-15 11:00:00Z],
        reporting_date: ~D[2026-11-14],
        items: [
          %{
            id: "b",
            rank: 1,
            title: "New story",
            url: "https://example.com/b",
            pageviews: 2
          }
        ]
    }

    assert {:ok, _} = Social.Trends.record_snapshot(old)
    assert {:ok, _} = Social.Trends.record_snapshot(new)
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='studio-trends']", "New in observed list")
    assert has_element?(view, "[data-role='studio-trends']", "Previous story")
    assert has_element?(view, "[data-role='studio-trends']", "Not in latest observed list")
  end

  test "disabling Studio refuses a direct trend event from an already-open page", %{conn: conn} do
    w = studio_world!()

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 20,
               complete: true,
               observed_at: ~U[2026-11-15 10:00:00Z],
               reporting_date: ~D[2026-11-13],
               items: [
                 %{
                   id: "x",
                   rank: 1,
                   title: "Synthetic",
                   url: "https://example.com",
                   pageviews: 1
                 }
               ]
             })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='trend-to-idea']")
    assert {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)

    render_click(view, "studio_trend_to_idea", %{
      "id" => "x",
      "snapshot_id" => Social.Trends.latest("wikimedia_pageviews").current.id
    })

    assert Platform.Repo.aggregate(
             from(i in Social.Idea, where: i.profile_id == ^w.profile.id),
             :count
           ) == 0

    refute has_element?(view, "[data-role='studio-trends']", "Synthetic")
  end

  test "a refresh between viewing and clicking refuses to save a different observation", %{
    conn: conn
  } do
    w = studio_world!()

    first = %{
      source: "wikimedia_pageviews",
      limit: 20,
      complete: true,
      observed_at: ~U[2026-11-15 10:00:00Z],
      reporting_date: ~D[2026-11-13],
      items: [
        %{
          id: "x",
          rank: 1,
          title: "Shown title",
          url: "https://example.com",
          pageviews: 1
        }
      ]
    }

    assert {:ok, _} = Social.Trends.record_snapshot(first)
    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    changed = %{
      first
      | observed_at: ~U[2026-11-15 11:00:00Z],
        reporting_date: ~D[2026-11-14],
        items: [
          %{
            id: "x",
            rank: 1,
            title: "Changed title",
            url: "https://example.com",
            pageviews: 2
          }
        ]
    }

    assert {:ok, _} = Social.Trends.record_snapshot(changed)
    view |> element("[data-role='trend-to-idea']") |> render_click()
    assert has_element?(view, "[data-role='studio-trends']", "Could not save this idea")

    assert Platform.Repo.aggregate(
             from(i in Social.Idea, where: i.profile_id == ^w.profile.id),
             :count
           ) == 0
  end

  test "Today only shows agent ideas for enabled visible profiles", %{conn: conn} do
    w = studio_world!()
    other = studio_world!()

    {:ok, _} =
      Social.Ideas.create(
        w.scope,
        w.profile.id,
        %{title: "Local agent idea", source_kind: "agent"},
        {:agent, w.agent.id}
      )

    {:ok, _} =
      Social.Ideas.create(
        other.scope,
        other.profile.id,
        %{title: "Foreign agent idea", source_kind: "agent"},
        {:agent, other.agent.id}
      )

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert render(view) =~ "Local agent idea"
    refute render(view) =~ "Foreign agent idea"
  end

  test "Today shows measured published results for the selected profile", %{conn: conn} do
    w = studio_world!()
    {:ok, post} = Social.create_post(w.org_id, w.tiktok, %{body: "Measured post"})

    force!(post, %{
      status: "published",
      approved_by_user_id: w.approver.id,
      approved_at: DateTime.utc_now(),
      published_at: DateTime.utc_now(),
      metrics_synced_at: DateTime.utc_now(),
      metrics: %{"views" => 99}
    })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='studio-results']", "Measured post")
    assert has_element?(view, "[data-role='studio-results']", "99")
  end

  test "a forged post id from another organization never opens its content", %{conn: conn} do
    w = studio_world!()
    foreign = studio_world!()
    post = studio_post!(foreign, foreign.tiktok, "needs_approval", %{body: "Foreign secret"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    render_click(view, "studio_open_post", %{"id" => post.id})
    refute render(view) =~ "Foreign secret"
    refute has_element?(view, "[data-role='studio-post-detail']")
  end

  test "the header counts authorized Studio work alongside legacy work and updates after approval",
       %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Needs a decision"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='social-needs-approval']", "1 need approval")
    assert has_element?(view, "[data-role='social-tab-button'][data-tab='queue']", "Queue (0)")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    view |> element("[data-role='studio-approve']") |> render_click()
    assert has_element?(view, "[data-role='social-needs-approval']", "0 need approval")
  end

  test "a project-denied viewer does not see Studio approval counts", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "needs_approval")

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, w.project.id}
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='social-needs-approval']", "0 need approval")
  end

  test "header combines legacy and Studio counts without adding Studio to Queue", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "needs_approval", %{body: "Studio item"})

    {:ok, _legacy} =
      Social.create_post(w.org_id, w.x, %{body: "Legacy item", status: "needs_approval"})

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='social-needs-approval']", "2 need approval")
    assert has_element?(view, "[data-role='social-tab-button'][data-tab='queue']", "Queue (1)")
    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()
    assert has_element?(view, "[data-role='social-queue']", "Legacy item")
    refute has_element?(view, "[data-role='social-queue']", "Studio item")
  end

  test "disabling Studio removes its header count without changing legacy queue", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "needs_approval")
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='social-needs-approval']", "1 need approval")
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    render_click(view, "week_this", %{})
    assert has_element?(view, "[data-role='social-needs-approval']", "0 need approval")
    assert has_element?(view, "[data-role='social-tab-button'][data-tab='queue']", "Queue (0)")
  end

  test "All brands counts only enabled, accessible Studio profiles", %{conn: conn} do
    w = studio_world!()
    studio_post!(w, w.tiktok, "needs_approval")

    {:ok, second} =
      Social.create_profile(w.org_id, %{
        name: "Second",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id]
      })

    {:ok, second} = Social.Studio.set_enabled(w.org_id, second.id, w.approver.id, true)
    {:ok, account} = Social.create_account(w.org_id, second, %{platform: "youtube"})
    studio_post!(%{w | profile: second}, account, "needs_approval")
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    assert has_element?(view, "[data-role='social-needs-approval']", "2 need approval")
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
    {:ok, _} = Social.Studio.set_enabled(w.org_id, second.id, w.approver.id, false)
    render_click(view, "week_this", %{})
    assert has_element?(view, "[data-role='social-needs-approval']", "1 need approval")
  end

  test "an approver reviews and approves a post without planning or publishing", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Ready to review"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    assert has_element?(
             view,
             "[data-role='studio-post-open'][data-post-id='#{post.id}'].text-left"
           )

    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    id = post.id
    assert_push_event(view, "studio:focus_detail", %{id: ^id})

    assert has_element?(
             view,
             "[data-role='studio-post-detail'][phx-hook='StudioPostFocus'][tabindex='-1']"
           )

    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    assert_push_event(view, "studio:focus_detail", %{id: ^id})
    assert has_element?(view, "[data-role='studio-post-detail']", "Ready to review")
    assert has_element?(view, "[data-role='studio-post-detail']", "@show")
    view |> element("[data-role='studio-approve']") |> render_click()

    saved = Social.get_post(w.org_id, post.id)
    assert saved.status == "approved"
    assert saved.scheduled_at == nil
    assert saved.external_id == nil
    assert has_element?(view, "[data-role='studio-post-detail']", "Approved")
  end

  test "Social body reserves space for the phone navigation rail", %{conn: conn} do
    w = studio_world!()
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    assert has_element?(view, "[data-role='social-tab-body'][class*='--bottom-nav-height']")
  end

  test "approval details use readable statuses and people instead of raw IDs", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Review text"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    assert has_element?(view, "[data-role='studio-post-detail']", "Needs approval")
    refute render(view) =~ "needs_approval"
    view |> element("[data-role='studio-approve']") |> render_click()
    assert has_element?(view, "[data-role='studio-receipt']", "Current")
    assert has_element?(view, "[data-role='studio-receipt']", w.approver.name)
    receipt = render(element(view, "[data-role='studio-receipt']"))
    refute receipt =~ w.approver.id
    refute receipt =~ w.tiktok.id
  end

  test "an approver can revoke an approval and see its historical receipt", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval")
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    view |> element("[data-role='studio-approve']") |> render_click()
    assert has_element?(view, "[data-role='studio-receipt']", "Current")
    view |> element("[data-role='studio-revoke']") |> render_click()
    assert Social.get_post(w.org_id, post.id).status == "needs_approval"
    assert has_element?(view, "[data-role='studio-receipt']", "Revoked")
    assert has_element?(view, "[data-role='studio-history']", "Approval revoked")
  end

  test "an out-of-date approval is refused and leaves the newer content unchanged", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Original"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    force!(post, %{body: "Changed elsewhere", version: post.version + 1})

    render_click(view, "studio_approve_post", %{})
    saved = Social.get_post(w.org_id, post.id)
    assert saved.status == "needs_approval"
    assert saved.body == "Changed elsewhere"
    assert has_element?(view, "[role='alert']")
  end

  test "a non-approver cannot approve by sending the event directly", %{conn: conn} do
    w = studio_world!()
    user = Platform.SocialFixtures.member!(Platform.SocialFixtures.user!(), w.org_id)
    post = studio_post!(w, w.tiktok, "needs_approval")
    view = open(conn, user, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    refute has_element?(view, "[data-role='studio-approve']")
    render_click(view, "studio_approve_post", %{})
    assert Social.get_post(w.org_id, post.id).status == "needs_approval"
  end

  test "disabling Studio while the socket is open removes the old detail on the next event", %{
    conn: conn
  } do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Private Studio draft"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()

    {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    render_click(view, "studio_approve_post", %{})

    refute has_element?(view, "[data-pane='today']")
    refute render(view) =~ "Private Studio draft"
    assert Social.get_post(w.org_id, post.id).status == "needs_approval"
  end

  test "a save after Studio is disabled removes the old detail", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "draft", %{body: "Hidden draft"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    view |> form("#studio-edit-form", %{body: "Attempted edit"}) |> render_submit()
    refute render(view) =~ "Hidden draft"
    assert Social.get_post(w.org_id, post.id).body == "Hidden draft"
  end

  test "fresh and returned drafts use the correct submission label and transition", %{conn: conn} do
    w = studio_world!()
    fresh = studio_post!(w, w.tiktok, "draft", %{body: "Fresh draft"})
    returned = studio_post!(w, w.tiktok, "draft", %{body: "Returned draft"})
    force!(returned, %{rejected_at: DateTime.utc_now(), rejection_reason: "Revise"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    view
    |> element("[data-role='studio-post-open'][data-post-id='#{fresh.id}']")
    |> render_click()

    assert has_element?(view, "[data-role='studio-submit']", "Submit for approval")
    view |> element("[data-role='studio-submit']") |> render_click()
    assert Social.get_post(w.org_id, fresh.id).status == "needs_approval"

    view
    |> element("[data-role='studio-post-open'][data-post-id='#{returned.id}']")
    |> render_click()

    assert has_element?(view, "[data-role='studio-submit']", "Resubmit for approval")
    view |> element("[data-role='studio-submit']") |> render_click()
    assert Social.get_post(w.org_id, returned.id).status == "needs_approval"
  end

  test "an approved post is planned in Burrow and its plan can be cancelled", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "approved", %{body: "Approved clip"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    future = DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.truncate(:second)

    local_time = future |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    view |> form("#studio-plan-form", %{planned_at: local_time}) |> render_submit()
    planned = Social.get_post(w.org_id, post.id)
    assert planned.status == "planned"
    assert has_element?(view, "[data-role='studio-post-detail']", "Planned in Burrow")
    assert planned.external_id == nil

    view |> element("[data-role='studio-cancel-plan']") |> render_click()
    assert Social.get_post(w.org_id, post.id).status == "approved"
  end

  test "editing an approved post warns and saves a new unapproved version", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "approved", %{body: "Old text"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()

    assert has_element?(view, "[data-role='studio-edit-warning']", "revokes")
    view |> form("#studio-edit-form", %{body: "New text"}) |> render_submit()
    saved = Social.get_post(w.org_id, post.id)
    assert saved.body == "New text"
    assert saved.status == "needs_approval"
    assert saved.version == post.version + 1
  end

  test "changing the destination creates a new version and revokes approval", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "approved", %{body: "Destination test"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()

    view
    |> form("#studio-edit-form", %{body: "Destination test", account_id: w.x.id})
    |> render_submit()

    saved = Social.get_post(w.org_id, post.id)
    assert saved.account_id == w.x.id
    assert saved.version == post.version + 1
    assert saved.status == "needs_approval"
  end

  test "a project-level social.use denial prevents Studio post disclosure", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Restricted content"})

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "social.use",
        resource: {:project, w.project.id}
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    refute has_element?(view, "[data-role='studio-post'][data-post-id='#{post.id}']")
    refute render(view) =~ "Restricted content"
  end

  test "saving unchanged text reports no changes without altering the version", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "draft", %{body: "Unchanged text"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()

    view
    |> form("#studio-edit-form", %{body: post.body, account_id: w.tiktok.id})
    |> render_submit()

    assert has_element?(view, "[data-role='studio-post-detail']", "No changes to save")
    refute has_element?(view, "[role='alert']", "Refresh")
    assert Social.get_post(w.org_id, post.id).version == post.version
  end

  test "an unchanged-looking save is still refused when the post changed elsewhere", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "draft", %{body: "Original"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    force!(post, %{body: "Changed elsewhere", version: post.version + 1})

    view
    |> form("#studio-edit-form", %{body: "Original", account_id: w.tiktok.id})
    |> render_submit()

    assert has_element?(view, "[role='alert']", "not saved")
    refute has_element?(view, "[role='status']", "No changes to save")
    assert Social.get_post(w.org_id, post.id).body == "Changed elsewhere"
  end

  test "a stale edit is refused without losing the entered text", %{conn: conn} do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Original"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()
    force!(post, %{body: "Other edit", version: post.version + 1})

    view |> form("#studio-edit-form", %{body: "My unsaved text"}) |> render_submit()
    assert has_element?(view, "#studio-edit-body", "My unsaved text")
    assert has_element?(view, "[role='alert']")
    assert Social.get_post(w.org_id, post.id).body == "Other edit"
  end

  test "an approver requests changes with a reason and the draft can be resubmitted", %{
    conn: conn
  } do
    w = studio_world!()
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Needs revision"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='studio-post-open'][data-post-id='#{post.id}']") |> render_click()

    view
    |> form("#studio-request-changes-form", %{reason: "Tighten the opening"})
    |> render_submit()

    changed = Social.get_post(w.org_id, post.id)
    assert changed.status == "draft"
    assert changed.rejection_reason == "Tighten the opening"
    assert has_element?(view, "[data-role='studio-submit']", "Resubmit for approval")
  end

  test "Calendar distinguishes planned work from approved work needing a time", %{conn: conn} do
    w = studio_world!()
    planned = studio_post!(w, w.tiktok, "planned", %{body: "Planned clip"})
    approved = studio_post!(w, w.x, "approved", %{body: "Waiting for time"})
    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()

    assert has_element?(
             view,
             "[data-role='studio-calendar-planned'][data-post-id='#{planned.id}']",
             "Planned in Burrow"
           )

    assert has_element?(
             view,
             "[data-role='studio-calendar-unscheduled'][data-post-id='#{approved.id}']",
             "Approved, needs a time"
           )

    refute has_element?(view, "[data-role='social-empty']", "Nothing scheduled")
    assert has_element?(view, "[data-role='social-empty']", "No other scheduled posts")

    view
    |> element("[data-role='studio-calendar-unscheduled'][data-post-id='#{approved.id}'] button")
    |> render_click()

    assert has_element?(view, "[data-role='studio-post-detail']", approved.body)
  end

  test "pairing previews a selected video and imports only after confirmation", %{conn: conn} do
    w = studio_world!()
    bytes = "pairing video"
    file = stored_file!(w.project, bytes, "clip.mp4", "video/mp4")
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    export =
      Jason.encode!(%{
        "clips" => [
          %{"external_ref" => "ep4/a", "sha256" => hash, "size_bytes" => byte_size(bytes)}
        ]
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    view |> form("#studio-pair-preview", %{export_json: export}) |> render_submit()
    assert has_element?(view, "[data-role='studio-pair-entry']", "clip.mp4")
    assert Social.list_clips(w.org_id, profile_id: w.profile.id, flow: "studio") == []

    view |> form("#studio-pair-import", %{choices: %{"ep4/a" => file.id}}) |> render_submit()
    assert has_element?(view, "[data-role='studio-pair-result']", "Imported")
    assert [clip] = Social.list_clips(w.org_id, profile_id: w.profile.id, flow: "studio")
    assert has_element?(view, "[data-role='studio-clip'][data-clip-id='#{clip.id}']")
  end

  test "pairing closes Studio when it is disabled after preview", %{conn: conn} do
    w = studio_world!()
    bytes = "disabled pairing video"
    file = stored_file!(w.project, bytes, "disabled-clip.mp4", "video/mp4")
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    export =
      Jason.encode!(%{
        "clips" => [
          %{"external_ref" => "ep4/a", "sha256" => hash, "size_bytes" => byte_size(bytes)}
        ]
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> form("#studio-pair-preview", %{export_json: export}) |> render_submit()
    {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    view |> form("#studio-pair-import", %{choices: %{"ep4/a" => file.id}}) |> render_submit()
    refute has_element?(view, "[data-pane='today']")
    refute render(view) =~ "disabled-clip.mp4"
  end

  test "pairing clears a preview when file access is withdrawn", %{conn: conn} do
    w = studio_world!()
    bytes = "private pairing video"
    file = stored_file!(w.project, bytes, "private-clip.mp4", "video/mp4")
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    export =
      Jason.encode!(%{
        "clips" => [
          %{"external_ref" => "ep4/a", "sha256" => hash, "size_bytes" => byte_size(bytes)}
        ]
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> form("#studio-pair-preview", %{export_json: export}) |> render_submit()
    assert render(view) =~ "private-clip.mp4"

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "files.read",
        resource: {:project, w.project.id}
      })

    view |> form("#studio-pair-import", %{choices: %{"ep4/a" => file.id}}) |> render_submit()
    refute render(view) =~ "private-clip.mp4"
    assert Social.list_clips(w.org_id, profile_id: w.profile.id, flow: "studio") == []
  end

  test "a rejected pairing keeps the selection visible for correction", %{conn: conn} do
    w = studio_world!()
    bytes = "will change"
    file = stored_file!(w.project, bytes, "clip.mp4", "video/mp4")
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    export =
      Jason.encode!(%{
        "clips" => [
          %{"external_ref" => "ep4/a", "sha256" => hash, "size_bytes" => byte_size(bytes)}
        ]
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> form("#studio-pair-preview", %{export_json: export}) |> render_submit()

    Platform.Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
      set: [deleted_at: DateTime.utc_now()]
    )

    view |> form("#studio-pair-import", %{choices: %{"ep4/a" => file.id}}) |> render_submit()
    assert has_element?(view, "[role='alert']")

    assert has_element?(
             view,
             "select[name='choices[ep4/a]'] option[value='#{file.id}'][selected]"
           )

    assert Social.list_clips(w.org_id, profile_id: w.profile.id, flow: "studio") == []
  end

  test "a repeated export reference is explained and cannot be imported", %{conn: conn} do
    w = studio_world!()
    entry = %{"external_ref" => "ep4/a", "sha256" => String.duplicate("a", 64), "size_bytes" => 1}
    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    view
    |> form("#studio-pair-preview", %{export_json: Jason.encode!(%{"clips" => [entry, entry]})})
    |> render_submit()

    assert has_element?(view, "[role='alert']", "repeated reference")
    refute has_element?(view, "#studio-pair-import")
  end

  test "a person can choose an export JSON file for the pairing preview", %{conn: conn} do
    w = studio_world!()
    bytes = "file preview"
    stored_file!(w.project, bytes, "clip.mp4", "video/mp4")
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    export =
      Jason.encode!(%{
        "clips" => [
          %{"external_ref" => "ep4/file", "sha256" => hash, "size_bytes" => byte_size(bytes)}
        ]
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    upload =
      file_input(view, "#studio-pair-file-form", :studio_export, [
        %{name: "clips.json", content: export, type: "application/json"}
      ])

    assert render_upload(upload, "clips.json") =~ "100%"
    view |> form("#studio-pair-file-form") |> render_submit()
    assert has_element?(view, "[data-role='studio-pair-entry']", "ep4/file")
  end

  test "a partial import names unresolved entries and preserves successful results", %{conn: conn} do
    w = studio_world!()
    bytes = "one matching video"
    file = stored_file!(w.project, bytes, "one.mp4", "video/mp4")
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    missing_hash = :crypto.hash(:sha256, "not uploaded") |> Base.encode16(case: :lower)

    export =
      Jason.encode!(%{
        "clips" => [
          %{"external_ref" => "ep4/one", "sha256" => hash, "size_bytes" => byte_size(bytes)},
          %{"external_ref" => "ep4/missing", "sha256" => missing_hash, "size_bytes" => 12}
        ]
      })

    view = open(conn, w.approver, "?profile=#{w.profile.id}")
    view |> form("#studio-pair-preview", %{export_json: export}) |> render_submit()
    view |> form("#studio-pair-import", %{choices: %{"ep4/one" => file.id}}) |> render_submit()
    assert has_element?(view, "[data-role='studio-pair-result']", "ep4/one · Imported")
    assert has_element?(view, "[data-role='studio-pair-issue']", "ep4/missing")
  end

  test "accepting a Studio clip prepares a post without approving or publishing", %{conn: conn} do
    w = studio_world!()
    clip = w |> pending_clip!() |> make_studio_clip!()
    {:ok, [render | _]} = Social.ClipVersions.recent(w.org_id, w.profile.id, clip.id)
    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    assert has_element?(view, "[data-role='studio-clip'][data-clip-id='#{clip.id}']")

    view
    |> form("#studio-clip-#{clip.id}", %{render_id: render.id, account_id: w.tiktok.id})
    |> render_submit()

    {:ok, [post]} = Social.Studio.list_posts(w.org_id, w.profile.id)
    assert post.status == "needs_approval"
    assert post.clip_render_id == render.id
    assert post.external_id == nil
    id = post.id
    assert_push_event(view, "studio:focus_detail", %{id: ^id})
    assert has_element?(view, "#studio-edit-body", "Agent caption")
    assert has_element?(view, "#studio-edit-body", "youtube.com/@clipshow")

    assert has_element?(
             view,
             "[data-role='studio-clip'][data-clip-id='#{clip.id}']",
             "Post prepared"
           )

    assert has_element?(view, "#studio-clip-#{clip.id} button", "Prepare or open post")

    view
    |> form("#studio-clip-#{clip.id}", %{render_id: render.id, account_id: w.tiktok.id})
    |> render_submit()

    assert {:ok, [same_post]} = Social.Studio.list_posts(w.org_id, w.profile.id)
    assert same_post.id == post.id
  end

  test "a titleless imported clip shows its reference without changing its stored title", %{
    conn: conn
  } do
    w = studio_world!()
    clip = w |> pending_clip!() |> make_studio_clip!()

    Platform.Repo.update_all(from(c in Social.Clip, where: c.id == ^clip.id),
      set: [title: nil, external_ref: "episode/example"]
    )

    view = open(conn, w.approver, "?profile=#{w.profile.id}")

    assert has_element?(
             view,
             "[data-role='studio-clip'][data-clip-id='#{clip.id}']",
             "episode/example"
           )

    assert is_nil(Social.get_clip(w.org_id, clip.id).title)
  end
end

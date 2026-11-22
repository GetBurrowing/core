defmodule PlatformWeb.SocialAccountTickerTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialStudioFixtures
  alias Platform.{Repo, Social}
  alias Platform.Social.{AccountTicker, FollowerSyncState}

  setup do
    w = studio_world!()

    profile =
      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Social.Profile, w.profile.id),
          provider_profile_ref: "ticker-profile"
        )
      )

    account =
      Repo.update!(
        Ecto.Changeset.change(w.tiktok,
          provider: "zernio",
          provider_account_ref: "ticker-account",
          follower_target: 100
        )
      )

    now = DateTime.utc_now()

    points =
      for {date, value} <- [{~D[2026-11-13], 93}, {~D[2026-11-20], 104}],
          do: %{
            date: date,
            followers: value,
            profile_id: "ticker-profile",
            account_id: "ticker-account",
            platform: "tiktok"
          }

    {:ok, 2} = AccountTicker.record(account, %{data: points}, now)
    %{w: %{w | profile: profile, tiktok: account}}
  end

  defp open(conn, w, query \\ "") do
    conn = Plug.Test.init_test_session(conn, current_user_id: w.approver.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{w.profile.id}#{query}")
    find_live_child(parent, "ext-page-social")
  end

  test "Wikipedia viewport CSS retains a 120px minimum and flex basis" do
    css = File.read!(Path.expand("../../../assets/css/clip_review.css", __DIR__))
    assert [[_, rule]] = Regex.scan(~r/\.social-wiki-viewport\s*\{([^}]*)\}/, css)
    assert Regex.match?(~r/\bmin-width\s*:\s*120px\s*;/, rule)
    assert Regex.match?(~r/\bflex\s*:\s*1\s+1\s+120px\s*;/, rule)
  end

  test "Wikipedia strip uses unfiltered display positions and opens All stories on Today", %{
    conn: conn,
    w: w
  } do
    original = Application.get_env(:social, :trends)
    Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")

    on_exit(fn ->
      if original,
        do: Application.put_env(:social, :trends, original),
        else: Application.delete_env(:social, :trends)
    end)

    items =
      for rank <- 2..12 do
        %{
          id: "article-#{rank}",
          rank: rank,
          title: if(rank == 3, do: "AI research", else: "Story #{rank}"),
          url: "https://example.test/#{rank}",
          pageviews: 100
        }
      end

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 20,
               complete: true,
               observed_at: ~U[2026-11-20 12:00:00Z],
               reporting_date: ~D[2026-11-19],
               items: items
             })

    view = open(conn, w)
    assert has_element?(view, "[data-role='ticker-wikipedia']", "Trending on Wikipedia")

    assert has_element?(
             view,
             "[data-role='ticker-wikipedia'].flex-wrap [data-wiki-viewport].social-wiki-viewport"
           )

    assert [label_classes] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("[data-role='ticker-wiki-label']")
             |> LazyHTML.attribute("class")

    assert "border-e" in String.split(label_classes)

    assert has_element?(
             view,
             "[data-role='ticker-wiki-label-mobile'][aria-hidden='true']",
             "W · Wikipedia"
           )

    assert has_element?(
             view,
             "[data-role='ticker-wiki-label-desktop'][aria-hidden='true']",
             "W · Trending on Wikipedia"
           )

    assert has_element?(view, "[data-role='ticker-wiki-label'] .sr-only", "Trending on Wikipedia")

    # Class contract only; the built-page check verifies actual responsive visibility.
    html = view |> render() |> LazyHTML.from_fragment()

    assert [mobile_classes] =
             html
             |> LazyHTML.query("[data-role='ticker-wiki-label-mobile']")
             |> LazyHTML.attribute("class")

    assert [desktop_classes] =
             html
             |> LazyHTML.query("[data-role='ticker-wiki-label-desktop']")
             |> LazyHTML.attribute("class")

    assert "sm:hidden" in String.split(mobile_classes)
    assert "hidden" in String.split(desktop_classes)
    assert "sm:inline" in String.split(desktop_classes)

    assert has_element?(
             view,
             "[data-wiki-original] [data-role='ticker-wiki-entry']",
             "1 · Story 2"
           )

    assert has_element?(
             view,
             "[data-wiki-original] [data-role='ticker-wiki-entry']",
             "10 · Story 11"
           )

    refute has_element?(view, "[data-wiki-original] [data-role='ticker-wiki-entry']", "Story 12")
    refute has_element?(view, "[data-wiki-copy] button:not([tabindex='-1'])")

    view |> element("[data-role='trends-ai-filter']") |> render_click()

    view
    |> element("[data-wiki-original] [data-role='ticker-wiki-entry']", "Story 2")
    |> render_click()

    assert has_element?(view, "#social-profile-switcher option[value='all'][selected]")
    assert has_element?(view, "[data-role='social-tab-body'][data-tab='today']")
    assert has_element?(view, "[data-role='studio-trends']", "Story 2")

    assert has_element?(
             view,
             "[data-role='studio-trends-heading'][tabindex='-1']",
             "What's moving"
           )

    assert has_element?(
             view,
             "[data-role='studio-trends'] button[aria-pressed='true']",
             "All stories"
           )

    assert_push_event(view, "social:focus_trends", %{})

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 20,
               complete: true,
               observed_at: ~U[2026-11-21 12:00:00Z],
               reporting_date: ~D[2026-11-20],
               items: [
                 %{
                   id: "new",
                   rank: 5,
                   title: "Latest story",
                   url: "https://example.test/new",
                   pageviews: 10
                 }
               ]
             })

    view |> element("[data-role='trends-refresh']") |> render_click()
    assert has_element?(view, "[data-wiki-original]", "1 · Latest story")
    refute has_element?(view, "[data-wiki-original]", "Story 2")
  end

  test "Wikipedia row hides without a snapshot or when Trends is switched off", %{
    conn: conn,
    w: w
  } do
    original = Application.get_env(:social, :trends)

    on_exit(fn ->
      if original,
        do: Application.put_env(:social, :trends, original),
        else: Application.delete_env(:social, :trends)
    end)

    Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
    view = open(conn, w)
    refute has_element?(view, "[data-role='ticker-wikipedia']")

    stale_date = Date.add(Date.utc_today(), -10)

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               observed_at: ~U[2026-11-20 12:00:00Z],
               reporting_date: stale_date,
               items: [
                 %{
                   id: "one",
                   rank: 1,
                   title: "One story",
                   url: "https://example.test/one",
                   pageviews: 1
                 }
               ]
             })

    view = open(conn, w)
    assert has_element?(view, "[data-role='ticker-wikipedia']", "One story")

    assert has_element?(
             view,
             "[data-role='ticker-wikipedia']",
             Calendar.strftime(stale_date, "%d %b")
           )

    assert has_element?(
             view,
             "[data-role='ticker-wiki-label'] .sr-only",
             Calendar.strftime(stale_date, "%d %b")
           )

    assert has_element?(
             view,
             "[data-role='ticker-wiki-label-desktop']",
             Calendar.strftime(stale_date, "%d %b")
           )

    refute has_element?(
             view,
             "[data-role='ticker-wiki-label-mobile']",
             Calendar.strftime(stale_date, "%d %b")
           )

    Application.put_env(:social, :trends, enabled: false, source: "wikimedia_pageviews")
    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()
    refute has_element?(view, "[data-role='ticker-wikipedia']")
  end

  test "revoked Social access removes Wikipedia and refuses a stale activation", %{
    conn: conn,
    w: w
  } do
    original = Application.get_env(:social, :trends)
    Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")

    on_exit(fn ->
      if original,
        do: Application.put_env(:social, :trends, original),
        else: Application.delete_env(:social, :trends)
    end)

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               observed_at: ~U[2026-11-20 12:00:00Z],
               reporting_date: ~D[2026-11-19],
               items: [
                 %{
                   id: "one",
                   rank: 1,
                   title: "One story",
                   url: "https://example.test/one",
                   pageviews: 1
                 }
               ]
             })

    view = open(conn, w, "&tab=queue")
    assert has_element?(view, "[data-role='ticker-wikipedia']", "One story")

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, w.approver.id},
               permission: "social.use",
               resource: {:project, w.project.id}
             })

    render_click(view, "ticker_wikipedia", %{})
    refute has_element?(view, "[data-role='ticker-wikipedia']")
    assert has_element?(view, "[data-role='social-tab-body'][data-tab='queue']")
  end

  test "the row follows visible enabled profiles even when a disabled brand is selected", %{
    conn: conn,
    w: w
  } do
    original = Application.get_env(:social, :trends)
    Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")

    on_exit(fn ->
      if original,
        do: Application.put_env(:social, :trends, original),
        else: Application.delete_env(:social, :trends)
    end)

    assert {:ok, _} =
             Social.Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               observed_at: ~U[2026-11-20 12:00:00Z],
               reporting_date: ~D[2026-11-19],
               items: [
                 %{
                   id: "one",
                   rank: 1,
                   title: "One story",
                   url: "https://example.test/one",
                   pageviews: 1
                 }
               ]
             })

    {:ok, disabled} = Social.create_profile(w.org_id, %{name: "Disabled brand"})

    {:ok, _} =
      Social.create_account(w.org_id, disabled, %{platform: "youtube", handle: "@disabled"})

    view = open(conn, w)
    view |> form("#social-profile-switcher", %{profile_id: disabled.id}) |> render_change()
    assert has_element?(view, "[data-role='ticker-wikipedia']", "One story")

    assert {:ok, _} = Social.Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    view |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()
    refute has_element?(view, "[data-role='ticker-wikipedia']")
  end

  test "strip dates follower changes, scopes views copy and hides duplicate keyboard stops", %{
    conn: conn,
    w: w
  } do
    view = open(conn, w)
    assert has_element?(view, "[data-role=social-account-ticker]")

    assert has_element?(
             view,
             "[data-ticker-original] [data-metric=followers][data-account-id='#{w.tiktok.id}']",
             "104"
           )

    assert has_element?(
             view,
             "[data-ticker-original] [data-metric=followers] time[datetime='2026-11-20']"
           )

    assert has_element?(
             view,
             "[data-ticker-original] [data-metric=followers]",
             "+11 vs 7 days ago"
           )

    assert has_element?(view, "[data-ticker-original] [data-metric=followers]", "104 of 100")

    assert has_element?(
             view,
             "[data-ticker-original] [data-metric=views]",
             "Burrow-published posts only"
           )

    refute has_element?(view, "[data-metric=followers] [data-role=ticker-views-scope]")
    assert has_element?(view, "[data-ticker-toggle]", "Pause")

    assert has_element?(
             view,
             "[data-role=social-account-ticker] > [data-role=ticker-strip-row] > .social-ticker-controls > [data-ticker-toggle]"
           )

    refute has_element?(view, "[data-role=social-account-ticker]", "Account performance")
    assert has_element?(view, "[data-ticker-original] time[datetime='2026-11-20']", "20 Nov")
    refute has_element?(view, "[data-ticker-original] time[datetime='2026-11-20']", "2026")
    assert has_element?(view, "[data-ticker-copy][aria-hidden=true]")
    refute has_element?(view, "[data-ticker-copy] a:not([tabindex='-1'])")
    refute has_element?(view, "[data-role=social-account-ticker][aria-live]")
  end

  test "unknown counts and no-posts are explicit; LinkedIn never gets a follower entry", %{
    conn: conn,
    w: w
  } do
    {:ok, li} =
      Social.create_account(w.org_id, w.profile, %{platform: "linkedin", handle: "@linkedin"})

    {:ok, _} = Social.update_account_schedule(w.org_id, w.x, %{follower_target: 100})
    view = open(conn, w)

    assert has_element?(
             view,
             "[data-ticker-original] [data-metric=followers][data-account-id='#{w.x.id}']",
             "Target 100"
           )

    refute has_element?(
             view,
             "[data-ticker-original] [data-metric=followers][data-account-id='#{w.x.id}']",
             "not available of 100"
           )

    assert has_element?(
             view,
             "[data-ticker-original] [data-metric=followers][data-account-id='#{w.x.id}']",
             "not available"
           )

    assert has_element?(
             view,
             "[data-ticker-original] [data-metric=views]",
             "No posts published in the last 7 days"
           )

    refute has_element?(view, "[data-metric=followers][data-account-id='#{li.id}']")
  end

  test "failed source refresh keeps its dated value and warning", %{conn: conn, w: w} do
    Repo.insert!(%FollowerSyncState{
      account_id: w.tiktok.id,
      provider_account_ref: "ticker-account",
      last_error: "transport"
    })

    view = open(conn, w)
    assert has_element?(view, "[data-ticker-original] [data-metric=followers]", "104")

    assert has_element?(
             view,
             "[data-ticker-original] [data-metric=followers]",
             "Last refresh failed"
           )

    assert has_element?(
             view,
             "[data-ticker-original] [data-metric=followers] time[datetime='2026-11-20']"
           )
  end

  test "profile switching and all-brands entries never combine follower audiences", %{
    conn: conn,
    w: w
  } do
    {:ok, other} = Social.create_profile(w.org_id, %{name: "Other ticker brand"})
    {:ok, a} = Social.create_account(w.org_id, other, %{platform: "youtube", handle: "@other"})
    view = open(conn, w)

    view
    |> element("[data-ticker-original] [data-metric=followers][data-account-id='#{w.x.id}']")
    |> render_click()

    view |> form("#social-profile-switcher", %{profile_id: other.id}) |> render_change()
    assert has_element?(view, "[data-ticker-original] [data-account-id='#{a.id}']")
    refute has_element?(view, "[data-ticker-original] [data-account-id='#{w.tiktok.id}']")
    refute has_element?(view, "[data-role=results-account-scope]")
    assert has_element?(view, "[data-role=results-account][data-account-id='#{a.id}']")
    view |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()
    assert has_element?(view, "[data-ticker-original] [data-account-id='#{a.id}']", other.name)

    assert has_element?(
             view,
             "[data-ticker-original] [data-account-id='#{w.tiktok.id}']",
             w.profile.name
           )
  end

  test "missing view analytics differs from no posts, and a failed refresh keeps measured zero",
       %{conn: conn, w: w} do
    {:ok, post} = Social.create_post(w.org_id, w.tiktok, %{body: "Measured cohort"})

    post =
      Repo.update!(
        Ecto.Changeset.change(post,
          status: "published",
          published_at: DateTime.utc_now(),
          approved_at: DateTime.utc_now(),
          approved_by_user_id: w.approver.id
        )
      )

    view = open(conn, w)
    selector = "[data-ticker-original] [data-metric=views][data-account-id='#{w.tiktok.id}']"
    assert has_element?(view, selector, "Views not available")
    refute has_element?(view, selector, "No posts published in the last 7 days")
    now = DateTime.utc_now()
    Repo.update!(Ecto.Changeset.change(post, metrics: %{"views" => 0}, metrics_synced_at: now))

    Repo.insert!(%Social.Analytics.SyncState{
      org_id: w.org_id,
      retry_at: DateTime.add(now, 60),
      post_refresh_error: "transport"
    })

    view |> element("[data-role=social-tab-button][data-tab=ideas]") |> render_click()
    assert has_element?(view, selector, "0")
    assert has_element?(view, selector, "Last refresh failed")
    assert has_element?(view, "#{selector} time[datetime='#{DateTime.to_iso8601(now)}']")
    refute has_element?(view, selector, "Views not available")
  end

  test "cached ticker data disappears when org visibility is revoked", %{conn: conn, w: w} do
    view = open(conn, w)

    Repo.get_by!(Platform.Tenancy.OrgMembership, org_id: w.org_id, user_id: w.approver.id)
    |> Repo.delete!()

    render_hook(view, "ticker_results", %{"account_id" => w.tiktok.id})
    refute has_element?(view, "[data-role=social-account-ticker]")
  end

  test "a failed first follower read never claims a stored value exists", %{conn: conn, w: w} do
    Repo.update!(Ecto.Changeset.change(w.x, provider_account_ref: "unknown-current"))

    Repo.insert!(%FollowerSyncState{
      account_id: w.x.id,
      provider_account_ref: "unknown-current",
      last_error: "transport"
    })

    view = open(conn, w)
    selector = "[data-ticker-original] [data-metric=followers][data-account-id='#{w.x.id}']"
    assert has_element?(view, selector, "not available")
    assert has_element?(view, selector, "Last refresh failed")
    refute has_element?(view, selector, "stored data")
  end

  test "ticker navigation filters Results without resetting a same-profile unsaved editor", %{
    conn: conn,
    w: w
  } do
    post = studio_post!(w, w.tiktok, "needs_approval", %{body: "Original"})
    view = open(conn, w)
    view |> element("[data-role=studio-post-open][data-post-id='#{post.id}']") |> render_click()
    Repo.update!(Ecto.Changeset.change(post, body: "Concurrent edit", version: post.version + 1))
    view |> form("#studio-edit-form", %{body: "Unsaved ticker text"}) |> render_submit()

    view
    |> element("[data-ticker-original] [data-metric=followers][data-account-id='#{w.tiktok.id}']")
    |> render_click()

    assert has_element?(view, "[data-role=social-tab-body][data-tab=results]")
    assert has_element?(view, "[data-role=results-account-scope]", w.tiktok.handle)
    view |> element("[data-role=social-tab-button][data-tab=today]") |> render_click()
    assert has_element?(view, "#studio-edit-body", "Unsaved ticker text")
    assert Social.get_post(w.org_id, post.id).body == "Concurrent edit"
  end

  test "ticker reuses platform marks with accessible names and a written unknown fallback", %{
    w: w
  } do
    [row | _] = AccountTicker.rows(w.approver, [w.profile.id])

    for {platform, label} <- [
          {"x", "X"},
          {"linkedin", "LinkedIn"},
          {"instagram", "Instagram"},
          {"youtube", "YouTube"},
          {"tiktok", "TikTok"}
        ] do
      row = %{row | account: %{row.account | platform: platform}}

      html =
        render_component(&PlatformWeb.SocialAccountTicker.strip/1,
          rows: [row],
          scope: {:profile, w.profile}
        )

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(
               LazyHTML.query(
                 doc,
                 "[data-ticker-original] [data-role='ticker-platform'][title='#{label}'] svg[aria-hidden='true']"
               )
             ) > 0

      assert LazyHTML.query(doc, "[data-ticker-original] [data-role='ticker-platform'] .sr-only")
             |> LazyHTML.text() =~ label
    end

    row = %{row | account: %{row.account | platform: "future-platform"}}

    html =
      render_component(&PlatformWeb.SocialAccountTicker.strip/1,
        rows: [row],
        scope: {:profile, w.profile}
      )

    assert html =~ "future-platform"
    refute html =~ "hero-globe"
  end

  defp youtube_publication!(w, attrs \\ %{}) do
    {:ok, a} =
      Social.create_account(w.org_id, w.profile, %{
        platform: "youtube",
        handle: "@latest-video",
        provider: "zernio",
        provider_account_ref: "video-account",
        status: "connected"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    video =
      struct!(
        Social.Analytics.Publication,
        Map.merge(
          %{
            account_id: a.id,
            profile_id: w.profile.id,
            provider_account_ref: a.provider_account_ref,
            provider_profile_ref: w.profile.provider_profile_ref,
            platform: "youtube",
            native_id: "abcdefghijk",
            vendor_url: "javascript:alert(1)",
            published_at: DateTime.add(now, -40 * 86400),
            vendor_synced_at: now,
            fetched_at: now,
            last_listed_at: now,
            listed_from: ~D[2026-10-01],
            listed_to: ~D[2026-10-30],
            is_owner: true,
            sync_status: "synced",
            metrics: %{"views" => 0}
          },
          attrs
        )
      )
      |> Repo.insert!()

    {a, video}
  end

  test "compact YouTube entry opens stationary data details with native link and separate provenance",
       %{conn: conn, w: w} do
    {a, video} = youtube_publication!(w)

    Req.Test.stub(Social.Publisher.Zernio, fn _ ->
      flunk("render and details must not request vendor")
    end)

    view = open(conn, w)
    selector = "[data-ticker-original] [data-role='ticker-latest-video']"

    assert has_element?(
             view,
             "#{selector} a[href='https://www.youtube.com/watch?v=abcdefghijk'][target='_blank'][rel='noopener noreferrer']",
             "Most recent YouTube video found"
           )

    assert has_element?(view, selector, "0 lifetime views")
    assert has_element?(view, selector, "search incomplete")
    refute has_element?(view, "#{selector} a[data-metric]")
    refute has_element?(view, selector, "Vendor last-sync time")

    assert has_element?(
             view,
             "#{selector} button[data-role='ticker-data-details'][aria-expanded='false']",
             "Data details"
           )

    refute has_element?(view, "[data-ticker-copy] a:not([tabindex='-1'])")
    refute has_element?(view, "[data-ticker-copy] button:not([tabindex='-1'])")
    view |> element("#{selector} button[data-role='ticker-data-details']") |> render_click()
    panel = "[data-role='ticker-video-details']"
    assert has_element?(view, panel, "Most recent YouTube video found · @latest-video")
    refute has_element?(view, "[data-ticker-viewport] #{panel}")

    assert has_element?(
             view,
             "#{panel} a[target='_blank'][rel='noopener noreferrer']",
             "Open on YouTube"
           )

    assert has_element?(
             view,
             "#{panel} time[datetime='#{DateTime.to_iso8601(video.published_at)}']",
             "UTC"
           )

    assert has_element?(view, panel, "Vendor last-sync time")
    assert has_element?(view, panel, "Last response received by Burrow")
    assert has_element?(view, panel, "Time the shown figures were received: not available")
    account_id = a.id
    assert_push_event(view, "social:ticker_details", %{open: true, account_id: ^account_id})
    view |> element("#{panel} button[data-role='ticker-details-close']") |> render_click()
    refute has_element?(view, panel)
    assert_push_event(view, "social:ticker_details", %{open: false, account_id: ^account_id})

    Repo.update!(
      Ecto.Changeset.change(video,
        metrics: %{"views" => nil},
        source_stale: true,
        ambiguous_count: 3,
        sync_status: "pending"
      )
    )

    view |> element("#{selector} button[data-role='ticker-data-details']") |> render_click()
    assert has_element?(view, selector, "views not available")
    assert has_element?(view, panel, "These figures may be out of date.")
    assert has_element?(view, panel, "at least three consecutive responses")
    assert has_element?(view, panel, "The vendor reports this video's figures as pending.")
    assert has_element?(view, panel, "That response conflicted and was set aside.")
    assert has_element?(view, panel, "Vendor last-sync time (for the figures shown)")
    refute has_element?(view, selector, "0 lifetime views")

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Social.Analytics.Publication, video.id),
        vendor_synced_at: nil,
        sync_status: "unavailable",
        ambiguous_count: 0
      )
    )

    render_click(view, "ticker_video_details", %{"account_id" => a.id})
    assert has_element?(view, panel, "No vendor time is recorded")
    refute has_element?(view, "#{panel} [data-role='ticker-vendor-time'] time")
    assert has_element?(view, panel, "The vendor reports this video's figures as unavailable.")
    refute has_element?(view, panel, "The vendor reports this video's figures as pending.")

    assert has_element?(
             view,
             "[data-metric='views']",
             "Lifetime views · Burrow posts published in last 7 days"
           )
  end

  test "details activation rechecks access and closes a previously open panel on revocation", %{
    conn: conn,
    w: w
  } do
    {a, _} = youtube_publication!(w)
    view = open(conn, w)
    render_click(view, "ticker_video_details", %{"account_id" => a.id})
    assert has_element?(view, "[data-role='ticker-video-details']")

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, w.approver.id},
               permission: "social.use",
               resource: {:project, w.project.id}
             })

    render_click(view, "ticker_video_details", %{"account_id" => a.id})
    refute has_element?(view, "[data-role='ticker-video-details']")
    refute has_element?(view, "[data-role='ticker-data-details']")
    assert has_element?(view, "[data-metric='followers']")
  end

  test "approved detail copy keeps discovery gaps separate from figures and unspecified statuses",
       %{w: w} do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))

    checked = [
      %{"from" => "2026-11-01", "to" => "2026-11-08"},
      %{"from" => "2026-11-15", "to" => "2026-11-22"}
    ]

    discovery = %{
      checked_ranges: checked,
      incomplete_ranges: [%{"from" => "2026-11-09", "to" => "2026-11-14"}],
      last_error: "refresh_failed",
      attempted_at: ~U[2026-11-22 08:00:00Z],
      from_date: ~D[2026-11-09],
      to_date: ~D[2026-11-14]
    }

    refresh = %{
      checked_ranges: [],
      incomplete_ranges: [%{"from" => "2026-10-13", "to" => "2026-10-13"}],
      last_error: nil,
      attempted_at: nil,
      from_date: ~D[2026-10-13],
      to_date: ~D[2026-10-13]
    }

    projection =
      Map.merge(row.latest_video, %{
        checked_ranges: checked,
        discovery: discovery,
        refresh: refresh,
        search_incomplete: true,
        newer_possible: true,
        figures_stale: false,
        response_set_aside: false
      })

    row =
      row
      |> Map.put(:latest_video, %{
        projection
        | video: %{projection.video | sync_status: "unspecified"}
      })
      |> Map.put(:ticker_details_open, true)

    html =
      render_component(&PlatformWeb.SocialAccountTicker.strip/1,
        rows: [row],
        scope: {:profile, w.profile}
      )

    doc = LazyHTML.from_fragment(html)

    strip =
      doc
      |> LazyHTML.query("[data-ticker-original] [data-role='ticker-latest-video']")
      |> LazyHTML.text()

    panel = doc |> LazyHTML.query("[data-role='ticker-video-details']") |> LazyHTML.text()
    assert strip =~ "search incomplete"
    refute strip =~ "figures may be out of date"
    assert panel =~ "1 Nov 2026 to 8 Nov 2026"
    assert panel =~ "15 Nov 2026 to 22 Nov 2026"
    refute panel =~ "1 Nov 2026 to 22 Nov 2026"
    assert panel =~ "9 Nov 2026 to 14 Nov 2026"
    assert panel =~ "A newer video may exist"
    assert panel =~ "Looking for videos"
    refute panel =~ "vendor reports this video's figures as unavailable"
    refute panel =~ "These figures may be out of date"
    assert panel =~ "No refresh problem is recorded."
    refute panel =~ "Up to date"

    uncertain =
      row
      |> Map.put(
        :latest_video,
        Map.merge(row.latest_video, %{
          search_incomplete: false,
          selection_uncertain: true,
          newer_possible: false,
          discovery: %{discovery | last_error: nil, incomplete_ranges: []}
        })
      )

    html =
      render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [uncertain], scope: :all)

    doc = LazyHTML.from_fragment(html)

    text =
      doc
      |> LazyHTML.query("[data-ticker-original] [data-role='ticker-latest-video']")
      |> LazyHTML.text()

    assert text =~ "Most recent YouTube video found"
    refute text =~ "search incomplete"

    assert doc |> LazyHTML.query("[data-role='ticker-video-details']") |> LazyHTML.text() =~
             "A newer stored observation was absent from a completed list scan; that does not establish deletion or privacy."
  end

  test "compact strip follows the approved ten-state copy without conflating refresh pagination",
       %{w: w} do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))

    discovery = %{
      checked_ranges: [%{"from" => "2026-11-01", "to" => "2026-11-22"}],
      incomplete_ranges: [],
      last_error: nil
    }

    base =
      Map.merge(row.latest_video, %{
        discovery: discovery,
        refresh: %{incomplete_ranges: [%{"from" => "2026-10-13", "to" => "2026-10-13"}]},
        search_incomplete: false,
        newer_possible: false,
        figures_stale: false,
        response_set_aside: false
      })

    for {views, incomplete, stale, label, metric, qualifier} <- [
          {66, false, false, "Latest YouTube video", "66 lifetime views", nil},
          {0, false, false, "Latest YouTube video", "0 lifetime views", nil},
          {1, false, false, "Latest YouTube video", "1 lifetime view", nil},
          {nil, false, false, "Latest YouTube video", "views not available", nil},
          {66, false, true, "Latest YouTube video", "66 lifetime views",
           "figures may be out of date"},
          {66, true, false, "Most recent YouTube video found", "66 lifetime views",
           "search incomplete"},
          {66, true, true, "Most recent YouTube video found", "66 lifetime views",
           "search incomplete"}
        ] do
      projection = %{
        base
        | video: %{base.video | metrics: %{"views" => views}, is_owner: nil, is_ad: nil},
          search_incomplete: incomplete,
          figures_stale: stale
      }

      html =
        render_component(&PlatformWeb.SocialAccountTicker.strip/1,
          rows: [%{row | latest_video: projection}],
          scope: :all
        )

      doc = LazyHTML.from_fragment(html)

      text =
        doc
        |> LazyHTML.query("[data-ticker-original] [data-role='ticker-latest-video']")
        |> LazyHTML.text()

      assert text =~ label
      assert text =~ metric
      if qualifier, do: assert(text =~ qualifier)
      if incomplete, do: refute(text =~ "figures may be out of date")
      unless incomplete, do: refute(text =~ "search incomplete")
      assert text =~ w.profile.name
    end

    for {incomplete, error, text} <- [
          {false, nil, "No YouTube video found in the dates checked, 1 Nov to 22 Nov"},
          {true, nil, "No YouTube video found yet · search incomplete"},
          {true, "refresh_failed", "Couldn't check YouTube for videos"}
        ] do
      projection = %{
        base
        | video: nil,
          fetched_at: nil,
          search_incomplete: incomplete,
          discovery: %{discovery | last_error: error}
      }

      empty_row = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)

      html =
        render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [empty_row], scope: :all)

      doc = LazyHTML.from_fragment(html)

      assert doc
             |> LazyHTML.query("[data-ticker-original] [data-role='ticker-latest-video']")
             |> LazyHTML.text() =~ text

      assert Enum.empty?(LazyHTML.query(doc, "[data-role='ticker-latest-video'] a"))
    end
  end

  test "successful incomplete refresh omitting the cached video is not a failed request", %{w: w} do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))
    day = DateTime.to_date(row.latest_video.video.published_at)
    range = %{"from" => Date.to_iso8601(day), "to" => Date.to_iso8601(day)}

    refresh = %{
      checked_ranges: [],
      incomplete_ranges: [range],
      last_error: "incomplete_observation",
      attempted_at: ~U[2026-11-22 08:00:00Z],
      from_date: day,
      to_date: day
    }

    discovery = %{
      checked_ranges: [
        %{"from" => Date.to_iso8601(day), "to" => Date.to_iso8601(Date.utc_today())}
      ],
      incomplete_ranges: [],
      last_error: nil
    }

    projection =
      Map.merge(row.latest_video, %{
        refresh: refresh,
        discovery: discovery,
        search_incomplete: false,
        figures_stale: false,
        newer_possible: false
      })

    shown = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)
    html = render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)
    doc = LazyHTML.from_fragment(html)
    panel = doc |> LazyHTML.query("[data-role='ticker-video-details']") |> LazyHTML.text()
    refute panel =~ "Updating this video's figures last failed"
    assert panel =~ "The vendor's page was incomplete (the request itself succeeded)."
    assert panel =~ "Updating figures · incomplete dates"

    strip =
      doc
      |> LazyHTML.query("[data-ticker-original] [data-role='ticker-latest-video']")
      |> LazyHTML.text()

    refute strip =~ "figures may be out of date"
    refute strip =~ "search incomplete"
  end

  test "successful incomplete discovery remains an unfinished search rather than a failed check",
       %{w: w} do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))

    discovery = %{
      checked_ranges: [],
      incomplete_ranges: [%{"from" => "2026-11-01", "to" => "2026-11-22"}],
      last_error: "incomplete_observation",
      attempted_at: ~U[2026-11-22 08:00:00Z],
      from_date: ~D[2026-11-01],
      to_date: ~D[2026-11-22]
    }

    projection =
      Map.merge(row.latest_video, %{
        video: nil,
        fetched_at: nil,
        discovery: discovery,
        refresh: %{last_error: nil},
        search_incomplete: true,
        figures_stale: false,
        newer_possible: false
      })

    shown = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)
    html = render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)
    doc = LazyHTML.from_fragment(html)

    strip =
      doc
      |> LazyHTML.query("[data-ticker-original] [data-role='ticker-latest-video']")
      |> LazyHTML.text()

    panel = doc |> LazyHTML.query("[data-role='ticker-video-details']") |> LazyHTML.text()
    assert strip =~ "No YouTube video found yet · search incomplete"
    refute strip =~ "Couldn't check YouTube for videos"
    refute panel =~ "last failed"
    assert panel =~ "The vendor's page was incomplete (the request itself succeeded)."
    assert panel =~ "1 Nov 2026 to 22 Nov 2026"
    assert panel =~ "Incomplete:"
  end

  test "coverage repair is local history reset rather than vendor or request failure", %{w: w} do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))
    day = DateTime.to_date(row.latest_video.video.published_at)

    repair = %{
      checked_ranges: [],
      incomplete_ranges: [],
      last_error: "coverage_repaired",
      attempted_at: ~U[2026-11-22 08:00:00Z],
      from_date: day,
      to_date: day
    }

    clean = %{checked_ranges: [], incomplete_ranges: [], last_error: nil}

    for {kind, video, incomplete, message} <- [
          {:discovery, nil, true,
           "Stored search history was invalid and has been reset. A fresh scan is pending or under way."},
          {:refresh, row.latest_video.video, false,
           "Stored update history was invalid and has been reset. A fresh scan is pending or under way."}
        ] do
      projection =
        Map.merge(row.latest_video, %{
          video: video,
          discovery: clean,
          refresh: clean,
          search_incomplete: incomplete,
          figures_stale: false,
          newer_possible: false
        })
        |> Map.put(kind, repair)

      shown = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)

      html =
        render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)

      doc = LazyHTML.from_fragment(html)

      strip =
        doc
        |> LazyHTML.query("[data-ticker-original] [data-role='ticker-latest-video']")
        |> LazyHTML.text()

      panel = doc |> LazyHTML.query("[data-role='ticker-video-details']") |> LazyHTML.text()
      assert panel =~ message
      refute panel =~ "No refresh problem is recorded."
      refute panel =~ "last failed"
      refute panel =~ "the request failed"
      refute strip =~ "Couldn't check YouTube"
      refute strip =~ "figures may be out of date"

      if kind == :discovery do
        assert strip =~ "No YouTube video found yet · search incomplete"
        assert panel =~ "The dates still to check are not available."
      end
    end
  end

  test "refresh diagnostics never reassure when an error of any kind is recorded", %{w: w} do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))
    day = DateTime.to_date(row.latest_video.video.published_at)

    for error <- ["incomplete_observation", "coverage_repaired", "refresh_failed"] do
      refresh = %{
        last_error: error,
        from_date: day,
        to_date: day,
        attempted_at: ~U[2026-11-22 08:00:00Z]
      }

      projection = Map.merge(row.latest_video, %{refresh: refresh, figures_stale: false})
      shown = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)

      html =
        render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)

      panel =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='ticker-video-details']")
        |> LazyHTML.text()

      refute panel =~ "No refresh problem is recorded."
      refute panel =~ "Looking for videos in"

      expected =
        case error do
          "incomplete_observation" ->
            "The vendor's page was incomplete (the request itself succeeded)."

          "coverage_repaired" ->
            "Stored update history was invalid and has been reset."

          "refresh_failed" ->
            "Updating this video's figures last failed"
        end

      assert panel =~ expected
    end
  end

  test "unreadable coverage reports unavailable dates without ranges or newer-video inference", %{
    w: w
  } do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))

    unavailable = %{
      coverage_unavailable: true,
      checked_ranges: [%{"from" => "2026-01-01", "to" => "2026-01-31"}],
      incomplete_ranges: [%{"from" => "2026-02-01", "to" => "2026-02-28"}],
      last_error: nil
    }

    projection =
      Map.merge(row.latest_video, %{
        discovery: unavailable,
        refresh: unavailable,
        search_incomplete: true,
        newer_possible: true
      })

    shown = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)
    html = render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)

    panel =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='ticker-video-details']")
      |> LazyHTML.text()

    assert panel =~ "Dates checked: not available"
    assert panel =~ "The dates still to check are not available."
    refute panel =~ "Not checked yet"
    refute panel =~ "Jan 2026"
    refute panel =~ "Feb 2026"
    refute panel =~ "A newer video may exist"
  end

  test "no-video details contain discovery only and an existing video has neutral missing-vendor-time copy",
       %{w: w} do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))

    projection =
      Map.merge(row.latest_video, %{
        video: nil,
        search_incomplete: true,
        refresh: %{last_error: "refresh_failed", checked_ranges: [], incomplete_ranges: []}
      })

    shown = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)
    html = render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)

    panel =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='ticker-video-details']")
      |> LazyHTML.text()

    assert panel =~ "Search"

    for omitted <- [
          "Lifetime views",
          "Vendor last-sync time",
          "Last response received by Burrow",
          "updating figures",
          "Updating figures",
          "Figures",
          "shown figures"
        ] do
      refute panel =~ omitted
    end

    projection = %{row.latest_video | video: %{row.latest_video.video | vendor_synced_at: nil}}
    shown = Map.put(shown, :latest_video, projection)
    html = render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)

    panel =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='ticker-video-details']")
      |> LazyHTML.text()

    assert panel =~ "No vendor time is recorded"
    refute panel =~ "The vendor gave no time"
  end

  test "details span the full width below the strip controls with local phone scrolling clearance",
       %{w: w} do
    {a, _} = youtube_publication!(w)

    row =
      AccountTicker.rows(w.approver, [w.profile.id])
      |> Enum.find(&(&1.account.id == a.id))
      |> Map.put(:ticker_details_open, true)

    html = render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [row], scope: :all)
    doc = LazyHTML.from_fragment(html)

    assert Enum.count(
             LazyHTML.query(
               doc,
               "#social-account-ticker > [data-role='ticker-strip-row'] + [data-role='ticker-video-details']"
             )
           ) == 1

    assert Enum.count(
             LazyHTML.query(doc, "[data-role='ticker-strip-row'] > .social-ticker-controls")
           ) == 1

    assert Enum.empty?(
             LazyHTML.query(doc, "[data-ticker-viewport] [data-role='ticker-video-details']")
           )

    [classes] =
      doc |> LazyHTML.query("[data-role='ticker-video-details']") |> LazyHTML.attribute("class")

    assert "overflow-y-auto" in String.split(classes)
    assert classes =~ "pb-[calc("
    assert classes =~ "scroll-mb-[calc("
  end

  test "repair explanation survives a successful partial page that clears the last error", %{w: w} do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))

    partial = %{
      checked_ranges: [],
      incomplete_ranges: [%{"from" => "2026-11-01", "to" => "2026-11-22"}],
      last_error: nil,
      coverage_repaired_at: ~U[2026-11-22 08:00:00Z]
    }

    clean = %{checked_ranges: [], incomplete_ranges: [], last_error: nil}

    for {kind, video, message} <- [
          {:discovery, nil, "Stored search history was invalid and has been reset."},
          {:refresh, row.latest_video.video,
           "Stored update history was invalid and has been reset."}
        ] do
      projection =
        Map.merge(row.latest_video, %{
          video: video,
          discovery: clean,
          refresh: clean,
          figures_stale: false,
          search_incomplete: true,
          newer_possible: false
        })
        |> Map.put(kind, partial)

      shown = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)

      html =
        render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)

      panel =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='ticker-video-details']")
        |> LazyHTML.text()

      assert panel =~ message
      assert panel =~ "1 Nov 2026 to 22 Nov 2026"
      refute panel =~ "No refresh problem is recorded."
      refute panel =~ "last failed"
    end
  end

  test "details heading qualifies incomplete or uncertain selection and never claims an unavailable video",
       %{w: w} do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))

    for {video, incomplete, uncertain, label} <- [
          {row.latest_video.video, true, false, "Most recent YouTube video found"},
          {row.latest_video.video, false, true, "Most recent YouTube video found"},
          {row.latest_video.video, false, false, "Latest YouTube video"},
          {nil, true, false, "YouTube video search"}
        ] do
      projection =
        Map.merge(row.latest_video, %{
          video: video,
          search_incomplete: incomplete,
          selection_uncertain: uncertain
        })

      shown = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)

      html =
        render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)

      heading =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='ticker-details-heading']")
        |> LazyHTML.text()

      assert heading =~ label <> " · @latest-video"
      assert heading =~ w.profile.name

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("[data-ticker-original] [data-role='ticker-data-details']")
             |> LazyHTML.attribute("aria-label") == [
               "Data details for " <> label <> " on @latest-video"
             ]
    end
  end

  test "incomplete search with no recorded range states uncertainty without inventing dates", %{
    w: w
  } do
    {a, _} = youtube_publication!(w)
    row = Enum.find(AccountTicker.rows(w.approver, [w.profile.id]), &(&1.account.id == a.id))

    projection =
      Map.merge(row.latest_video, %{
        video: nil,
        search_incomplete: true,
        newer_possible: false,
        discovery: %{checked_ranges: [], incomplete_ranges: [], last_error: nil}
      })

    shown = row |> Map.put(:latest_video, projection) |> Map.put(:ticker_details_open, true)
    html = render_component(&PlatformWeb.SocialAccountTicker.strip/1, rows: [shown], scope: :all)

    text =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='ticker-video-details']")
      |> LazyHTML.text()

    assert text =~ "Search incomplete. The dates still to check are not available."
    refute text =~ "Not checked yet not yet checked"
    refute text =~ "Complete for"
    refute text =~ "A newer video may exist"
  end

  test "cached latest video hides on project revocation or provider profile change without hiding legacy ticker",
       %{conn: conn, w: w} do
    youtube_publication!(w)
    view = open(conn, w)
    assert has_element?(view, "[data-role='ticker-latest-video']")
    Repo.update!(Ecto.Changeset.change(w.profile, provider_profile_ref: "different-profile"))
    render_click(view, "ticker_results", %{"account_id" => w.tiktok.id})
    refute has_element?(view, "[data-role='ticker-latest-video'] a")
    assert has_element?(view, "[data-metric='followers']")

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Social.Profile, w.profile.id),
        provider_profile_ref: "ticker-profile"
      )
    )

    view = open(conn, w)
    assert has_element?(view, "[data-role='ticker-latest-video'] a")

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, w.approver.id},
               permission: "social.use",
               resource: {:project, w.project.id}
             })

    render_click(view, "ticker_results", %{"account_id" => w.tiktok.id})
    refute has_element?(view, "[data-role='ticker-latest-video']")
    assert has_element?(view, "[data-metric='followers']")
  end

  test "render rechecks cached publication authority per profile while legacy rows remain", %{
    w: w
  } do
    {a, _} = youtube_publication!(w)

    {:ok, legacy} =
      Social.create_profile(w.org_id, %{name: "Legacy visible brand", project_id: nil})

    {:ok, other} =
      Social.create_account(w.org_id, legacy, %{
        platform: "youtube",
        provider: "zernio",
        provider_account_ref: "legacy-video-account",
        status: "connected"
      })

    rows = AccountTicker.rows(w.approver, [w.profile.id, legacy.id])
    assert Enum.find(rows, &(&1.account.id == a.id)).latest_video.video
    assert Enum.find(rows, &(&1.account.id == other.id)).latest_video == nil
    assigns = %{user: w.approver, scope: :all, ticker_rows: rows}

    Req.Test.stub(Social.Publisher.Zernio, fn _ ->
      flunk("cached render must not request vendor")
    end)

    assert Enum.find(
             PlatformWeb.SocialAccountTicker.visible_rows(assigns),
             &(&1.account.id == a.id)
           ).latest_video.video

    Repo.update!(Ecto.Changeset.change(a, provider: "different-provider"))

    assert Enum.find(
             PlatformWeb.SocialAccountTicker.visible_rows(assigns),
             &(&1.account.id == a.id)
           ).latest_video == nil

    Repo.update!(Ecto.Changeset.change(Repo.get!(Social.Account, a.id), provider: nil))
    original_publisher = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, Social.Publisher.Fake)
    on_exit(fn -> Application.put_env(:social, :publisher, original_publisher) end)

    assert Enum.find(
             PlatformWeb.SocialAccountTicker.visible_rows(assigns),
             &(&1.account.id == a.id)
           ).latest_video == nil

    Application.put_env(:social, :publisher, original_publisher)
    Repo.update!(Ecto.Changeset.change(Repo.get!(Social.Account, a.id), provider: "zernio"))

    {:ok, moved_profile} =
      Social.create_profile(w.org_id, %{name: "Another project brand", project_id: w.project.id})

    moved_profile =
      Repo.update!(Ecto.Changeset.change(moved_profile, provider_profile_ref: "ticker-profile"))

    Repo.update!(Ecto.Changeset.change(a, profile_id: moved_profile.id))

    assert Enum.find(
             PlatformWeb.SocialAccountTicker.visible_rows(assigns),
             &(&1.account.id == a.id)
           ).latest_video == nil

    Repo.update!(Ecto.Changeset.change(Repo.get!(Social.Account, a.id), profile_id: w.profile.id))
    Repo.update!(Ecto.Changeset.change(w.profile, provider_profile_ref: "reconnected-profile"))

    assert Enum.find(
             PlatformWeb.SocialAccountTicker.visible_rows(assigns),
             &(&1.account.id == a.id)
           ).latest_video == nil

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Social.Profile, w.profile.id),
        provider_profile_ref: "ticker-profile"
      )
    )

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, w.approver.id},
               permission: "social.use",
               resource: {:project, w.project.id}
             })

    current = PlatformWeb.SocialAccountTicker.visible_rows(assigns)
    assert Enum.find(current, &(&1.account.id == a.id)).latest_video == nil
    assert Enum.find(current, &(&1.account.id == other.id))
    assert Enum.find(current, &(&1.account.id == w.tiktok.id)).followers.value == 104
  end
end

defmodule PlatformWeb.SocialAccountTickerTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialStudioFixtures
  alias Platform.{Repo, Social}
  alias Platform.Social.{AccountTicker, FollowerSyncState}

  setup do
    w = studio_world!()

    profile =
      Repo.update!(Ecto.Changeset.change(w.profile, provider_profile_ref: "ticker-profile"))

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
             "[data-role=social-account-ticker] > .social-ticker-controls > [data-ticker-toggle]"
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
end

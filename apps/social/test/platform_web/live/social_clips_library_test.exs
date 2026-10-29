defmodule PlatformWeb.SocialClipsLibraryTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  alias Platform.{Repo, Social}
  alias Platform.Social.AgentDrafts

  setup do
    w = render_world!()

    {:ok, ig} =
      Social.create_account(w.org_id, w.profile, %{platform: "instagram", handle: "@ig"})

    {:ok, _} = Social.create_account(w.org_id, w.profile, %{platform: "youtube", handle: "@yt"})
    %{w: Map.put(w, :ig, ig)}
  end

  defp clip!(w, title, attrs \\ %{}, fields \\ []) do
    file = stored_file!(w.project, "library #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        Map.merge(
          %{
            file_id: file.id,
            title: title,
            episode_code: "S2E14",
            duration_s: 44,
            caption: "A caption",
            platforms: ["instagram", "tiktok"]
          },
          attrs
        ),
        w.agent.id
      )

    fields =
      if fields[:review_status] in ["approved", "rejected"] do
        Keyword.merge(
          [
            reviewed_at: DateTime.utc_now(),
            reviewed_by_user_id: w.approver.id,
            review_note: "A review note",
            reviewed_render_id: render_id!(clip)
          ],
          fields
        )
      else
        fields
      end

    clip |> Ecto.Changeset.change(fields) |> Repo.update!()
  end

  defp open(conn, user, profile) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, parent, _} = live(conn, "/m/social?tab=clips&view=library&profile=#{profile.id}")
    find_live_child(parent, "ext-page-social")
  end

  defp search(view, q),
    do: view |> element("#social-clips-library form") |> render_change(%{"q" => q})

  defp filter(view, key, value) do
    view
    |> element("[data-role=library-filter-option][data-key='#{key}'][data-value='#{value}']")
    |> render_click()
  end

  defp clear(view, key),
    do: view |> element("[data-role=library-chip][data-key='#{key}']") |> render_click()

  defp card?(view, clip), do: has_element?(view, "#library-clip-#{clip.id}")
  defp count(view, text), do: assert(has_element?(view, "[data-role=library-count]", text))

  test "search matches title and caption case-insensitively and resets the stream", %{
    conn: conn,
    w: w
  } do
    title = clip!(w, "Solar lighthouse")
    caption = clip!(w, "Unrelated", %{caption: "A SOLAR caption"})
    other = clip!(w, "Garden")
    view = open(conn, w.approver, w.profile)
    count(view, "3 of 3 clips")
    assert has_element?(view, "#library-search[placeholder='Search title, caption']")
    # LiveSocket merges button.value into a click payload. A field named value
    # is overwritten by the button's empty native value in a real browser.
    assert has_element?(view, "[data-role=library-filter-option][phx-value-option='In review']")
    refute has_element?(view, "[data-role=library-filter-option][phx-value-value]")
    search(view, "solar")
    assert card?(view, title)
    assert card?(view, caption)
    refute card?(view, other)
    count(view, "2 of 3 clips")
    assert has_element?(view, "[data-role=library-chip][data-key=q]", "Search: solar ×")
    search(view, "garden")
    refute card?(view, title)
    refute card?(view, caption)
    assert card?(view, other)
    clear(view, "q")
    count(view, "3 of 3 clips")

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[data-role=library-clip]")
           |> Enum.count() == 3
  end

  test "combined filters have independent chips and counts apply every OTHER filter and search",
       %{conn: conn, w: w} do
    keep = clip!(w, "Match one")
    rejected = clip!(w, "Match two", %{}, review_status: "rejected")
    other_episode = clip!(w, "Match three", %{episode_code: "S2E15"})
    clip!(w, "Unrelated", %{episode_code: "S2E15"})
    view = open(conn, w.approver, w.profile)
    search(view, "match")
    filter(view, "episode", "S2E14")
    filter(view, "status", "In review")
    assert card?(view, keep)
    refute card?(view, rejected)
    refute card?(view, other_episode)
    count(view, "1 of 4 clips")
    assert has_element?(view, "[data-role=library-chip][data-key=episode]", "Episode: S2E14 ×")
    assert has_element?(view, "[data-role=library-chip][data-key=status]", "Status: In review ×")

    assert has_element?(
             view,
             "[data-key=status][data-value=Rejected] [data-role=library-option-count]",
             "1"
           )

    assert has_element?(
             view,
             "[data-key=episode][data-value=S2E15] [data-role=library-option-count]",
             "1"
           )

    clear(view, "status")
    assert card?(view, rejected)
    refute card?(view, other_episode)
    assert has_element?(view, "[data-role=library-chip][data-key=episode]")
    clear(view, "episode")
    count(view, "3 of 4 clips")
    view |> element("[data-role=library-clear-all]") |> render_click()
    count(view, "4 of 4 clips")
    refute has_element?(view, "[data-role=library-chip]")
    assert has_element?(view, "#library-search[value='']")
  end

  test "date and platform filters narrow actual records and clear-all recovers from empty", %{
    conn: conn,
    w: w
  } do
    today = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    recent = clip!(w, "Fresh", %{platforms: ["instagram"]}, rendered_at: today)

    older =
      clip!(w, "Archive", %{platforms: ["youtube"]}, rendered_at: DateTime.add(today, -10, :day))

    view = open(conn, w.approver, w.profile)
    filter(view, "date", "older")
    filter(view, "platform", "youtube")
    assert card?(view, older)
    refute card?(view, recent)
    assert has_element?(view, "[data-role=library-chip][data-key=date]", "Date: Older ×")

    assert has_element?(
             view,
             "[data-role=library-chip][data-key=platform]",
             "Platform: YouTube ×"
           )

    filter(view, "date", "today")
    count(view, "0 of 2 clips")
    assert has_element?(view, "[data-role=library-empty]", "No clips match.")
    refute has_element?(view, "[data-role=library-clip]")
    view |> element("[data-role=library-empty] button") |> render_click()
    count(view, "2 of 2 clips")
    assert card?(view, recent)
    assert card?(view, older)
  end

  test "newest order includes in-review and rejected; pre-review clips stay out", %{
    conn: conn,
    w: w
  } do
    older = clip!(w, "Earlier", %{}, rendered_at: DateTime.add(DateTime.utc_now(), -600))
    newer = clip!(w, "Later", %{}, review_status: "rejected")
    clip!(w, "Still rendering", %{}, review_status: nil)
    view = open(conn, w.approver, w.profile)

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role=library-clip]")
      |> LazyHTML.attribute("data-clip-id")

    assert ids == [newer.id, older.id]
    assert has_element?(view, "#library-clip-#{older.id} [data-role=library-state]", "In review")
    assert has_element?(view, "#library-clip-#{newer.id} [data-role=library-state]", "Rejected")
    assert has_element?(view, "[data-role=library-meta]", "S2E14 · 0:44")
    assert has_element?(view, "#library-grid[phx-update=stream].grid-cols-2")
    assert has_element?(view, "[data-role=library-thumbnail].aspect-\\[9\\/16\\]")
  end

  test "mixed published IG and failed TikTok remain separate with Failed on the card", %{
    conn: conn,
    w: w
  } do
    clip = clip!(w, "Mixed platforms", %{}, review_status: "approved")

    ig = w.ig

    {:ok, first} = Social.create_post(w.org_id, ig, %{body: "Published", clip_id: clip.id})

    first
    |> Ecto.Changeset.change(
      status: "published",
      clip_id: clip.id,
      approved_by_user_id: w.approver.id,
      approved_at: DateTime.utc_now(),
      published_at: DateTime.utc_now(),
      external_url: "https://example.com/post"
    )
    |> Repo.update!()

    {:ok, second} = Social.create_post(w.org_id, w.tiktok, %{body: "Failed", clip_id: clip.id})

    second
    |> Ecto.Changeset.change(
      status: "failed",
      clip_id: clip.id,
      approved_by_user_id: w.approver.id,
      approved_at: DateTime.utc_now(),
      error: "TOKEN_EXPIRED",
      publish_attempts: 2
    )
    |> Repo.update!()

    view = open(conn, w.approver, w.profile)
    assert has_element?(view, "#library-clip-#{clip.id} [data-role=library-state]", "Failed")

    assert has_element?(
             view,
             "#library-clip-#{clip.id} [data-role=library-platform]",
             "IGPublished"
           )

    assert has_element?(view, "#library-clip-#{clip.id} [data-role=library-platform]", "TTFailed")
  end

  test "Show uses parent's authorized switch path, preserves other filters and removes stale cards",
       %{
         conn: conn,
         w: w
       } do
    original = clip!(w, "Original")

    {:ok, profile} =
      Social.create_profile(w.org_id, %{
        name: "Second show",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id]
      })

    second = clip!(%{w | profile: profile}, "Second", %{platforms: []})
    other = render_world!()
    hidden = clip!(other, "Other organization", %{platforms: ["tiktok"]})
    view = open(conn, w.approver, w.profile)
    search(view, "original")

    assert has_element?(
             view,
             "[data-role=library-show-option][data-value='#{profile.id}'] [data-role=library-option-count]",
             "0"
           )

    refute has_element?(view, "[data-role=library-show-option][data-value='#{other.profile.id}']")

    view
    |> element("[data-role=library-show-option][data-value='#{profile.id}']")
    |> render_click()

    refute card?(view, original)
    refute card?(view, second)
    refute card?(view, hidden)
    count(view, "0 of 1 clips")
    assert has_element?(view, "[data-role=library-chip][data-key=show]", "Show: Second show ×")
    assert has_element?(view, "[data-role=library-chip][data-key=q]", "Search: original ×")
    clear(view, "q")
    assert card?(view, second)
    clear(view, "show")
    assert card?(view, second)

    view
    |> element("[data-role=library-show-option][data-value='#{profile.id}']")
    |> render_click()

    assert has_element?(view, "[data-role=library-chip][data-key=show]", "Show: Second show ×")
    render_click(view, "switch_profile", %{"profile_id" => other.profile.id})
    assert card?(view, second)
    refute card?(view, hidden)
  end

  test "invalid filter events cannot crash or expand the current profile", %{conn: conn, w: w} do
    own = clip!(w, "Own clip")
    view = open(conn, w.approver, w.profile)

    with_target(view, "#social-clips-library")
    |> render_click("filter", %{"key" => "status", "option" => "invented"})

    assert card?(view, own)
    count(view, "1 of 1 clips")

    with_target(view, "#social-clips-library")
    |> render_click("filter", %{"key" => "show", "option" => Ecto.UUID.generate()})

    assert card?(view, own)
  end

  test "retained removal controls keep their authorization and broadcasts refresh the stream", %{
    conn: conn,
    w: w
  } do
    clip = clip!(w, "Remove me")
    view = open(conn, w.approver, w.profile)
    view |> element("#library-clip-#{clip.id} [data-role=clip-delete]") |> render_click()
    view |> element("[data-role=clip-delete-confirm]") |> render_click()
    render(view)
    refute card?(view, clip)
    count(view, "0 of 0 clips")
    other_clip = clip!(w, "Read only")
    viewer = member!(user!(), w.org_id)
    readonly = open(conn, viewer, w.profile)
    assert card?(readonly, other_clip)

    assert has_element?(
             readonly,
             "#library-clip-#{other_clip.id} [data-role=clip-delete][disabled]"
           )
  end

  test "revoked profile visibility clears all streamed records on the next filter event", %{
    conn: conn,
    w: w
  } do
    clip = clip!(w, "Private record")
    view = open(conn, w.approver, w.profile)
    assert card?(view, clip)
    import Ecto.Query

    Repo.delete_all(
      from(m in Platform.Tenancy.OrgMembership,
        where: m.user_id == ^w.approver.id and m.org_id == ^w.org_id
      )
    )

    search(view, "Private")
    refute card?(view, clip)
    count(view, "0 of 0 clips")
    refute has_element?(view, "[data-role=library-show-option]")
  end

  defp post!(w, clip, account, status, attrs \\ []) do
    {:ok, post} =
      Social.create_post(w.org_id, account, %{
        body: "Post caption",
        media_file_ids: [clip.render_file_id]
      })

    post
    |> Ecto.Changeset.change(
      Keyword.merge(
        [
          clip_id: clip.id,
          clip_render_id: render_id!(clip),
          status: status,
          approved_by_user_id: w.approver.id,
          approved_at: DateTime.utc_now()
        ],
        attrs
      )
    )
    |> Repo.update!()
  end

  defp detail(view, clip),
    do:
      view |> element("#library-clip-#{clip.id} [data-role=library-thumbnail]") |> render_click()

  defp event(view, name, attrs),
    do: view |> with_target("#social-clips-library") |> render_hook(name, attrs)

  test "detail preserves mixed-platform facts and retries only the failed post", %{
    conn: conn,
    w: w
  } do
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    Platform.Social.RateLimit.reset()
    clip = clip!(w, "Independent posts", %{}, review_status: "approved")

    ig =
      post!(w, clip, w.ig, "published",
        published_at: DateTime.utc_now(),
        external_id: "published-instagram-stays-unchanged",
        external_url: "https://example.com/ig"
      )

    tt = post!(w, clip, w.tiktok, "failed", error: "TOKEN_EXPIRED", publish_attempts: 2)
    view = open(conn, w.approver, w.profile)
    detail(view, clip)
    assert has_element?(view, "#library-detail", "Clip · clip #{String.slice(clip.id, 0, 8)}")
    assert has_element?(view, "[data-post-id='#{ig.id}']", "Published")

    assert has_element?(
             view,
             "[data-post-id='#{ig.id}'] a[href='https://example.com/ig']",
             "View post ↗"
           )

    assert has_element?(view, "[data-post-id='#{tt.id}']", "Failed")
    assert has_element?(view, "[data-post-id='#{tt.id}']", "2 attempts")
    assert has_element?(view, "[data-post-id='#{tt.id}']", "TOKEN_EXPIRED")
    assert has_element?(view, "[data-post-id='#{tt.id}']", "TikTok signed us out.")
    refute has_element?(view, "#library-detail", "views")
    refute has_element?(view, "[data-role=library-reconnected]")
    view |> element("[data-post-id='#{tt.id}'] [data-role=library-retry]") |> render_click()

    assert [%{id: id}] =
             Enum.map(Fake.calls(:publish), fn {:publish, [_, req], _} ->
               %{id: req.idempotency_key}
             end)

    assert id == tt.id
    assert Repo.get!(Platform.Social.Post, ig.id) == ig
    retried = Repo.get!(Platform.Social.Post, tt.id)
    assert retried.status == "scheduled"
    assert retried.publish_attempts == tt.publish_attempts + 1
    assert retried.approved_by_user_id == w.approver.id
    refute has_element?(view, "[data-role=library-retry]")
  end

  test "detail shows recorded renderer, reviewer, rejection note and Review path without invented source",
       %{conn: conn, w: w} do
    w.agent |> Ecto.Changeset.change(name: "Octavius") |> Repo.update!()

    clip =
      clip!(w, "Rejected story", %{}, review_status: "rejected", review_note: "Crop the intro")

    view = open(conn, w.approver, w.profile)
    detail(view, clip)
    assert has_element?(view, "[data-role=library-renderer]", "rendered by Octavius")
    assert has_element?(view, "[data-role=library-decision]", "Rejected by #{w.approver.name}")
    refute has_element?(view, "[data-role=library-decision]", "in chat")
    assert has_element?(view, "[data-role=library-rejection]", "“Crop the intro”")

    assert has_element?(
             view,
             "[data-role=library-open-review][href='/m/social?tab=clips&view=review&clip=#{clip.id}&profile=#{w.profile.id}']"
           )

    assert has_element?(view, "[data-role=library-not-posted]", "Not selected")
    assert has_element?(view, "[data-role=library-not-posted]", "Not posted")
    view |> element("#library-detail header button") |> render_click()
    refute has_element?(view, "#library-detail")
  end

  test "scheduled, queued, uploading and non-auth failure rows retain real facts", %{
    conn: conn,
    w: w
  } do
    clip = clip!(w, "Status variety", %{}, review_status: "approved")

    scheduled =
      post!(w, clip, w.ig, "scheduled", scheduled_at: DateTime.add(DateTime.utc_now(), 86400))

    queued =
      post!(w, clip, w.tiktok, "approved", publish_after: DateTime.add(DateTime.utc_now(), 8))

    {:ok, yt} =
      Social.create_account(w.org_id, w.profile, %{platform: "youtube", handle: "@more"})

    uploading = post!(w, clip, yt, "approved")
    failed = post!(w, clip, w.x, "failed", error: "VIDEO_TOO_LONG", publish_attempts: 3)
    {:ok, _} = Social.update_account(w.org_id, w.x, %{status: "reauth_needed"})
    view = open(conn, w.approver, w.profile)
    detail(view, clip)
    assert has_element?(view, "[data-post-id='#{queued.id}']", "Queued ·")

    assert has_element?(
             view,
             "[data-post-id='#{queued.id}']",
             "publishes when the undo window closes"
           )

    assert has_element?(view, "[data-post-id='#{uploading.id}']", "Uploading")
    refute has_element?(view, "[data-post-id='#{uploading.id}']", "%")
    assert has_element?(view, "[data-post-id='#{failed.id}']", "VIDEO_TOO_LONG")
    refute has_element?(view, "[data-post-id='#{failed.id}']", "signed us out")
    refute has_element?(view, "[data-post-id='#{failed.id}'] [data-role=library-reconnect]")

    view
    |> element("[data-post-id='#{scheduled.id}'] [data-role=library-reschedule]")
    |> render_click()

    assert has_element?(
             view,
             "[data-role=social-tab-button][data-tab=calendar][aria-selected=true]"
           )

    assert has_element?(view, "[data-role=social-post-detail]", "Post caption")
    assert has_element?(view, "[data-role=social-post-detail]", w.ig.handle)
  end

  test "a reader sees no Retry and forged retry makes no writes", %{conn: conn, w: w} do
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    clip = clip!(w, "Read only detail", %{}, review_status: "approved")
    post = post!(w, clip, w.tiktok, "failed", error: "TOKEN_EXPIRED")
    reader = member!(user!(), w.org_id)
    view = open(conn, reader, w.profile)
    detail(view, clip)
    refute has_element?(view, "[data-role=library-retry]")
    refute has_element?(view, "[data-role=library-reconnect]")
    event(view, "retry", %{clip_id: clip.id, post_id: post.id})
    assert Repo.get!(Platform.Social.Post, post.id) == post
    assert Fake.calls(:publish) == []
  end

  test "stale approver or account ownership is rechecked on retry", %{conn: conn, w: w} do
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    clip = clip!(w, "Stale permission", %{}, review_status: "approved")
    post = post!(w, clip, w.tiktok, "failed", error: "TOKEN_EXPIRED")
    view = open(conn, w.approver, w.profile)
    detail(view, clip)
    assert has_element?(view, "[data-role=library-retry]")
    {:ok, _} = Social.set_account_owner(w.org_id, w.tiktok, member!(user!(), w.org_id).id)
    event(view, "retry", %{clip_id: clip.id, post_id: post.id})
    refute has_element?(view, "[data-role=library-retry]")
    assert Repo.get!(Platform.Social.Post, post.id) == post
    assert Fake.calls(:publish) == []
  end

  test "foreign, malformed, unknown, removed and wrong-profile detail or retry ids fail closed",
       %{conn: conn, w: w} do
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    own = clip!(w, "Own", %{}, review_status: "approved")
    own_post = post!(w, own, w.tiktok, "failed", error: "TOKEN_EXPIRED")
    other = render_world!()
    foreign = clip!(other, "Foreign secret", %{platforms: ["tiktok"]}, review_status: "approved")
    foreign_post = post!(other, foreign, other.tiktok, "failed", error: "TOKEN_EXPIRED")
    removed = clip!(w, "Removed", %{}, removed_at: DateTime.utc_now())

    {:ok, profile} =
      Social.create_profile(w.org_id, %{
        name: "Other profile",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id]
      })

    wrong_profile = clip!(%{w | profile: profile}, "Wrong profile", %{platforms: []})
    view = open(conn, w.approver, w.profile)

    for id <- [
          foreign.id,
          removed.id,
          wrong_profile.id,
          Ecto.UUID.generate(),
          "oops",
          nil,
          %{},
          [own.id]
        ] do
      event(view, "open_detail", %{id: id})
      refute has_element?(view, "#library-detail")
      event(view, "retry", %{clip_id: id, post_id: own_post.id})
    end

    event(view, "retry", %{clip_id: own.id, post_id: foreign_post.id})
    assert Repo.get!(Platform.Social.Post, foreign_post.id) == foreign_post
    assert Repo.get!(Platform.Social.Post, own_post.id) == own_post
    assert Fake.calls(:publish) == []
    refute render(view) =~ "Foreign secret"
  end

  test "reconnect is scoped and requires refreshed connected state before confirmation", %{
    conn: conn,
    w: w
  } do
    {:ok, account} = Social.update_account(w.org_id, w.tiktok, %{status: "reauth_needed"})
    clip = clip!(w, "Reconnect detail", %{}, review_status: "approved")
    post = post!(w, clip, account, "failed", error: "TOKEN_EXPIRED")
    view = open(conn, w.approver, w.profile)
    detail(view, clip)
    refute has_element?(view, "[data-role=library-reconnected]")
    html = view |> element("[data-role=library-reconnect]") |> render()
    assert html =~ "connect_account"
    assert html =~ "connections"
    assert html =~ account.id
    event(view, "reconnect", %{clip_id: clip.id, post_id: post.id})
    event(view, "refresh", %{})
    refute has_element?(view, "[data-role=library-reconnected]")
    {:ok, _} = Social.update_account(w.org_id, account, %{status: "connected"})
    event(view, "refresh", %{})
    assert has_element?(view, "[data-role=library-reconnected]", "Reconnected")
    assert has_element?(view, "[data-role=library-retry]")
  end

  test "removing a displayed clip or switching profile clears detail", %{conn: conn, w: w} do
    clip = clip!(w, "Gone after refresh")
    view = open(conn, w.approver, w.profile)
    detail(view, clip)
    clip |> Ecto.Changeset.change(removed_at: DateTime.utc_now()) |> Repo.update!()
    event(view, "refresh", %{})
    refute has_element?(view, "#library-detail")
    remaining = clip!(w, "Switch away")
    event(view, "refresh", %{})
    detail(view, remaining)

    {:ok, profile} =
      Social.create_profile(w.org_id, %{
        name: "Switch target",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id]
      })

    event(view, "refresh", %{})

    view
    |> element("[data-role=library-show-option][data-value='#{profile.id}']")
    |> render_click()

    refute has_element?(view, "#library-detail")
  end

  defp option_counts(view, key) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role=library-filter-option][data-key='#{key}']")
    |> Map.new(fn node ->
      [value] = LazyHTML.attribute(node, "data-value")
      count = node |> LazyHTML.query("[data-role=library-option-count]") |> LazyHTML.text()
      {value, count |> String.trim() |> String.to_integer()}
    end)
  end

  test "all six states and exact faceted counts survive real Show navigation", %{conn: conn, w: w} do
    today = Date.utc_today() |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")
    recent = DateTime.add(today, -2, :day)
    older = DateTime.add(today, -14, :day)
    pending = clip!(w, "Beacon pending", %{}, rendered_at: today)
    rejected = clip!(w, "Beacon rejected", %{}, review_status: "rejected", rendered_at: older)

    published =
      clip!(w, "Beacon published", %{platforms: ["instagram"], episode_code: "S2E15"},
        review_status: "approved",
        rendered_at: recent
      )

    post!(w, published, w.ig, "published", published_at: recent, external_id: "untouched-ig")

    scheduled =
      clip!(w, "Beacon scheduled", %{platforms: ["instagram"], episode_code: "S2E15"},
        review_status: "approved",
        rendered_at: today
      )

    post!(w, scheduled, w.ig, "scheduled", scheduled_at: DateTime.add(today, 2, :day))

    publishing =
      clip!(w, "Beacon publishing", %{platforms: ["tiktok"]},
        review_status: "approved",
        rendered_at: recent
      )

    post!(w, publishing, w.tiktok, "approved")
    failed = clip!(w, "Beacon failed", %{}, review_status: "approved", rendered_at: older)
    post!(w, failed, w.ig, "published", published_at: recent)
    post!(w, failed, w.tiktok, "failed", error: "TOKEN_EXPIRED")

    {:ok, profile} =
      Social.create_profile(w.org_id, %{
        name: "Second beacon show",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id]
      })

    {:ok, _} =
      Social.create_account(w.org_id, profile, %{platform: "instagram", handle: "@second"})

    second =
      clip!(
        %{w | profile: profile},
        "Beacon second",
        %{episode_code: "S2E15", platforms: ["instagram"]},
        rendered_at: today
      )

    foreign_world = render_world!()
    foreign = clip!(foreign_world, "Beacon foreign", %{platforms: ["tiktok"]})
    view = open(conn, w.approver, w.profile)
    count(view, "6 of 6 clips")

    for {clip, state} <- [
          {pending, "In review"},
          {rejected, "Rejected"},
          {published, "Published"},
          {scheduled, "Scheduled"},
          {publishing, "Publishing"},
          {failed, "Failed"}
        ] do
      assert has_element?(view, "#library-clip-#{clip.id} [data-role=library-state]", state)
    end

    refute card?(view, foreign)

    assert option_counts(view, "status") ==
             Map.new(
               ["In review", "Rejected", "Published", "Scheduled", "Publishing", "Failed"],
               &{&1, 1}
             )

    assert option_counts(view, "date") == %{"today" => 2, "this_week" => 2, "older" => 2}
    search(view, "beacon")
    filter(view, "episode", "S2E15")
    filter(view, "platform", "instagram")
    filter(view, "date", "today")
    filter(view, "status", "Scheduled")
    count(view, "1 of 6 clips")
    assert option_counts(view, "date") == %{"today" => 1, "this_week" => 0, "older" => 0}
    assert option_counts(view, "episode") == %{"S2E14" => 0, "S2E15" => 1}

    assert option_counts(view, "status") == %{
             "In review" => 0,
             "Rejected" => 0,
             "Published" => 0,
             "Scheduled" => 1,
             "Publishing" => 0,
             "Failed" => 0
           }

    assert option_counts(view, "platform")["instagram"] == 1
    assert option_counts(view, "platform")["tiktok"] == 0
    clear(view, "status")
    assert option_counts(view, "date") == %{"today" => 1, "this_week" => 1, "older" => 0}
    detail(view, scheduled)

    view
    |> element("[data-role=library-show-option][data-value='#{profile.id}']")
    |> render_click()

    assert card?(view, second)
    refute has_element?(view, "#library-detail")
    count(view, "1 of 1 clips")
    assert has_element?(view, "[data-role=library-chip][data-key=episode]", "S2E15")

    for old <- [pending, rejected, published, scheduled, publishing, failed, foreign],
        do: refute(card?(view, old))

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role=library-clip]")
      |> LazyHTML.attribute("data-clip-id")

    assert ids == [second.id]
    search(view, "no-match")
    count(view, "0 of 1 clips")
    view |> element("[data-role=library-empty] button") |> render_click()
    count(view, "1 of 1 clips")
    assert card?(view, second)
  end

  test "Reconnect executes Connections for the failed account and no other account", %{
    conn: conn,
    w: w
  } do
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    {:ok, account} = Social.update_account(w.org_id, w.tiktok, %{status: "reauth_needed"})
    clip = clip!(w, "Connections target", %{}, review_status: "approved")
    post = post!(w, clip, account, "failed", error: "TOKEN_EXPIRED")
    view = open(conn, w.approver, w.profile)
    detail(view, clip)
    url = "https://fake-publisher.example.test/library-reconnect"
    Fake.put_next(:connect_url, {:ok, url})
    view |> element("[data-post-id='#{post.id}'] [data-role=library-reconnect]") |> render_click()
    assert_redirect(view, url)
    assert [{:connect_url, [connected, opts], _}] = Fake.calls(:connect_url)
    assert connected.id == account.id
    assert opts[:profile].id == w.profile.id
    assert Repo.get!(Platform.Social.Post, post.id) == post
    assert Fake.calls(:publish) == []
  end

  test "invalid event shapes preserve the valid filter and expose no detail", %{conn: conn, w: w} do
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    clip = clip!(w, "Robust event")
    view = open(conn, w.approver, w.profile)
    search(view, "Robust")

    for {name, payload} <- [
          {"filter", %{}},
          {"filter", %{key: %{}, option: []}},
          {"filter", %{key: "date", option: "yesterday"}},
          {"search", %{q: %{unexpected: true}}},
          {"select_show", %{profile_id: []}},
          {"clear_filter", %{key: %{}}},
          {"open_detail", %{}},
          {"retry", %{post_id: [clip.id]}},
          {"reconnect", %{clip_id: %{}}}
        ] do
      event(view, name, payload)
      assert Process.alive?(view.pid)
      assert card?(view, clip)
      assert has_element?(view, "[data-role=library-chip][data-key=q]", "Search: Robust ×")
      refute has_element?(view, "#library-detail")
    end

    assert Fake.calls(:publish) == []
  end

  test "real agent identity has no Library or Retry and forged parent events publish nothing", %{
    conn: conn,
    w: w
  } do
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    clip = clip!(w, "Human-only retry", %{}, review_status: "approved")
    post = post!(w, clip, w.tiktok, "failed", error: "TOKEN_EXPIRED")
    agent_conn = Plug.Test.init_test_session(conn, current_user_id: w.agent.id)

    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live(agent_conn, "/m/social?tab=clips&view=library")

    # The real authenticated route rejects an agent ID. Exercise SocialLive's
    # nil-human guard as well, using its normal session contract, not assigns.
    {:ok, view, _} =
      live_isolated(build_conn(), PlatformWeb.SocialLive, session: %{"user_id" => w.agent.id})

    refute has_element?(view, "[data-role=library-retry]")
    refute has_element?(view, "[data-role=clips-library]")
    render_hook(view, "retry", %{clip_id: clip.id, post_id: post.id})
    render_hook(view, "open_detail", %{id: clip.id})
    assert Process.alive?(view.pid)
    assert Repo.get!(Platform.Social.Post, post.id) == post
    assert Fake.calls(:publish) == []
  end

  test "same-org wrong-profile posts and forged mixed IDs cannot be retried", %{conn: conn, w: w} do
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    own = clip!(w, "Current profile", %{}, review_status: "approved")
    own_post = post!(w, own, w.tiktok, "failed", error: "TOKEN_EXPIRED")

    {:ok, profile} =
      Social.create_profile(w.org_id, %{
        name: "Other authorized show",
        project_id: w.project.id,
        approver_user_ids: [w.approver.id]
      })

    {:ok, account} =
      Social.create_account(w.org_id, profile, %{platform: "tiktok", handle: "@other-show"})

    other_w = %{w | profile: profile}

    other =
      clip!(other_w, "Other profile secret", %{platforms: ["tiktok"]}, review_status: "approved")

    other_post = post!(other_w, other, account, "failed", error: "TOKEN_EXPIRED")
    view = open(conn, w.approver, w.profile)
    detail(view, own)
    event(view, "open_detail", %{id: other.id})
    refute has_element?(view, "#library-detail")

    for {clip_id, post_id} <- [
          {own.id, other_post.id},
          {other.id, own_post.id},
          {other.id, other_post.id},
          {own.id, %{}},
          {own.id, []},
          {own.id, nil}
        ] do
      event(view, "retry", %{clip_id: clip_id, post_id: post_id})
      assert Repo.get!(Platform.Social.Post, own_post.id) == own_post
      assert Repo.get!(Platform.Social.Post, other_post.id) == other_post
      assert Fake.calls(:publish) == []
      refute render(view) =~ "Other profile secret"
    end
  end

  test "revoking profile approver permission after mount denies stale Retry", %{conn: conn, w: w} do
    alias Platform.Social.Publisher.Fake
    Fake.reset()
    clip = clip!(w, "Revoked approver", %{}, review_status: "approved")
    post = post!(w, clip, w.tiktok, "failed", error: "TOKEN_EXPIRED")
    view = open(conn, w.approver, w.profile)
    detail(view, clip)
    assert has_element?(view, "[data-role=library-retry]")
    w.profile |> Ecto.Changeset.change(approver_user_ids: []) |> Repo.update!()
    event(view, "retry", %{clip_id: clip.id, post_id: post.id})
    refute has_element?(view, "[data-role=library-retry]")
    assert Repo.get!(Platform.Social.Post, post.id) == post
    assert Fake.calls(:publish) == []
  end
end

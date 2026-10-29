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
end

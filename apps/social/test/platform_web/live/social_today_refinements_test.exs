defmodule PlatformWeb.SocialTodayRefinementsTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures
  alias Platform.{Repo, Social}

  defp open(conn, w) do
    {:ok, parent, _} =
      conn
      |> Plug.Test.init_test_session(current_user_id: w.approver.id)
      |> live("/m/social?profile=#{w.profile.id}")

    find_live_child(parent, "ext-page-social")
  end

  defp thumbnail_ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("id")
  end

  defp card(post), do: "[data-role='studio-post'][data-post-id='#{post.id}']"

  test "post cards prefer the stored cover, then video frame or image, and keep text-only cards",
       %{conn: conn} do
    w = studio_world!()
    video = stored_file!(w.project, "video", "clip.mp4", "video/mp4")
    image = stored_file!(w.project, "cover", "cover.png", "image/png")

    covered =
      studio_post!(w, w.tiktok, "draft", %{
        body: "Covered",
        media_file_ids: [video.id],
        cover_file_id: image.id
      })

    {:ok, %{post: covered}} =
      Social.Studio.save_version(
        w.org_id,
        covered.id,
        {:human, w.approver.id},
        %{cover_file_id: image.id},
        expect(covered)
      )

    assert covered.cover_file_id == image.id

    filmed = studio_post!(w, w.tiktok, "draft", %{body: "Video", media_file_ids: [video.id]})
    pictured = studio_post!(w, w.x, "draft", %{body: "Image", media_file_ids: [image.id]})
    text = studio_post!(w, w.x, "draft", %{body: "Text only"})
    view = open(conn, w)

    assert has_element?(
             view,
             "#{card(covered)} [data-role='studio-post-open'] img[src='/files/blob/#{image.id}'][alt='']"
           )

    thumb = "[data-role='studio-post-thumbnail']"

    assert has_element?(
             view,
             "#{card(covered)} #{thumb}[phx-hook='SocialThumbnail'][phx-update='ignore']"
           )

    ids = thumbnail_ids(view, thumb)
    assert length(ids) == 3
    assert length(Enum.uniq(ids)) == 3
    assert Enum.all?(ids, &(String.trim(&1) != ""))
    assert [covered_id] = thumbnail_ids(view, "#{card(covered)} #{thumb}")
    # A revert guard only; computed display/line count belongs to the built-CSS browser check.
    assert [body_classes] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#{card(covered)} span.line-clamp-3")
             |> LazyHTML.attribute("class")

    assert "line-clamp-3" in String.split(body_classes)
    refute "block" in String.split(body_classes)

    refute has_element?(view, "#{card(covered)} video")

    assert has_element?(
             view,
             "#{card(filmed)} video[src='/files/blob/#{video.id}#t=0.1'][preload='metadata'][muted][playsinline]"
           )

    refute has_element?(view, "#{card(filmed)} video[controls]")
    assert has_element?(view, "#{card(pictured)} img[src='/files/blob/#{image.id}']")
    refute has_element?(view, "#{card(text)} [data-role='studio-post-thumbnail']")
    view |> element("#{card(covered)} [data-role='studio-post-open']") |> render_click()
    assert has_element?(view, "[data-role='studio-post-detail'][data-post-id='#{covered.id}']")
    assert thumbnail_ids(view, "#{card(covered)} #{thumb}") == [covered_id]
    view |> element("[data-role='social-tab-button'][data-tab='ideas']") |> render_click()
    view |> element("[data-role='social-tab-button'][data-tab='today']") |> render_click()
    assert thumbnail_ids(view, "#{card(covered)} #{thumb}") == [covered_id]
  end

  test "a denied viewer gets usable cards without image or video URLs", %{conn: conn} do
    w = studio_world!()
    file = stored_file!(w.project, "video", "clip.mp4", "video/mp4")
    image = stored_file!(w.project, "cover", "cover.png", "image/png")

    post =
      studio_post!(w, w.tiktok, "draft", %{
        body: "Still openable",
        media_file_ids: [file.id],
        cover_file_id: image.id
      })

    {:ok, %{post: post}} =
      Social.Studio.save_version(
        w.org_id,
        post.id,
        {:human, w.approver.id},
        %{cover_file_id: image.id},
        expect(post)
      )

    assert post.cover_file_id == image.id

    clip = w |> pending_clip!() |> make_studio_clip!()

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, w.approver.id},
        permission: "files.read",
        resource: {:project, w.project.id}
      })

    view = open(conn, w)
    assert has_element?(view, card(post), "Still openable")
    refute has_element?(view, "#{card(post)} img, #{card(post)} video")
    refute render(view) =~ "/files/blob/#{file.id}"
    refute render(view) =~ "/files/blob/#{image.id}"
    refute has_element?(view, "[data-role='studio-clip'][data-clip-id='#{clip.id}'] video")

    refute has_element?(
             view,
             "[data-role='studio-clip'][data-clip-id='#{clip.id}'] [phx-hook='ChatClip']"
           )

    assert has_element?(
             view,
             "[data-role='studio-clip'][data-clip-id='#{clip.id}'] [role='status']",
             "Video unavailable."
           )
  end

  test "wrong-project, wrong-org and deleted files never become a thumbnail", %{conn: conn} do
    w = studio_world!()
    other = stored_file!(project!(w.org_id), "other", "other.png", "image/png")
    foreign = stored_file!(project!(org_id!()), "foreign", "foreign.png", "image/png")
    wrong_org = stored_file!(w.project, "wrong org", "wrong-org.png", "image/png")
    wrong_org = Repo.update!(Ecto.Changeset.change(wrong_org, org_id: org_id!()))
    deleted = stored_file!(w.project, "gone", "gone.png", "image/png")
    Repo.update!(Ecto.Changeset.change(deleted, deleted_at: DateTime.utc_now()))

    for file <- [other, foreign, wrong_org, deleted] do
      post = studio_post!(w, w.x, "draft", %{body: "Forged stale media"})
      Repo.update!(Ecto.Changeset.change(post, media_file_ids: [file.id], cover_file_id: file.id))
    end

    view = open(conn, w)

    for file <- [other, foreign, wrong_org, deleted],
        do: refute(render(view) =~ "/files/blob/#{file.id}")

    refute has_element?(view, "[data-role='studio-post-thumbnail']")
  end

  test "clip preview requests the existing first frame without changing the media", %{conn: conn} do
    w = studio_world!()
    clip = w |> pending_clip!() |> make_studio_clip!()
    view = open(conn, w)

    assert has_element?(
             view,
             "[data-role='studio-clip'][data-clip-id='#{clip.id}'] video[src='/files/blob/#{clip.render_file_id}#t=0.1'][controls]"
           )
  end

  test "Today has semantic idea lists and only saved Wikipedia provenance gets the badge", %{
    conn: conn
  } do
    w = studio_world!()

    {:ok, agent_idea} =
      Social.Ideas.create(w.org_id, w.profile.id, %{title: "Agent pitch"}, {:agent, w.agent.id})

    {:ok, plain} =
      Social.Ideas.create(
        w.org_id,
        w.profile.id,
        %{
          title: "Plain URL",
          source_kind: "url",
          source_url: "https://en.wikipedia.org/wiki/Plain"
        },
        {:user, w.approver.id}
      )

    {:ok, snapshot} =
      Social.Trends.record_snapshot(%{
        source: "wikimedia_pageviews",
        limit: 1,
        complete: true,
        reporting_date: Date.add(Date.utc_today(), -1),
        observed_at: DateTime.utc_now(),
        items: [
          %{
            id: "article",
            rank: 3,
            title: "Wikipedia story",
            url: "https://en.wikipedia.org/wiki/Story",
            pageviews: 42
          }
        ]
      })

    {:ok, wiki} =
      Social.Trends.turn_into_idea(
        w.org_id,
        w.profile.id,
        "wikimedia_pageviews",
        "article",
        w.approver.id,
        snapshot.id
      )

    {:ok, other_snapshot} =
      Social.Trends.record_snapshot(%{
        source: "other_provider",
        limit: 1,
        complete: true,
        reporting_date: Date.add(Date.utc_today(), -1),
        observed_at: DateTime.utc_now(),
        items: [
          %{
            id: "other",
            rank: 1,
            title: "Other source",
            url: "https://example.test/article",
            pageviews: 10
          }
        ]
      })

    {:ok, other_idea} =
      Social.Trends.turn_into_idea(
        w.org_id,
        w.profile.id,
        "other_provider",
        "other",
        w.approver.id,
        other_snapshot.id
      )

    view = open(conn, w)
    assert has_element?(view, "ul > li[data-role='studio-agent-idea']", agent_idea.title)
    refute has_element?(view, "li[data-role='studio-agent-idea']", w.profile.name)

    assert has_element?(
             view,
             "[data-role='studio-trends'] h2 [data-role='wikipedia-badge']",
             "Wikipedia"
           )

    assert has_element?(view, "[data-role='studio-trends'] ul > li [data-role='trend-rank']", "1")
    assert has_element?(view, "[data-role='studio-trends'] ul > li a", "Wikipedia story")
    view |> element("[data-role='social-tab-button'][data-tab='ideas']") |> render_click()

    assert has_element?(
             view,
             "[data-idea-id='#{wiki.id}'] [data-role='idea-wikipedia-source']",
             "From Wikipedia"
           )

    refute has_element?(view, "[data-idea-id='#{plain.id}'] [data-role='idea-wikipedia-source']")

    refute has_element?(
             view,
             "[data-idea-id='#{other_idea.id}'] [data-role='idea-wikipedia-source']"
           )

    view |> element("[data-role='idea-card-open'][phx-value-id='#{wiki.id}']") |> render_click()

    assert has_element?(
             view,
             "[data-role='idea-detail'] [data-role='idea-wikipedia-source']",
             "From Wikipedia"
           )
  end

  test "unsupported thumbnail formats leave a usable text card", %{conn: conn} do
    w = studio_world!()

    for type <- ["image/tiff", "image/svg+xml"] do
      file = stored_file!(w.project, "unsupported #{type}", "unsupported-image", type)
      studio_post!(w, w.x, "draft", %{body: "Still readable", media_file_ids: [file.id]})
    end

    view = open(conn, w)
    refute has_element?(view, "[data-role='studio-post-thumbnail']")
    assert has_element?(view, "[data-role='studio-post-open']", "Still readable")
  end

  test "clip failure handling uses the existing player with an accessible unavailable state", %{
    conn: conn
  } do
    w = studio_world!()
    clip = w |> pending_clip!() |> make_studio_clip!()
    view = open(conn, w)

    assert has_element?(
             view,
             "[data-role='studio-clip'][data-clip-id='#{clip.id}'] [phx-hook='ChatClip'] [data-role='clip-fallback'][role='status']",
             "Video unavailable"
           )
  end
end

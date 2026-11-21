defmodule PlatformWeb.SocialStudioAgentDraftTodayTest do
  @moduledoc """
  A draft made by `social_studio_draft_create` shows on Today marked as
  agent-drafted, and a person who may submit it can, with the page's own
  "Submit for approval" control (no new control exists).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Social

  defp open(conn, user, profile) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, parent, _} = live(conn, "/m/social?profile=#{profile.id}")
    find_live_child(parent, "ext-page-social")
  end

  defp agent_draft!(w, body, media_file_ids \\ []) do
    {:ok, %{post: post}} =
      ToolArguments.dispatch(
        "social_studio_draft_create",
        %{
          "account_id" => w.tiktok.id,
          "request_id" => "page-#{System.unique_integer()}",
          "body" => body,
          "media_file_ids" => media_file_ids
        },
        %{agent_id: w.agent.id}
      )

    post
  end

  defp open_detail(view, post) do
    view
    |> Phoenix.LiveViewTest.element("[data-role='studio-post-open'][data-post-id='#{post.id}']")
    |> render_click()

    view
  end

  @video "[data-role='studio-post-detail'] video"

  @label "Drafted by an agent · not reviewed"

  test "the card and the review panel carry the label; a person's draft does not", %{conn: conn} do
    w = studio_world!()
    post = agent_draft!(w, "Written by the agent")
    human = studio_post!(w, w.x, "draft", %{body: "Written by a person"})
    view = open(conn, w.approver, w.profile)

    card = "[data-role='studio-post'][data-post-id='#{post.id}']"
    human_card = "[data-role='studio-post'][data-post-id='#{human.id}']"

    assert has_element?(view, card, "Written by the agent")
    assert has_element?(view, "#{card} [data-role='studio-agent-drafted']", @label)
    refute has_element?(view, "#{human_card} [data-role='studio-agent-drafted']")
    refute render(view) =~ "Agent-drafted"

    view
    |> Phoenix.LiveViewTest.element("[data-role='studio-post-open'][data-post-id='#{post.id}']")
    |> render_click()

    assert has_element?(
             view,
             "[data-role='studio-post-detail'] [data-role='studio-detail-agent-drafted']",
             @label
           )

    view
    |> Phoenix.LiveViewTest.element("[data-role='studio-post-open'][data-post-id='#{human.id}']")
    |> render_click()

    assert has_element?(view, "[data-role='studio-post-detail']", "Written by a person")
    refute has_element?(view, "[data-role='studio-detail-agent-drafted']")
  end

  test "a person submits the draft with the page's own control, and the label goes",
       %{conn: conn} do
    w = studio_world!()
    post = agent_draft!(w, "Written by the agent")
    view = open(conn, w.approver, w.profile)

    view
    |> Phoenix.LiveViewTest.element("[data-role='studio-post-open'][data-post-id='#{post.id}']")
    |> render_click()

    assert has_element?(view, "[data-role='studio-submit']", "Submit for approval")
    view |> Phoenix.LiveViewTest.element("[data-role='studio-submit']") |> render_click()
    assert Social.get_post(w.org_id, post.id).status == "needs_approval"
    refute has_element?(view, "[data-role='studio-agent-drafted']")
    refute has_element?(view, "[data-role='studio-detail-agent-drafted']")
  end

  describe "the review panel plays a draft's video" do
    test "an agent draft with an MP4 renders the video from its own file", %{conn: conn} do
      w = studio_world!()
      mp4 = stored_file!(w.project, "mp4 #{System.unique_integer()}", "clip.mp4", "video/mp4")
      post = agent_draft!(w, "Agent clip", [mp4.id])
      assert is_nil(Social.get_post(w.org_id, post.id).clip_render_id)

      view = w |> then(&open(conn, &1.approver, &1.profile)) |> open_detail(post)

      assert has_element?(view, "#{@video}[src='/files/blob/#{mp4.id}']")
      assert has_element?(view, "#{@video}[controls]")
    end

    test "a viewer who sees the post but is denied files.read gets a line, not a player",
         %{conn: conn} do
      w = studio_world!()
      mp4 = stored_file!(w.project, "mp4 #{System.unique_integer()}", "clip.mp4", "video/mp4")
      post = agent_draft!(w, "Agent clip", [mp4.id])

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "files.read",
          resource: {:project, w.project.id}
        })

      view = w |> then(&open(conn, &1.approver, &1.profile)) |> open_detail(post)

      assert has_element?(view, "[data-role='studio-post-detail']", "Agent clip")
      refute has_element?(view, @video)
      refute render(view) =~ "/files/blob/#{mp4.id}"

      assert has_element?(
               view,
               "[data-role='studio-detail-video-no-access']",
               "Media unavailable"
             )
    end

    test "a text-only draft and a non-video first file render no video", %{conn: conn} do
      w = studio_world!()
      png = stored_file!(w.project, "png #{System.unique_integer()}", "pic.png", "image/png")
      text = agent_draft!(w, "Just words")
      picture = agent_draft!(w, "A picture", [png.id])
      view = open(conn, w.approver, w.profile)

      view |> open_detail(text)
      assert has_element?(view, "[data-role='studio-post-detail']", "Just words")
      refute has_element?(view, @video)
      refute has_element?(view, "[data-role='studio-detail-video-no-access']")

      view |> open_detail(picture)
      assert has_element?(view, "[data-role='studio-post-detail']", "A picture")
      refute has_element?(view, @video)
      refute has_element?(view, "[data-role='studio-detail-video-no-access']")
    end

    test "a post prepared from a clip render still renders its video", %{conn: conn} do
      w = studio_world!()
      clip = w |> pending_clip!() |> make_studio_clip!()
      {:ok, [render | _]} = Social.ClipVersions.recent(w.org_id, w.profile.id, clip.id)

      view = open(conn, w.approver, w.profile)

      view
      |> form("#studio-clip-#{clip.id}", %{render_id: render.id, account_id: w.tiktok.id})
      |> render_submit()

      {:ok, [post]} = Social.Studio.list_posts(w.org_id, w.profile.id)
      assert post.clip_render_id == render.id
      [file_id | _] = post.media_file_ids

      view |> open_detail(post)
      assert has_element?(view, "#{@video}[src='/files/blob/#{file_id}']")
    end
  end
end

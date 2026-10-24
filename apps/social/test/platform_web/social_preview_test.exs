defmodule PlatformWeb.SocialPreviewTest.Harness do
  @moduledoc false
  # Renders one `<.preview>` from the session, so the component can be
  # asserted on with `has_element?/2` inside a live view.
  use Phoenix.LiveView

  def mount(_params, %{"attrs" => attrs}, socket), do: {:ok, assign(socket, :attrs, attrs)}

  def render(assigns) do
    ~H"""
    <PlatformWeb.SocialPreview.preview {@attrs} />
    """
  end
end

defmodule PlatformWeb.SocialPreviewTest do
  @moduledoc """
  The per-platform previews (task 01a16c4f): the fold, the X thread, the
  Instagram plain link, the YouTube title flag, and the phone-width frame.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Social.PlatformLimits
  alias PlatformWeb.SocialPreviewTest.Harness

  @account %{
    handle: "examplecompany",
    name: "Avery Example",
    approval_mode: "approve_first",
    status: "connected"
  }

  @image %{src: "/files/blob/img", content_type: "image/jpeg", alt: "A whiteboard"}
  @video %{src: "/files/blob/vid", content_type: "video/mp4", duration_s: 20, alt: "A demo"}

  defp mount_preview(conn, attrs) do
    attrs = Map.merge(%{account: @account, id: "p"}, attrs)
    {:ok, view, _html} = live_isolated(conn, Harness, session: %{"attrs" => attrs})
    view
  end

  defp short_text(view) do
    view
    |> element("[data-role=fold-short]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role=fold-short] > span")
    |> LazyHTML.text()
  end

  @long String.duplicate("abcd ", 200)

  for platform <- ~w(linkedin instagram youtube tiktok) do
    describe "#{platform} fold" do
      test "the fold truncates at the documented count and offers more", %{conn: conn} do
        platform = unquote(platform)
        fold = PlatformLimits.get(platform).fold

        view = mount_preview(conn, %{platform: platform, body: @long, media: [@video]})

        assert has_element?(view, "[data-preview-frame=#{platform}]")

        assert has_element?(
                 view,
                 "[data-role=fold-more]",
                 PlatformLimits.get(platform).fold_label
               )

        assert has_element?(view, "[data-role=fold-full].hidden")

        visible = short_text(view)
        assert String.length(visible) <= fold
        assert String.length(visible) >= fold - 20

        view =
          mount_preview(conn, %{
            platform: platform,
            body: String.duplicate("a", fold),
            media: [@video]
          })

        refute has_element?(view, "[data-role=fold-more]")
      end
    end
  end

  describe "x thread" do
    test "a 600-character body renders 3 numbered posts", %{conn: conn} do
      body = (1..100 |> Enum.map_join(" ", fn _ -> "words" end)) <> "."
      view = mount_preview(conn, %{platform: "x", body: body})

      assert has_element?(view, "[data-role=x-post]", "1/3")
      assert has_element?(view, "[data-role=x-post][data-index='2']", "2/3")
      assert has_element?(view, "[data-role=x-post][data-index='3']", "3/3")
      refute has_element?(view, "[data-role=x-post][data-index='4']")
      assert has_element?(view, "[data-flag=thread_needed]", "X thread needs 3 posts")
      assert has_element?(view, "[data-role=x-post-count]", "Post 1 of 3")
    end

    test "a short post is one post with no number", %{conn: conn} do
      view = mount_preview(conn, %{platform: "x", body: "Hello there"})
      assert has_element?(view, "[data-role=x-post]", "Hello there")
      refute has_element?(view, "[data-role=x-post][data-index='2']")
      refute has_element?(view, "[data-role=x-post]", "1/1")
    end
  end

  describe "instagram links and frame" do
    test "shows a link as plain text, not a link, and flags it", %{conn: conn} do
      view =
        mount_preview(conn, %{
          platform: "instagram",
          body: "Read it at https://example.com/post",
          link_url: "https://example.com/beta",
          media: [@image]
        })

      assert has_element?(view, "[data-role=plain-link]", "https://example.com/post")
      assert has_element?(view, "[data-role=plain-link]", "https://example.com/beta")
      refute has_element?(view, "a[href='https://example.com/post']")
      refute has_element?(view, "a[href='https://example.com/beta']")
      assert has_element?(view, "[data-flag=link_not_clickable]")
    end

    test "an image is a 4:5 frame, a video a 9:16 frame", %{conn: conn} do
      view = mount_preview(conn, %{platform: "instagram", body: "hi", media: [@image]})
      assert has_element?(view, "[data-role=media-frame][data-ratio='4:5'].aspect-\\[4\\/5\\]")

      view = mount_preview(conn, %{platform: "instagram", body: "hi", media: [@video]})
      assert has_element?(view, "[data-role=media-frame][data-ratio='9:16'].aspect-\\[9\\/16\\]")
    end

    test "LinkedIn keeps the same link clickable", %{conn: conn} do
      view =
        mount_preview(conn, %{platform: "linkedin", body: "Read it at https://example.com/post"})

      assert has_element?(view, "a[href='https://example.com/post']")
    end
  end

  describe "youtube title" do
    test "a video without a title flags", %{conn: conn} do
      view = mount_preview(conn, %{platform: "youtube", body: "desc", media: [@video]})
      assert has_element?(view, "[data-flag=missing_title]", "YouTube needs a title")

      view =
        mount_preview(conn, %{
          platform: "youtube",
          body: "desc",
          media: [@video],
          title: "A title"
        })

      refute has_element?(view, "[data-flag=missing_title]")
      assert has_element?(view, "[data-role=youtube-title]", "A title")
    end
  end

  describe "every preview" do
    test "shows the approval-mode badge and the owner line", %{conn: conn} do
      for platform <- PlatformLimits.platforms() do
        view =
          mount_preview(conn, %{
            platform: platform,
            account: %{@account | approval_mode: "draft_only"} |> Map.put(:owner_name, "Avery"),
            body: "hi",
            media: [@video]
          })

        assert has_element?(view, "[data-role=approval-mode]", "Draft only")
        assert has_element?(view, "[data-role=owner-line]", "Posts as Avery")
        assert has_element?(view, "[data-flag=posts_by_hand]", "You post this yourself")
      end

      view = mount_preview(conn, %{platform: "x", body: "hi", viewer_owner?: true})
      assert has_element?(view, "[data-role=approval-mode]", "Approve first")
      assert has_element?(view, "[data-role=owner-line]", "Posts as you")
    end

    test "a disconnected account flags", %{conn: conn} do
      view =
        mount_preview(conn, %{
          platform: "linkedin",
          body: "hi",
          account: %{@account | status: "reauth_needed"}
        })

      assert has_element?(view, "[data-flag=account_disconnected]")
    end

    # 375px: every frame is fluid (w-full) under a max width, and every
    # media element is capped at its container, so nothing can be wider
    # than a phone viewport. The pixel check is the PR's 390px screenshot.
    test "frames are full-width and capped, media never wider than the frame", %{conn: conn} do
      for platform <- PlatformLimits.platforms() do
        view = mount_preview(conn, %{platform: platform, body: @long, media: [@image, @video]})

        assert has_element?(view, "[data-role=social-preview].w-full.min-w-0")

        assert has_element?(view, "[data-preview-frame=#{platform}].w-full.overflow-hidden") or
                 has_element?(
                   view,
                   "[data-preview-frame=#{platform}].w-full [data-role=media-frame].overflow-hidden"
                 )

        html = render(view)
        doc = LazyHTML.from_fragment(html)

        for node <- doc |> LazyHTML.query("img, video") |> Enum.to_list() do
          classes = node |> LazyHTML.attribute("class") |> List.first() |> String.split()
          assert "max-w-full" in classes
        end

        refute html =~ ~r/class="[^"]*(?<![\w-])(w-\[\d{3,}px\]|min-w-\[\d{3,}px\])/
      end
    end
  end
end

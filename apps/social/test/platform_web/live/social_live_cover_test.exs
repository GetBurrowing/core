defmodule PlatformWeb.SocialLiveCoverTest do
  @moduledoc """
  The queue card's Cover control and picker (task 01a165ec stage 4, design
  canvas 01a165ec-76e8): the three labels, the chosen cover as the card's
  <video> thumbnail (poster for an upload, `#t=` fragment for a frame),
  the upload and frame paths through `Social.set_cover/4`, the refusals in
  the cover rule's words, and the copy rule (no "thumbnail"/"reelCover").
  `async: false`: the approval card's canvas server is another process on
  the shared sandbox connection, and the Fake's call log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Post, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()

    {:ok, profile} =
      Social.update_profile(ctx.org_id, ctx.profile, %{project_id: project!(ctx.org_id).id})

    {:ok, ig} =
      Social.create_account(ctx.org_id, profile, %{platform: "instagram", handle: "@htc_reels"})

    video = media_file!(ctx.org_id, "video/mp4")
    Map.merge(ctx, %{profile: profile, ig: ig, video: video})
  end

  defp video_post!(ctx, attrs \\ %{}) do
    pending_post!(
      ctx,
      ctx.ig,
      Map.merge(
        %{
          body: "Clip 03: how to reset a router",
          media_file_ids: [ctx.video.id],
          media_meta: %{ctx.video.id => %{"duration_s" => 42.5}}
        },
        attrs
      )
    )
  end

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    find_live_child(view, "ext-page-social")
  end

  defp row(post), do: "#queue-#{post.id}"
  defp in_row(post, sel), do: "#{row(post)} #{sel}"

  defp open_picker(child, post) do
    child |> element(in_row(post, "[data-role='social-card-cover']")) |> render_click()
    assert has_element?(child, "[data-role='social-cover-picker']")
    child
  end

  # A PNG header (signature + IHDR) of the given size: enough bytes for the
  # store and for `Platform.Social.CoverImage.dimensions/1`.
  defp png(w, h) do
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", w::32, h::32, 8, 6, 0, 0, 0, 0::32>>
  end

  defp upload_png(child, name, bytes) do
    child |> element("[data-role='social-cover-tab'][data-tab='upload']") |> render_click()

    input =
      file_input(child, "#social-cover-upload", :cover, [
        %{name: name, content: bytes, type: "image/png"}
      ])

    render_upload(input, name)
  end

  describe "the card's Cover control" do
    test "reads first frame, frame m:ss, or uploaded image", %{conn: conn} = ctx do
      {plain, _} = video_post!(ctx)
      {framed, _} = video_post!(ctx, %{cover_offset_ms: 7_400})
      png = media_file!(ctx.org_id, "image/png")
      {uploaded, _} = video_post!(ctx, %{cover_file_id: png.id})

      child = open(conn, ctx.h1)

      assert has_element?(
               child,
               in_row(plain, "button[data-role='social-card-cover']"),
               "Cover: first frame"
             )

      assert has_element?(
               child,
               in_row(framed, "button[data-role='social-card-cover']"),
               "Cover: frame 0:07"
             )

      assert has_element?(
               child,
               in_row(uploaded, "button[data-role='social-card-cover']"),
               "Cover: uploaded image"
             )

      # The card thumbnail is the chosen cover.
      assert has_element?(child, in_row(uploaded, "video[poster='/files/blob/#{png.id}']"))
      assert has_element?(child, in_row(framed, "video[src$='#t=7.4']"))
      refute has_element?(child, in_row(plain, "video[poster]"))
      assert has_element?(child, in_row(plain, "video[src='/files/blob/#{ctx.video.id}']"))
    end

    test "a non-video post has no Cover control", %{conn: conn} = ctx do
      {text_post, _} = pending_post!(ctx, ctx.a, %{body: "text only"})
      png = media_file!(ctx.org_id, "image/png")
      {image_post, _} = pending_post!(ctx, ctx.ig, %{body: "image", media_file_ids: [png.id]})

      child = open(conn, ctx.h1)

      assert has_element?(child, row(text_post))
      refute has_element?(child, in_row(text_post, "[data-role='social-card-cover']"))
      refute has_element?(child, in_row(image_post, "[data-role='social-card-cover']"))
      refute has_element?(child, in_row(image_post, "[data-role='social-card-cover-label']"))
    end
  end

  describe "the picker" do
    test "opens as a dialog with the frame scrubber, platform line and one primary",
         %{conn: conn} = ctx do
      {post, _} = video_post!(ctx, %{cover_offset_ms: 7_400})
      child = conn |> open(ctx.h1) |> open_picker(post)

      assert has_element?(
               child,
               "[data-role='social-cover-tab'][aria-selected='true']",
               "Pick a frame"
             )

      assert has_element?(child, "[data-role='social-cover-tab']", "Upload image")

      scrubber = "#social-cover-scrubber-#{post.id}"
      assert has_element?(child, "#{scrubber}[phx-hook='CoverPicker'][phx-update='ignore']")
      assert has_element?(child, "#{scrubber}[data-src='/files/blob/#{ctx.video.id}']")

      assert has_element?(
               child,
               "#{scrubber} [role='slider'][aria-valuetext='0:07.40 / 0:42']"
             )

      assert has_element?(child, "[data-role='social-cover-timecode']", "0:07.40 / 0:42")
      assert has_element?(child, "[data-role='social-cover-crop-guide']")

      assert has_element?(
               child,
               "[data-role='social-cover-platform']",
               "Instagram uses this cover"
             )

      assert has_element?(child, "[data-role='social-cover-reset']", "Reset to first frame")

      html = render(child)
      doc = LazyHTML.from_fragment(html)
      primaries = LazyHTML.query(doc, "[data-role='social-cover-picker'] .btn-primary")
      assert Enum.count(primaries) == 1
      assert LazyHTML.text(primaries) =~ "Use this cover"
    end

    test "uploading a PNG and using it sets cover_file_id, the label and the poster",
         %{conn: conn} = ctx do
      {post, _} = video_post!(ctx, %{cover_offset_ms: 3_000})
      child = conn |> open(ctx.h1) |> open_picker(post)

      upload_png(child, "cover.png", png(1080, 1920))
      assert has_element?(child, "[data-role='social-cover-file']", "cover.png")
      refute has_element?(child, "[data-role='social-cover-crop-note']")

      child |> form("#social-cover-upload") |> render_submit()

      stored = Repo.get!(Post, post.id)
      assert is_binary(stored.cover_file_id)
      assert stored.cover_offset_ms == nil
      assert %{content_type: "image/png"} = Platform.Files.get_file(stored.cover_file_id)

      refute has_element?(child, "[data-role='social-cover-picker']")

      assert has_element?(
               child,
               in_row(post, "[data-role='social-card-cover']"),
               "Cover: uploaded image"
             )

      assert has_element?(
               child,
               in_row(post, "video[poster='/files/blob/#{stored.cover_file_id}']")
             )
    end

    test "the same image uploaded twice reuses the stored file", %{conn: conn} = ctx do
      {post, _} = video_post!(ctx)
      bytes = png(1080, 1920)

      child = conn |> open(ctx.h1) |> open_picker(post)
      upload_png(child, "cover.png", bytes)
      child |> form("#social-cover-upload") |> render_submit()
      first = Repo.get!(Post, post.id).cover_file_id

      open_picker(child, post)
      upload_png(child, "again.png", bytes)
      refute has_element?(child, "[data-role='social-cover-error']")
      child |> form("#social-cover-upload") |> render_submit()

      assert Repo.get!(Post, post.id).cover_file_id == first
    end

    test "a non-9:16 image says Instagram will crop it, without blocking", %{conn: conn} = ctx do
      {post, _} = video_post!(ctx)
      child = conn |> open(ctx.h1) |> open_picker(post)

      upload_png(child, "square.png", png(1000, 1000))

      assert has_element?(
               child,
               "[data-role='social-cover-crop-note']",
               "Instagram will crop this to 9:16"
             )

      refute has_element?(child, "[data-role='social-cover-use'][disabled]")
    end

    test "cover_frame at 7400 ms sets the frame, clears the upload and fragments the src",
         %{conn: conn} = ctx do
      png = media_file!(ctx.org_id, "image/png")
      {post, _} = video_post!(ctx, %{cover_file_id: png.id})
      child = conn |> open(ctx.h1) |> open_picker(post)

      render_hook(child, "cover_frame", %{
        "post_id" => post.id,
        "offset_ms" => 7_400,
        "duration_ms" => 42_500
      })

      stored = Repo.get!(Post, post.id)
      assert stored.cover_offset_ms == 7_400
      assert stored.cover_file_id == nil

      assert has_element?(
               child,
               in_row(post, "[data-role='social-card-cover']"),
               "Cover: frame 0:07"
             )

      assert has_element?(child, in_row(post, "video[src$='#t=7.4']"))
      refute has_element?(child, in_row(post, "video[poster]"))
    end

    test "Reset to first frame clears the cover", %{conn: conn} = ctx do
      {post, _} = video_post!(ctx, %{cover_offset_ms: 7_400})
      child = conn |> open(ctx.h1) |> open_picker(post)

      child |> element("[data-role='social-cover-reset']") |> render_click()

      stored = Repo.get!(Post, post.id)
      assert {stored.cover_offset_ms, stored.cover_file_id} == {nil, nil}

      assert has_element?(
               child,
               in_row(post, "[data-role='social-card-cover']"),
               "Cover: first frame"
             )
    end

    test "a PDF upload shows the cover rule's error text", %{conn: conn} = ctx do
      {post, _} = video_post!(ctx)
      child = conn |> open(ctx.h1) |> open_picker(post)
      child |> element("[data-role='social-cover-tab'][data-tab='upload']") |> render_click()

      input =
        file_input(child, "#social-cover-upload", :cover, [
          %{name: "brief.pdf", content: "%PDF-1.4", type: "application/pdf"}
        ])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "brief.pdf")

      assert has_element?(
               child,
               "[data-role='social-cover-error']",
               "cover must be a JPG or PNG image"
             )

      assert Repo.get!(Post, post.id).cover_file_id == nil
    end

    test "an offset past the end shows the error and keeps the picker open",
         %{conn: conn} = ctx do
      {post, _} = video_post!(ctx)
      child = conn |> open(ctx.h1) |> open_picker(post)

      render_hook(child, "cover_frame", %{"post_id" => post.id, "offset_ms" => 99_000})

      assert has_element?(
               child,
               "[data-role='social-cover-error']",
               "cover frame is past the end of the video (0:42)"
             )

      assert has_element?(child, "[data-role='social-cover-picker']")
      assert Repo.get!(Post, post.id).cover_offset_ms == nil
    end

    test "names the platform: YouTube needs an upload, others pick their own",
         %{conn: conn} = ctx do
      {:ok, yt} =
        Social.create_account(ctx.org_id, ctx.profile, %{platform: "youtube", handle: "HTC"})

      {:ok, tt} =
        Social.create_account(ctx.org_id, ctx.profile, %{platform: "tiktok", handle: "@htc"})

      meta = %{ctx.video.id => %{"duration_s" => 42.5}}
      {yt_post, _} = pending_post!(ctx, yt, %{media_file_ids: [ctx.video.id], media_meta: meta})
      {tt_post, _} = pending_post!(ctx, tt, %{media_file_ids: [ctx.video.id], media_meta: meta})

      child = conn |> open(ctx.h1) |> open_picker(yt_post)

      assert has_element?(
               child,
               "[data-role='social-cover-platform']",
               "YouTube uses only an uploaded cover"
             )

      child |> element("[data-role='social-cover-tab'][data-tab='upload']") |> render_click()
      assert has_element?(child, "[data-role='social-cover-platform']", "YouTube uses this cover")

      child
      |> element("[data-role='social-cover-picker'] .modal-box button[aria-label='Close']")
      |> render_click()

      open_picker(child, tt_post)

      assert has_element?(
               child,
               "[data-role='social-cover-platform']",
               "TikTok picks its own cover"
             )
    end
  end

  test "no UI text says thumbnail or reelCover, on the card or either tab", %{conn: conn} = ctx do
    {post, _} = video_post!(ctx)
    child = open(conn, ctx.h1)
    pages = [render(child)]

    open_picker(child, post)
    pages = [render(child) | pages]
    child |> element("[data-role='social-cover-tab'][data-tab='upload']") |> render_click()
    pages = [render(child) | pages]

    for html <- pages do
      text = html |> LazyHTML.from_fragment() |> LazyHTML.text()
      refute text =~ ~r/thumbnail|reelcover/i

      labels =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[aria-label], [aria-valuetext], [alt], [title]")
        |> Enum.flat_map(fn node ->
          for attr <- ~w(aria-label aria-valuetext alt title),
              value <- LazyHTML.attribute(node, attr),
              do: value
        end)

      refute Enum.any?(labels, &(&1 =~ ~r/thumbnail|reelcover/i))
    end
  end
end

defmodule Platform.Social.CoverTest do
  @moduledoc """
  A video post's cover (task 01a165ec stage 2): the one cover rule
  (`Platform.Social.Cover`) through the human path (`Social.set_cover/4`)
  and the general `Post.changeset/2` path (`Social.update_post/3`), plus
  the approval fingerprint. `async: false`: the approval card's canvas
  server is another process on the shared sandbox connection, and the Fake
  publisher's call log is global.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Social
  alias Platform.Social.{Approvals, Post, RateLimit}
  alias Platform.Social.Publisher.Fake

  @both "choose either an uploaded cover or a frame, not both"
  @not_video "a cover applies only to a video post"
  @not_image "cover must be a JPG or PNG image"
  @not_in_org "cover must exist in the profile's org"
  @unknown "the video's duration is unknown, so a frame cannot be checked"

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()
    video = media_file!(ctx.org_id, "video/mp4")
    png = media_file!(ctx.org_id, "image/png")
    jpg = media_file!(ctx.org_id, "image/jpeg")
    Map.merge(ctx, %{video: video, png: png, jpg: jpg})
  end

  defp video_post!(ctx, attrs \\ %{}) do
    {:ok, post} =
      Social.create_post(
        ctx.org_id,
        ctx.a,
        Map.merge(
          %{
            body: "clip",
            status: "draft",
            media_file_ids: [ctx.video.id],
            media_meta: %{ctx.video.id => %{"duration_s" => 42.5}}
          },
          attrs
        )
      )

    post
  end

  defp set(ctx, post, attrs, user \\ nil),
    do: Social.set_cover(ctx.org_id, (user || ctx.h1).id, post.id, attrs)

  defp refused(result) do
    assert {:error, %Ecto.Changeset{} = changeset} = result
    errors_on(changeset)
  end

  describe "refusals, each with its exact message" do
    test "a non-image file (application/pdf)", ctx do
      post = video_post!(ctx)
      pdf = media_file!(ctx.org_id, "application/pdf")

      assert %{cover_file_id: [@not_image]} = refused(set(ctx, post, %{cover_file_id: pdf.id}))
      assert Repo.get!(Post, post.id).cover_file_id == nil
    end

    test "an image from ANOTHER org", ctx do
      post = video_post!(ctx)
      foreign = media_file!(org_id!(), "image/png")

      assert %{cover_file_id: [@not_in_org]} =
               refused(set(ctx, post, %{cover_file_id: foreign.id}))
    end

    test "a missing file id", ctx do
      post = video_post!(ctx)

      assert %{cover_file_id: [@not_in_org]} =
               refused(set(ctx, post, %{cover_file_id: Ecto.UUID.generate()}))
    end

    test "an offset past the video's duration names the duration", ctx do
      post = video_post!(ctx)

      assert %{cover_offset_ms: ["cover frame is past the end of the video (0:42)"]} =
               refused(set(ctx, post, %{cover_offset_ms: 42_501}))

      # The last frame itself is fine.
      assert {:ok, %Post{cover_offset_ms: 42_500}} = set(ctx, post, %{cover_offset_ms: 42_500})
    end

    test "a negative offset", ctx do
      post = video_post!(ctx)

      assert %{cover_offset_ms: ["must be greater than or equal to 0"]} =
               refused(set(ctx, post, %{cover_offset_ms: -1}))
    end

    test "an unknown duration", ctx do
      post = video_post!(ctx, %{media_meta: %{}})

      assert %{cover_offset_ms: [@unknown]} = refused(set(ctx, post, %{cover_offset_ms: 1_000}))
    end

    test "a cover on an image-only post", ctx do
      {:ok, post} =
        Social.create_post(ctx.org_id, ctx.a, %{
          body: "pic",
          status: "draft",
          media_file_ids: [ctx.png.id]
        })

      assert %{cover_file_id: [@not_video]} =
               refused(set(ctx, post, %{cover_file_id: ctx.jpg.id}))

      assert %{cover_offset_ms: [@not_video]} = refused(set(ctx, post, %{cover_offset_ms: 0}))
    end

    test "both fields in one call", ctx do
      post = video_post!(ctx)

      assert %{cover_file_id: [@both]} =
               refused(set(ctx, post, %{cover_file_id: ctx.png.id, cover_offset_ms: 1_000}))

      assert %Post{cover_file_id: nil, cover_offset_ms: nil} = Repo.get!(Post, post.id)
    end

    test "a post past needs_approval is post_locked", ctx do
      {post, card} = pending_post!(ctx, ctx.a, video_attrs(ctx))
      {:ok, _} = Approvals.decide_approve(card.canvas_id, ctx.h1)

      assert {:error, :post_locked} = set(ctx, post, %{cover_offset_ms: 1_000})
    end

    test "only a user who may edit the card may set the cover", ctx do
      post = video_post!(ctx)

      assert {:error, :not_an_approver} = set(ctx, post, %{cover_offset_ms: 1_000}, ctx.n)
      assert {:error, _} = Social.set_cover(ctx.org_id, ctx.g.id, post.id, %{cover_offset_ms: 1})
      assert Repo.get!(Post, post.id).cover_offset_ms == nil
    end

    test "Post.changeset (update_post) refuses through the same rule", ctx do
      post = video_post!(ctx)
      pdf = media_file!(ctx.org_id, "application/pdf")

      assert %{cover_file_id: [@not_image]} =
               refused(Social.update_post(ctx.org_id, post, %{cover_file_id: pdf.id}))

      assert %{cover_file_id: [@both]} =
               refused(
                 Social.update_post(ctx.org_id, post, %{
                   "cover_file_id" => ctx.png.id,
                   "cover_offset_ms" => 5
                 })
               )

      assert {:ok, %Post{cover_file_id: id}} =
               Social.update_post(ctx.org_id, post, %{cover_file_id: ctx.png.id})

      assert id == ctx.png.id
    end
  end

  describe "one cover at a time" do
    test "upload after frame keeps only cover_file_id", ctx do
      post = video_post!(ctx)
      {:ok, _} = set(ctx, post, %{cover_offset_ms: 3_000})
      {:ok, post} = set(ctx, post, %{cover_file_id: ctx.jpg.id})

      assert {post.cover_file_id, post.cover_offset_ms} == {ctx.jpg.id, nil}
      assert %Post{cover_file_id: id, cover_offset_ms: nil} = Repo.get!(Post, post.id)
      assert id == ctx.jpg.id
    end

    test "frame after upload keeps only cover_offset_ms", ctx do
      post = video_post!(ctx)
      {:ok, _} = set(ctx, post, %{cover_file_id: ctx.png.id})
      {:ok, _} = set(ctx, post, %{cover_offset_ms: 7_000})

      assert %Post{cover_file_id: nil, cover_offset_ms: 7_000} = Repo.get!(Post, post.id)
    end

    test "clear nils both", ctx do
      post = video_post!(ctx)
      {:ok, _} = set(ctx, post, %{cover_file_id: ctx.png.id})
      {:ok, _} = set(ctx, post, :clear)
      assert %Post{cover_file_id: nil, cover_offset_ms: nil} = Repo.get!(Post, post.id)

      {:ok, _} = set(ctx, post, %{cover_offset_ms: 1})
      {:ok, _} = set(ctx, post, %{clear: true})
      assert %Post{cover_file_id: nil, cover_offset_ms: nil} = Repo.get!(Post, post.id)
    end
  end

  describe "duration backfill from the browser" do
    test "fills an unknown duration, then checks the frame against it", ctx do
      post = video_post!(ctx, %{media_meta: %{}})

      assert {:ok, %Post{cover_offset_ms: 10_000, media_meta: meta}} =
               set(ctx, post, %{cover_offset_ms: 10_000, duration_ms: 30_000})

      assert meta[ctx.video.id]["duration_s"] == 30.0

      assert %{cover_offset_ms: ["cover frame is past the end of the video (0:30)"]} =
               refused(set(ctx, post, %{cover_offset_ms: 31_000, duration_ms: 90_000}))
    end

    test "never overwrites a known duration", ctx do
      post = video_post!(ctx)

      assert %{cover_offset_ms: ["cover frame is past the end of the video (0:42)"]} =
               refused(set(ctx, post, %{cover_offset_ms: 60_000, duration_ms: 120_000}))

      assert Repo.get!(Post, post.id).media_meta[ctx.video.id]["duration_s"] == 42.5
    end
  end

  describe "the approval fingerprint" do
    test "changes when the cover changes", ctx do
      post = video_post!(ctx)
      none = Approvals.fingerprint(post)

      {:ok, framed} = set(ctx, post, %{cover_offset_ms: 1_000})
      {:ok, reframed} = set(ctx, post, %{cover_offset_ms: 2_000})
      {:ok, uploaded} = set(ctx, post, %{cover_file_id: ctx.png.id})

      prints = Enum.map([post, framed, reframed, uploaded], &Approvals.fingerprint/1)
      assert prints |> Enum.uniq() |> length() == 4
      assert hd(prints) == none
    end

    test "approving a card whose cover changed under it is post_changed", ctx do
      {post, card} = pending_post!(ctx, ctx.a, video_attrs(ctx))
      shown = Approvals.fingerprint(Repo.get!(Post, post.id))

      {:ok, _} = set(ctx, post, %{cover_offset_ms: 4_000})

      assert {:error, :post_changed} = Approvals.decide_approve(card.canvas_id, ctx.h1, shown)
      assert Repo.get!(Post, post.id).status == "needs_approval"
    end
  end

  defp video_attrs(ctx),
    do: %{
      media_file_ids: [ctx.video.id],
      media_meta: %{ctx.video.id => %{"duration_s" => 42.5}}
    }
end

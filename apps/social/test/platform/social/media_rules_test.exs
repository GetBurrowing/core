defmodule Platform.Social.MediaRulesTest do
  @moduledoc "Each platform's media rule, pure. Messages name the platform, the limit and the value."
  use ExUnit.Case, async: true

  alias Platform.Social.MediaRules

  defp video(duration_s, opts \\ []),
    do: %{
      content_type: Keyword.get(opts, :type, "video/mp4"),
      byte_size: Keyword.get(opts, :bytes, 1_000),
      duration_s: duration_s
    }

  defp image(type \\ "image/png", bytes \\ 1_000),
    do: %{content_type: type, byte_size: bytes, duration_s: nil}

  defp gif, do: image("image/gif")

  describe "tiktok" do
    test "one compliant video or 1..35 images pass" do
      assert :ok = MediaRules.check("tiktok", nil, [video(30)])
      assert :ok = MediaRules.check("tiktok", nil, [video(3)])
      assert :ok = MediaRules.check("tiktok", nil, [video(600, type: "video/quicktime")])
      assert :ok = MediaRules.check("tiktok", nil, [image()])
      assert :ok = MediaRules.check("tiktok", nil, for(_ <- 1..35, do: image("image/jpeg")))
    end

    test "media is required" do
      assert {:error, ["TikTok needs media: one video or 1 to 35 images"]} =
               MediaRules.check("tiktok", nil, [])
    end

    test "duration bounds and unknown duration" do
      assert {:error, ["TikTok videos must be at least 3 seconds; this one is 1.5 seconds"]} =
               MediaRules.check("tiktok", nil, [video(1.5)])

      assert {:error, ["TikTok videos must be at most 600 seconds; this one is 601 seconds"]} =
               MediaRules.check("tiktok", nil, [video(601)])

      assert {:error, ["TikTok needs the video's duration; it is unknown"]} =
               MediaRules.check("tiktok", nil, [video(nil)])
    end

    test "size, type, count and mixing" do
      assert {:error, ["TikTok videos must be at most 4 GB" <> _]} =
               MediaRules.check("tiktok", nil, [video(30, bytes: 5 * 1024 * 1024 * 1024)])

      assert {:error, ["TikTok videos must be MP4, MOV or WebM; got video/x-msvideo"]} =
               MediaRules.check("tiktok", nil, [video(30, type: "video/x-msvideo")])

      assert {:error, ["TikTok allows one video per post; this post has 2"]} =
               MediaRules.check("tiktok", nil, [video(30), video(30)])

      assert {:error, ["TikTok cannot mix a video and images in one post"]} =
               MediaRules.check("tiktok", nil, [video(30), image()])

      assert {:error, ["TikTok allows at most 35 images per post; this post has 36"]} =
               MediaRules.check("tiktok", nil, for(_ <- 1..36, do: image()))

      assert {:error, ["TikTok images must be at most 20 MB each" <> _]} =
               MediaRules.check("tiktok", nil, [image("image/png", 21 * 1024 * 1024)])

      assert {:error, ["TikTok images must be JPEG, PNG or WebP; got image/gif"]} =
               MediaRules.check("tiktok", nil, [gif()])
    end
  end

  describe "instagram" do
    test "a Reel needs a Business or Creator account" do
      for type <- ["personal", nil] do
        assert {:error, ["Instagram Reels need a Business or Creator account"]} =
                 MediaRules.check("instagram", %{platform_account_type: type}, [video(30)])
      end

      for type <- ["business", "creator"],
          do:
            assert(
              :ok = MediaRules.check("instagram", %{platform_account_type: type}, [video(30)])
            )

      assert :ok = MediaRules.check("instagram", %{platform_account_type: "personal"}, [image()])
    end
  end

  describe "x" do
    test "at most 4 images, or 1 video, or 1 GIF, never mixed" do
      assert :ok = MediaRules.check("x", nil, for(_ <- 1..4, do: image()))
      assert :ok = MediaRules.check("x", nil, [video(30)])
      assert :ok = MediaRules.check("x", nil, [gif()])
      assert :ok = MediaRules.check("x", nil, [])

      assert {:error, ["X allows at most 4 images per post; this post has 5"]} =
               MediaRules.check("x", nil, for(_ <- 1..5, do: image()))

      assert {:error, ["X allows one video per post; this post has 2"]} =
               MediaRules.check("x", nil, [video(30), video(30)])

      assert {:error, ["X allows one GIF per post; this post has 2"]} =
               MediaRules.check("x", nil, [gif(), gif()])

      assert {:error, ["X cannot mix videos, GIFs and images in one post"]} =
               MediaRules.check("x", nil, [video(30), image()])

      assert {:error, ["X cannot mix videos, GIFs and images in one post"]} =
               MediaRules.check("x", nil, [gif(), image()])
    end
  end

  describe "youtube and linkedin" do
    test "youtube needs exactly one video" do
      assert :ok = MediaRules.check("youtube", nil, [video(30)])

      assert {:error, ["YouTube needs exactly one video" <> _]} =
               MediaRules.check("youtube", nil, [])

      assert {:error, ["YouTube needs exactly one video" <> _]} =
               MediaRules.check("youtube", nil, [video(30), video(30)])

      assert {:error, ["YouTube needs exactly one video" <> _]} =
               MediaRules.check("youtube", nil, [image()])
    end

    test "linkedin passes" do
      assert :ok = MediaRules.check("linkedin", nil, [video(nil), image(), gif()])
    end
  end

  # Social 5/7: the clip pipeline checks these at render time.
  describe "x video length and size (Social 5/7)" do
    test "at most 140 seconds, boundary included" do
      assert :ok = MediaRules.check("x", nil, [video(140)])
      assert :ok = MediaRules.check("x", nil, [video(140.0)])

      assert {:error, ["X videos must be at most 140 seconds; this one is 150.0 seconds"]} =
               MediaRules.check("x", nil, [video(150.0)])
    end

    test "at most 512 MB" do
      assert :ok = MediaRules.check("x", nil, [video(30, bytes: 512 * 1024 * 1024)])

      assert {:error, ["X videos must be at most 512 MB; this one is 512.0 MB"]} =
               MediaRules.check("x", nil, [video(30, bytes: 512 * 1024 * 1024 + 1)])
    end

    test "both broken gives both messages; an unknown duration is not judged" do
      assert {:error, [_, _]} = MediaRules.check("x", nil, [video(200, bytes: 600 * 1024 * 1024)])
      assert :ok = MediaRules.check("x", nil, [video(nil)])
    end
  end

  describe "instagram reel length and size (Social 5/7)" do
    @business %{platform_account_type: "business"}

    test "3 to 900 seconds, boundaries included" do
      assert :ok = MediaRules.check("instagram", @business, [video(3)])
      assert :ok = MediaRules.check("instagram", @business, [video(900)])

      assert {:error, ["Instagram Reels must be at least 3 seconds; this one is 2.5 seconds"]} =
               MediaRules.check("instagram", @business, [video(2.5)])

      assert {:error, ["Instagram Reels must be at most 900 seconds; this one is 901 seconds"]} =
               MediaRules.check("instagram", @business, [video(901)])
    end

    test "at most 1 GB, and the account rule still applies alongside" do
      assert {:error, [msg]} =
               MediaRules.check("instagram", @business, [video(60, bytes: 1024 * 1024 * 1024 + 1)])

      assert msg =~ "Instagram Reels must be at most 1 GB"

      assert {:error, ["Instagram Reels need a Business or Creator account", _]} =
               MediaRules.check("instagram", nil, [video(901)])
    end
  end
end

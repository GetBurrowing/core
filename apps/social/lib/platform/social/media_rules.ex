defmodule Platform.Social.MediaRules do
  @moduledoc """
  Each platform's media rules, checked BEFORE any vendor call so a post that
  would fail at the platform is refused early with a readable reason (task
  01a140a9, Social 2/7). Pure: no DB, no process.

  `media` is a list of maps built by `Platform.Social.Publishing` from
  `Platform.Files.get_file/2` (`content_type`, `byte_size`) and the post's
  `media_meta` (`duration_s`, `width`, `height`; `nil` when unknown).

  Sources and assumptions:

    * TikTok, from https://docs.zernio.com/platforms/tiktok: media is
      required; ONE video (MP4, MOV or WebM, 3 to 600 seconds, at most 4 GB)
      or 1 to 35 images (JPEG, PNG or WebP, at most 20 MB each), never both.
    * Instagram: a video is a Reel and is refused here ONLY when the account
      type is known to be `"personal"`. `nil` (or no account) means the type
      is unknown and the Reel is allowed: the platform decides at publish and
      its error lands on the post row. Zernio does not report an Instagram
      account type (its OpenAPI v1.333.2 SocialAccount schema, fetched
      2026-10-22 from https://docs.zernio.com/api/openapi, carries only
      `tiktokAccountType`), and https://docs.zernio.com/platforms/instagram
      states Instagram requires a Business or Creator account, converting
      the account to professional before consent, so an unknown type is
      almost always a professional one.
      A Reel runs 3 to 900 seconds and is at most 1 GB (Social 5/7, checked
      at clip render time too). ASSUMED platform rule, from
      https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media#reel-specifications
    * X: at most 4 images, or exactly 1 video, or 1 GIF, never mixed.
      ASSUMED platform rule. A video is at most 140 seconds and at most
      512 MB (Social 5/7). ASSUMED platform rule, from
      https://developer.x.com/en/docs/x-api/v1/media/upload-media/uploading-media/media-best-practices
    * YouTube: exactly one video.
    * LinkedIn: no rule checked here.
  """

  @type item :: %{
          optional(:file_id) => String.t(),
          content_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          duration_s: number() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil
        }

  @tiktok_video_types ~w(video/mp4 video/quicktime video/webm)
  @tiktok_image_types ~w(image/jpeg image/png image/webp)
  @tiktok_min_s 3
  @tiktok_max_s 600
  @tiktok_max_video_bytes 4 * 1024 * 1024 * 1024
  @tiktok_max_image_bytes 20 * 1024 * 1024
  @tiktok_max_images 35
  @x_max_images 4
  # Social 5/7 (clip pipeline): video length and size limits.
  @x_max_video_s 140
  @x_max_video_bytes 512 * 1024 * 1024
  @instagram_reel_min_s 3
  @instagram_reel_max_s 900
  @instagram_reel_max_bytes 1024 * 1024 * 1024

  @doc "`:ok`, or `{:error, messages}` naming the platform, the limit and the offending value."
  @spec check(String.t(), map() | nil, [item()]) :: :ok | {:error, [String.t()]}
  def check(platform, account, media) when is_list(media) do
    case rules(platform, account, Enum.map(media, &classify/1)) do
      [] -> :ok
      messages -> {:error, messages}
    end
  end

  # ── Per platform ─────────────────────────────────────────────────────

  defp rules("tiktok", _account, []), do: ["TikTok needs media: one video or 1 to 35 images"]

  defp rules("tiktok", _account, media) do
    {videos, others} = Enum.split_with(media, &(&1.kind == :video))

    cond do
      videos != [] and others != [] ->
        ["TikTok cannot mix a video and images in one post"]

      length(videos) > 1 ->
        ["TikTok allows one video per post; this post has #{length(videos)}"]

      videos != [] ->
        tiktok_video(hd(videos))

      true ->
        tiktok_images(others)
    end
  end

  defp rules("instagram", account, media) do
    videos = Enum.filter(media, &(&1.kind == :video))

    account_rule =
      if videos != [] and account_type(account) == "personal",
        do: ["Instagram Reels need a Business or Creator account"],
        else: []

    account_rule ++ Enum.flat_map(videos, &instagram_reel/1)
  end

  defp rules("x", _account, media) do
    counts = Enum.frequencies_by(media, & &1.kind)
    images = Map.get(counts, :image, 0)
    videos = Map.get(counts, :video, 0)
    gifs = Map.get(counts, :gif, 0)
    others = Map.get(counts, :other, 0)

    cond do
      others > 0 ->
        Enum.map(Enum.filter(media, &(&1.kind == :other)), fn item ->
          "X accepts images, GIFs or a video; got #{type(item)}"
        end)

      Enum.count([images, videos, gifs], &(&1 > 0)) > 1 ->
        ["X cannot mix videos, GIFs and images in one post"]

      videos > 1 ->
        ["X allows one video per post; this post has #{videos}"]

      gifs > 1 ->
        ["X allows one GIF per post; this post has #{gifs}"]

      images > @x_max_images ->
        ["X allows at most #{@x_max_images} images per post; this post has #{images}"]

      videos == 1 ->
        media |> Enum.find(&(&1.kind == :video)) |> x_video()

      true ->
        []
    end
  end

  defp rules("youtube", _account, media) do
    videos = Enum.count(media, &(&1.kind == :video))

    if videos == 1 and length(media) == 1,
      do: [],
      else: [
        "YouTube needs exactly one video; this post has #{videos} video(s) and #{length(media) - videos} other file(s)"
      ]
  end

  defp rules("linkedin", _account, _media), do: []
  defp rules(platform, _account, _media), do: ["#{inspect(platform)} is not a supported platform"]

  # ── TikTok details ───────────────────────────────────────────────────

  defp tiktok_video(video) do
    [
      if(video.content_type not in @tiktok_video_types,
        do: "TikTok videos must be MP4, MOV or WebM; got #{type(video)}"
      ),
      tiktok_duration(video.duration_s),
      if(is_integer(video.byte_size) and video.byte_size > @tiktok_max_video_bytes,
        do: "TikTok videos must be at most 4 GB; this one is #{mb(video.byte_size)}"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp tiktok_duration(nil), do: "TikTok needs the video's duration; it is unknown"

  defp tiktok_duration(s) when s < @tiktok_min_s,
    do: "TikTok videos must be at least #{@tiktok_min_s} seconds; this one is #{seconds(s)}"

  defp tiktok_duration(s) when s > @tiktok_max_s,
    do: "TikTok videos must be at most #{@tiktok_max_s} seconds; this one is #{seconds(s)}"

  defp tiktok_duration(_s), do: nil

  defp tiktok_images(images) when length(images) > @tiktok_max_images,
    do: [
      "TikTok allows at most #{@tiktok_max_images} images per post; this post has #{length(images)}"
    ]

  defp tiktok_images(images) do
    Enum.flat_map(images, fn image ->
      [
        if(image.content_type not in @tiktok_image_types,
          do: "TikTok images must be JPEG, PNG or WebP; got #{type(image)}"
        ),
        if(is_integer(image.byte_size) and image.byte_size > @tiktok_max_image_bytes,
          do: "TikTok images must be at most 20 MB each; one is #{mb(image.byte_size)}"
        )
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  # ── Video length and size (Social 5/7) ───────────────────────────────

  # An unknown duration or size is not judged here: X and Instagram have no
  # "duration required" rule in this module (TikTok's is above).
  defp x_video(video) do
    [
      if(is_number(video.duration_s) and video.duration_s > @x_max_video_s,
        do:
          "X videos must be at most #{@x_max_video_s} seconds; this one is #{seconds(video.duration_s)}"
      ),
      if(is_integer(video.byte_size) and video.byte_size > @x_max_video_bytes,
        do: "X videos must be at most 512 MB; this one is #{mb(video.byte_size)}"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp instagram_reel(video) do
    s = video.duration_s

    [
      if(is_number(s) and s < @instagram_reel_min_s,
        do:
          "Instagram Reels must be at least #{@instagram_reel_min_s} seconds; this one is #{seconds(s)}"
      ),
      if(is_number(s) and s > @instagram_reel_max_s,
        do:
          "Instagram Reels must be at most #{@instagram_reel_max_s} seconds; this one is #{seconds(s)}"
      ),
      if(is_integer(video.byte_size) and video.byte_size > @instagram_reel_max_bytes,
        do: "Instagram Reels must be at most 1 GB; this one is #{mb(video.byte_size)}"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp classify(item) do
    content_type = item |> Map.get(:content_type) |> normalize_type()

    kind =
      cond do
        content_type == "image/gif" -> :gif
        String.starts_with?(content_type || "", "video/") -> :video
        String.starts_with?(content_type || "", "image/") -> :image
        true -> :other
      end

    %{
      kind: kind,
      content_type: content_type,
      byte_size: Map.get(item, :byte_size),
      duration_s: Map.get(item, :duration_s)
    }
  end

  defp normalize_type(nil), do: nil

  defp normalize_type(type),
    do: type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

  defp account_type(%{platform_account_type: type}), do: type
  defp account_type(_), do: nil

  defp type(%{content_type: nil}), do: "an unknown file type"
  defp type(%{content_type: type}), do: type

  defp seconds(s) when is_float(s), do: "#{:erlang.float_to_binary(s, decimals: 1)} seconds"
  defp seconds(s), do: "#{s} seconds"

  defp mb(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end

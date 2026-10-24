defmodule Platform.Social.PlatformOptions do
  @moduledoc """
  The per-platform options a human sets on one version of an idea
  (Social authoring 7/11, task 01a16c50-ea67), stored on
  `social_posts.platform_options` and sent by the Zernio adapter.

  ONLY options Zernio's OpenAPI (https://zernio.com/openapi.json, read at
  v1.350.1) accepts for the platform are offered; anything else is not
  shown and not stored. Field names as Zernio spells them:

    * `first_comment`: `InstagramPlatformData.firstComment`,
      `LinkedInPlatformData.firstComment`, `YouTubePlatformData.firstComment`.
      X (`TwitterPlatformData`) and TikTok (`TikTokPlatformData`) have none.
    * `alt_text`: `MediaItem.altText`, "applied on every platform that
      supports it": Instagram (feed images only), X (max 1000 chars) and
      LinkedIn of ours; ignored on TikTok and YouTube. One text, set on
      every image of the post.
    * `title`: `YouTubePlatformData.title` (at most 100 characters).

  Not offered: a YouTube description. Zernio has no description field in
  `YouTubePlatformData`; the post's own text is the description. The cover
  is the #1324 picker's (`Platform.Social.Cover`), not an option here.
  """

  @first_comment_max %{"linkedin" => 1_250, "instagram" => 2_200, "youtube" => 10_000}
  @alt_max 1_000
  @title_max 100

  @fields %{
    "x" => ~w(alt_text),
    "linkedin" => ~w(first_comment alt_text),
    "instagram" => ~w(first_comment alt_text),
    "youtube" => ~w(title first_comment),
    "tiktok" => []
  }

  @type field :: %{key: String.t(), label: String.t(), max: pos_integer(), zernio: String.t()}

  @doc "The option keys `platform` accepts, in display order (`[]` for an unknown platform)."
  @spec keys(String.t() | nil) :: [String.t()]
  def keys(platform), do: Map.get(@fields, platform, [])

  @doc "The options `platform` accepts, each with its label, limit and Zernio field."
  @spec fields(String.t() | nil) :: [field()]
  def fields(platform), do: Enum.map(keys(platform), &field(platform, &1))

  defp field(platform, "first_comment"),
    do: %{
      key: "first_comment",
      label: "First comment",
      max: Map.fetch!(@first_comment_max, platform),
      zernio: "platformSpecificData.firstComment"
    }

  defp field(_platform, "alt_text"),
    do: %{
      key: "alt_text",
      label: "Image alt text",
      max: @alt_max,
      zernio: "mediaItems[].altText"
    }

  defp field(_platform, "title"),
    do: %{
      key: "title",
      label: "Video title",
      max: @title_max,
      zernio: "platformSpecificData.title"
    }

  @doc """
  Cleans `attrs` for `platform`: only its keys, trimmed, blanks dropped.
  `{:error, %{key => message}}` when one is over its limit.
  """
  @spec validate(String.t() | nil, map()) :: {:ok, map()} | {:error, %{String.t() => String.t()}}
  def validate(platform, attrs) when is_map(attrs) do
    fields = fields(platform)

    {clean, errors} =
      Enum.reduce(fields, {%{}, %{}}, fn %{key: key, max: max, label: label}, {clean, errors} ->
        case attrs |> Map.get(key) |> trim() do
          nil ->
            {clean, errors}

          value ->
            if String.length(value) > max,
              do: {clean, Map.put(errors, key, "#{label} must be at most #{max} characters")},
              else: {Map.put(clean, key, value), errors}
        end
      end)

    if errors == %{}, do: {:ok, clean}, else: {:error, errors}
  end

  def validate(_platform, _attrs), do: {:ok, %{}}

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(_), do: nil

  @doc """
  The stored options of a post that still apply to `platform` (a key the
  platform does not take is dropped, never sent).
  """
  @spec for_platform(map() | nil, String.t() | nil) :: map()
  def for_platform(options, platform) when is_map(options),
    do: Map.take(options, keys(platform))

  def for_platform(_options, _platform), do: %{}

  @doc "Zernio `platformSpecificData` keys for the options (firstComment, title)."
  @spec zernio_platform_data(String.t(), map() | nil) :: map()
  def zernio_platform_data(platform, options) do
    options = for_platform(options, platform)

    %{}
    |> put_present(:firstComment, options["first_comment"])
    |> put_present(:title, options["title"])
  end

  @doc "The `altText` to set on every image media item, or nil."
  @spec zernio_alt_text(String.t(), map() | nil) :: String.t() | nil
  def zernio_alt_text(platform, options), do: for_platform(options, platform)["alt_text"]

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end

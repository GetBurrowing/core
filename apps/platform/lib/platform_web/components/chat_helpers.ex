defmodule PlatformWeb.Components.ChatHelpers do
  @moduledoc """
  Shared helpers for chat surfaces — used by both `PlatformWeb.ChatLive` and
  the `PlatformWeb.Components.ChatMessage` function component extracted from it
  in Stage 2 of task 019e0f29 (#11).
  """

  use PlatformWeb, :verified_routes

  def relative_time(nil), do: ""

  def relative_time(%DateTime{} = datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  def image_attachment?(attachment) do
    String.starts_with?(attachment.content_type || "", "image/")
  end

  # Task 01a120be stage 3: video attachments render as an in-place player.
  def video_attachment?(attachment) do
    String.starts_with?(attachment.content_type || "", "video/")
  end

  def attachment_url(attachment), do: ~p"/chat/attachments/#{attachment.id}"

  # Task 01a1655c stage 3: the player's poster frame. A stored poster wins
  # (same-origin paths only, so a row can't make viewers fetch a third-party
  # URL); otherwise the src carries a #t=0.1 media fragment, which makes iOS
  # Safari paint the first frame instead of a black box.
  def video_poster(attachment), do: poster_url(attachment)

  def video_src(attachment) do
    case poster_url(attachment) do
      nil -> attachment_url(attachment) <> "#t=0.1"
      _url -> attachment_url(attachment)
    end
  end

  # The clip's stored aspect ratio, when known, so the box is reserved at the
  # right shape before any bytes load, with the width capped so the box at
  # that ratio fits under 60vh (stage 4). Otherwise the frame holds 16:9 until
  # the ChatClip hook applies the clip's own ratio on loadedmetadata.
  def video_aspect_style(%{metadata: %{"width" => w, "height" => h}})
      when is_integer(w) and is_integer(h) and w > 0 and h > 0,
      do: "aspect-ratio: #{w} / #{h}; max-width: min(100%, calc(60vh * #{w} / #{h}))"

  def video_aspect_style(_attachment), do: nil

  # Task 01a1655c stage 4: the file line under a clip, `<stem>.<ext>` split so
  # the stem can truncate while the extension stays visible.
  def clip_name_parts(filename) when is_binary(filename) do
    case String.split(filename, ".") do
      [_only] -> {filename, ""}
      parts -> {parts |> Enum.drop(-1) |> Enum.join("."), "." <> List.last(parts)}
    end
  end

  def clip_name_parts(_filename), do: {"", ""}

  # Stored duration in seconds as m:ss, or nil when unknown (the ChatClip
  # hook fills it on loadedmetadata).
  def clip_duration(%{metadata: %{"duration" => seconds}})
      when is_number(seconds) and seconds >= 0 do
    total = round(seconds)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  def clip_duration(_attachment), do: nil

  defp poster_url(%{metadata: %{"poster_url" => "/" <> rest = url}}) when is_binary(rest) do
    if String.starts_with?(rest, "/"), do: nil, else: url
  end

  defp poster_url(_attachment), do: nil

  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(_value), do: false

  # Rung 13 stage 1: rendered message html is shown only when something is
  # left after a card replaced its bare link line.
  def rendered_present?({:safe, _} = safe),
    do: safe |> Phoenix.HTML.safe_to_string() |> present?()

  def rendered_present?(_value), do: false

  def reactor_aria_label(%{emoji: emoji, reactors: reactors, extra_count: extra}) do
    names = reactors |> Enum.map(& &1.name) |> Enum.reject(&(&1 in [nil, ""]))

    people =
      case names do
        [] ->
          "Someone"

        [one] ->
          one

        [first, second] ->
          "#{first} and #{second}"

        list ->
          {init, [last]} = Enum.split(list, -1)
          "#{Enum.join(init, ", ")}, and #{last}"
      end

    tail =
      cond do
        extra == 0 -> ""
        extra == 1 -> " and 1 other"
        true -> " and #{extra} others"
      end

    "#{people}#{tail} reacted with #{emoji}"
  end

  # One size-label rule for every surface (task 01a120be): the file chip
  # beside a video card must not read binary-as-MB while the card reads
  # decimal.
  def format_bytes(size) when is_integer(size) and size >= 0,
    do: Platform.Chat.UploadLimits.format_bytes(size)

  def format_bytes(_size), do: "—"
end

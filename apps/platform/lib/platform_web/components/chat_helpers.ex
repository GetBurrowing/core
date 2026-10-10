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

  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(_value), do: false

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

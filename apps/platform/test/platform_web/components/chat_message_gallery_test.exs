defmodule PlatformWeb.Components.ChatMessageGalleryTest do
  @moduledoc """
  Task 01a1b67d stage 3: each gallery item opens the in-app viewer, so it
  must be a focusable, keyboard-operable button. Without tabindex the
  viewer's close could not hand focus back to it and focus fell to BODY.
  Enter/Space are wired in assets/js/hooks/chat_viewer.js (vitest).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  @images [
    %{
      id: "0199aaaa-0000-7000-8000-0000000000a1",
      filename: "red.png",
      content_type: "image/png",
      byte_size: 1200
    },
    %{
      id: "0199aaaa-0000-7000-8000-0000000000a2",
      filename: "blue.png",
      content_type: "image/png",
      byte_size: 1300
    }
  ]

  defp row_html(attachments, msg_id \\ "msg-1") do
    assigns = %{
      msg: %{
        id: msg_id,
        space_id: "space-1",
        participant_id: "p-1",
        content: "two images",
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-11-07 10:00:00.000000Z],
        day_label: nil,
        reactions: [],
        versions_count: 1,
        corrects_message_id: nil,
        metadata: %{}
      },
      attachments_map: %{msg_id => attachments}
    }

    rendered_to_string(~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-1"
      msg={@msg}
      current_participant={nil}
      agent_participant_ids={MapSet.new()}
      participants_map={%{"p-1" => %{name: "Alex", avatar_url: nil, avatar_seed: nil}}}
      quick_emojis={[]}
      pinned_message_ids={MapSet.new()}
      canvases_by_id={%{}}
      attachments_map={@attachments_map}
      thread_previews={%{}}
      expanded_threads={MapSet.new()}
      inline_thread_messages={%{}}
    />
    """)
  end

  defp items(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-role=gallery-item]")
  end

  defp attr_of(node, name) do
    case LazyHTML.attribute(node, name) do
      [value] -> value
      [] -> nil
    end
  end

  test "every gallery item is a focusable button that opens the viewer" do
    nodes = items(row_html(@images))
    assert Enum.count(nodes) == 2

    for node <- nodes do
      assert attr_of(node, "tabindex") == "0"
      assert attr_of(node, "role") == "button"
      assert attr_of(node, "data-viewer-open") == ""
      assert attr_of(node, "phx-click") == "viewer_open"
      assert attr_of(node, "id") =~ ~r/^gallery-msg-1-/
    end
  end

  test "each item is named by its position and filename" do
    labels = row_html(@images) |> items() |> Enum.map(&attr_of(&1, "aria-label"))
    assert labels == ["Open image 1 of 2: red.png", "Open image 2 of 2: blue.png"]
  end

  test "a single image is still a focusable button" do
    [node] = row_html(Enum.take(@images, 1)) |> items() |> Enum.to_list()
    assert attr_of(node, "tabindex") == "0"
    assert attr_of(node, "role") == "button"
    assert attr_of(node, "aria-label") == "Open image 1 of 1: red.png"
  end
end

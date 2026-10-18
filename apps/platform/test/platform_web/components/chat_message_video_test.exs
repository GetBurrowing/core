defmodule PlatformWeb.Components.ChatMessageVideoTest do
  @moduledoc "Task 01a120be stage 3: a received video plays in place."
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  defp row_html(attachments) do
    assigns = %{
      msg: %{
        id: "msg-1",
        space_id: "space-1",
        participant_id: "p-1",
        content: "the clip",
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-10-09 10:00:00.000000Z],
        day_label: nil,
        reactions: [],
        versions_count: 1,
        corrects_message_id: nil,
        metadata: %{}
      },
      attachments_map: %{"msg-1" => attachments}
    }

    rendered_to_string(~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-1"
      msg={@msg}
      current_participant={nil}
      agent_participant_ids={MapSet.new()}
      agent_colors_map={%{}}
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

  @video %{
    id: "0199aaaa-0000-7000-8000-000000000001",
    filename: "launch-walkthrough.mov",
    content_type: "video/quicktime",
    byte_size: 900_000_000
  }

  test "a video renders <video preload=metadata> without autoplay, with the size and Download" do
    html = row_html([@video])
    doc = LazyHTML.from_fragment(html)

    [video] = doc |> LazyHTML.query("video") |> Enum.to_list()
    assert LazyHTML.attribute(video, "preload") == ["metadata"]
    assert LazyHTML.attribute(video, "src") == ["/chat/attachments/#{@video.id}"]
    assert LazyHTML.attribute(video, "autoplay") == []
    assert LazyHTML.attribute(video, "controls") != []

    card = doc |> LazyHTML.query(~s([data-role="video-attachment"])) |> LazyHTML.text()
    assert card =~ "900 MB"
    assert card =~ "Download"
    assert card =~ "launch-walkthrough.mov"
  end

  test "a non-video file keeps the paperclip link" do
    html = row_html([%{@video | content_type: "application/pdf", filename: "spec.pdf"}])
    refute html =~ "<video"
    assert html =~ "hero-paper-clip"
    assert html =~ "spec.pdf"
  end
end

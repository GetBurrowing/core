defmodule PlatformWeb.ChatLive.Partials.ComposerStreamingSlotTest do
  @moduledoc """
  The streaming reply bubble wears the agent's identity slot exactly as the
  settled row will (task 01a1557a rung 3 stage 2): the same
  `data-agent-slot`, no inline accent, a caret that is base-content (it is a
  status, never the hue) and a full base-content body.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  @participants %{"p-agent" => %{name: "Pixel", avatar_url: nil, avatar_seed: nil}}

  defp bubble(slots) do
    assigns = %{slots: slots, participants: @participants}

    ~H"""
    <PlatformWeb.ChatLive.Partials.Composer.streaming_replies
      streaming_replies={%{"chunk-1" => %{text: "thinking out loud", participant_id: "p-agent"}}}
      agent_slots_map={@slots}
      participants_map={@participants}
    />
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp settled(slots) do
    assigns = %{slots: slots, participants: @participants}

    ~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-1"
      msg={
        %{
          id: "m-1",
          space_id: "s-1",
          participant_id: "p-agent",
          content: "done",
          content_type: "text",
          canvas_id: nil,
          inserted_at: ~U[2026-10-20 10:00:00.000000Z],
          day_label: nil,
          reactions: [],
          versions_count: 1,
          corrects_message_id: nil,
          metadata: nil
        }
      }
      current_participant={nil}
      agent_participant_ids={MapSet.new(["p-agent"])}
      agent_slots_map={@slots}
      participants_map={@participants}
      quick_emojis={[]}
      pinned_message_ids={MapSet.new()}
      canvases_by_id={%{}}
      attachments_map={%{}}
      thread_previews={%{}}
      expanded_threads={MapSet.new()}
      inline_thread_messages={%{}}
    />
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp attr_of(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  test "the bubble carries the same slot as the settled row, for every slot and for none" do
    for slots <- [%{} | Enum.map(Platform.Agents.ColorPalette.ids(), &%{"p-agent" => &1})] do
      [slot] = attr_of(bubble(slots), "#streaming-chunk-1", "data-agent-slot")
      assert [slot] == attr_of(settled(slots), "#row-1", "data-agent-slot"), inspect(slots)
      assert slot == Map.get(slots, "p-agent", "blue")
    end
  end

  test "no inline accent, a base-content caret and a full base-content body" do
    doc = bubble(%{"p-agent" => "teal"})
    html = LazyHTML.to_html(doc)

    refute html =~ "agent-accent"
    refute html =~ "style="
    assert attr_of(doc, "#streaming-chunk-1", "class") |> hd() =~ "msg-agent"

    [caret] = attr_of(doc, ~s([data-role="streaming-caret"]), "class")
    assert caret =~ "bg-base-content"
    refute caret =~ "--ag"

    [body] = attr_of(doc, ~s([data-role="streaming-body"]), "class")

    assert body =~ "text-base-content"
    refute body =~ "text-base-content/"
    refute body =~ "border-l"
  end
end

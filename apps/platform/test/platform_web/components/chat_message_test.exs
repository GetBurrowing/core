defmodule PlatformWeb.Components.ChatMessageTest do
  @moduledoc """
  `PlatformWeb.Components.ChatMessage` rendering. Task 01a0cf21 stage 3: an
  inbound email carries one provenance line above its body, and no other
  message does.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  defp row_html(metadata, content \\ "the body") do
    assigns = %{
      msg: %{
        id: "msg-1",
        space_id: "space-1",
        participant_id: "p-email",
        content: content,
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-09-23 10:00:00.000000Z],
        day_label: nil,
        reactions: [],
        versions_count: 1,
        corrects_message_id: nil,
        metadata: metadata
      }
    }

    rendered_to_string(~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-1"
      msg={@msg}
      current_participant={nil}
      agent_participant_ids={MapSet.new()}
      agent_colors_map={%{}}
      participants_map={
        %{"p-email" => %{name: "Email (external)", avatar_url: nil, avatar_seed: nil}}
      }
      quick_emojis={[]}
      pinned_message_ids={MapSet.new()}
      canvases_by_id={%{}}
      attachments_map={%{}}
      thread_previews={%{}}
      expanded_threads={MapSet.new()}
      inline_thread_messages={%{}}
    />
    """)
  end

  @email_meta %{
    "source" => "email_inbound",
    "skip_mention_scan" => true,
    "account_address" => "support@acme.test",
    "from" => "Mallory <mallory@evil.test>",
    "message_id" => "<hostile-1@evil.test>"
  }

  test "an inbound email renders the provenance line above the body" do
    html = row_html(@email_meta)
    doc = LazyHTML.from_fragment(html)

    [line] = doc |> LazyHTML.query(~s([data-role="mail-inbound-provenance"])) |> Enum.to_list()
    text = LazyHTML.text(line)

    assert text =~ "Email to support@acme.test, from Mallory <mallory@evil.test>"
    assert LazyHTML.attribute(line, "class") |> hd() =~ "text-xs"
    assert LazyHTML.attribute(line, "class") |> hd() =~ "text-base-content/60"
    assert line |> LazyHTML.query(".hero-envelope") |> Enum.count() == 1

    [id] = doc |> LazyHTML.query(~s([data-role="mail-inbound-message-id"])) |> Enum.to_list()
    assert LazyHTML.text(id) =~ "<hostile-1@evil.test>"
    assert LazyHTML.attribute(id, "class") |> hd() =~ "font-mono"

    # Provenance precedes the body.
    {prov_at, _} = :binary.match(html, "mail-inbound-provenance")
    # (Match the rendered body's container: the raw text also appears
    # earlier, in the copy button's data-clipboard-text.)
    {body_at, _} = :binary.match(html, "chat-markdown")
    assert prov_at < body_at
  end

  test "header values are escaped, not rendered as markup" do
    html = row_html(Map.put(@email_meta, "from", "<img src=x onerror=alert(1)>"))
    refute html =~ "<img src=x"
    assert html =~ "&lt;img src=x"
  end

  test "ordinary messages carry no provenance line" do
    for metadata <- [nil, %{}, %{"source" => "task_router"}] do
      html = row_html(metadata)
      refute html =~ "mail-inbound-provenance"
      refute html =~ "mail-inbound-message-id"
    end
  end
end

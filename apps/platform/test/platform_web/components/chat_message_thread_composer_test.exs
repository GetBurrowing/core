defmodule PlatformWeb.Components.ChatMessageThreadComposerTest do
  @moduledoc """
  The thread reply box in `PlatformWeb.Components.ChatMessage` (redesign
  rung 10, stage 4; direction canvas 01a16233, rule "Thread replies").

  The box is the space composer's chip field, and its @mention list is the
  space composer's own `Partials.MentionList`, opened only for this box's
  `mention_source`. The list hangs from the box's top edge, and that
  anchoring lives in app.css (`.thread-field-box .mention-list`), never in
  an inline style. Send is disabled until there is text: the server cannot
  see the field, so it always renders Send disabled and ComposeInput lights it.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  defp msg do
    %{
      id: "msg-1",
      space_id: "space-1",
      participant_id: "p-human",
      content: "root",
      content_type: "text",
      canvas_id: nil,
      inserted_at: ~U[2026-10-23 10:00:00.000000Z],
      day_label: nil,
      reactions: [],
      versions_count: 1,
      corrects_message_id: nil
    }
  end

  defp suggestions do
    [
      %{
        participant_type: "user",
        name: "Person One",
        display_name: "Person One",
        avatar_url: nil,
        avatar_seed: "person-one",
        not_in_space: false
      },
      %{
        participant_type: "agent",
        name: "Builder",
        display_name: "Builder",
        avatar_url: nil,
        avatar_seed: "builder",
        not_in_space: false
      }
    ]
  end

  defp thread_html(opts) do
    assigns = %{
      msg: msg(),
      suggestions: Keyword.get(opts, :suggestions, suggestions()),
      source: Keyword.get(opts, :source),
      query: Keyword.get(opts, :query),
      participant: Keyword.get(opts, :participant, %{id: "p-human"}),
      replies: Keyword.get(opts, :replies, [])
    }

    rendered_to_string(~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-1"
      msg={@msg}
      current_participant={@participant}
      agent_participant_ids={MapSet.new()}
      participants_map={%{"p-human" => %{name: "Dana Reed", avatar_url: nil, avatar_seed: "s"}}}
      quick_emojis={[]}
      pinned_message_ids={MapSet.new()}
      canvases_by_id={%{}}
      attachments_map={%{}}
      thread_previews={%{}}
      expanded_threads={MapSet.new(["msg-1"])}
      inline_thread_messages={%{"msg-1" => @replies}}
      mention_suggestions={@suggestions}
      mention_source={@source}
      mention_query={@query}
    />
    """)
  end

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> find(selector) |> Enum.count()

  defp attr_of(html, selector, name) do
    case html |> find(selector) |> LazyHTML.attribute(name) do
      [value] -> value
      other -> flunk("expected one #{selector}, got #{inspect(other)}")
    end
  end

  @form "form#inline-thread-compose-form-msg-1"
  @list "#inline-thread-mention-list-msg-1"

  defp reply(id, content) do
    %{
      id: id,
      space_id: "space-1",
      participant_id: "p-human",
      content: content,
      inserted_at: ~U[2026-10-23 10:01:00.000000Z]
    }
  end

  # Rung 10 stage 5 (the shape of gate case 7007, in the thread): a reply
  # row arriving after a send was inserted as the reply box's sibling, and
  # the DOM patch re-appended the box after it, moving (and blurring) the
  # focused field. The rows now live inside an always-rendered container,
  # so the box's siblings are the same whether there are 0 replies or 2.
  test "reply rows live in their own container; the reply box's siblings never change" do
    for replies <- [[], [reply("r-1", "one"), reply("r-2", "two")]] do
      html = thread_html(replies: replies)

      assert html |> find("#inline-thread-msg-1 > *") |> LazyHTML.attribute("id") |> Enum.take(2) ==
               ["inline-thread-replies-msg-1", "inline-thread-composer-msg-1"]

      assert count(html, "#inline-thread-replies-msg-1.contents") == 1
      assert count(html, "#inline-thread-msg-1 > .thread-reply") == 0
      assert count(html, "#inline-thread-composer-msg-1 #{@form}") == 1

      assert html
             |> find("#inline-thread-replies-msg-1 > .thread-reply")
             |> LazyHTML.attribute("id") ==
               Enum.map(replies, &"inline-thread-reply-#{&1.id}")
    end
  end

  test "renders the shared mention list for its own source, agents first" do
    html = thread_html(source: "inline-thread-compose-form-msg-1", query: "")

    assert count(html, "#{@form} .thread-field-box [data-role=mention-list] #{@list}") == 1
    assert attr_of(html, @list, "role") == "listbox"

    names =
      html
      |> find("#{@list} [role=option]")
      |> LazyHTML.attribute("data-mention-name")

    assert names == ["Builder", "Person One"]
  end

  test "the list stays closed for the space composer's source and for another thread" do
    for source <- ["compose-form", "inline-thread-compose-form-other", nil] do
      html = thread_html(source: source, query: "")
      assert count(html, @list) == 0, "the thread list opened for #{inspect(source)}"
      # The wrapper is still there (it never moves the field), holding nothing.
      assert count(
               html,
               "#{@form} #inline-thread-mention-list-msg-1-wrap[data-role=mention-list]"
             ) == 1
    end
  end

  test "an empty filter in this thread renders the empty row" do
    html = thread_html(source: "inline-thread-compose-form-msg-1", query: "zzqx", suggestions: [])

    assert html |> find("#{@list} [data-role=mention-list-empty]") |> LazyHTML.text() =~
             "No one matches “zzqx”"
  end

  test "the field is the chip combobox, Enter sends, with its own draft key" do
    html = thread_html([])
    field = "#inline-thread-compose-msg-1"

    assert attr_of(html, field, "contenteditable") == "true"
    assert attr_of(html, field, "phx-hook") == "ComposeInput"
    assert attr_of(html, field, "phx-update") == "ignore"
    assert attr_of(html, field, "role") == "combobox"
    assert attr_of(html, field, "aria-controls") == "inline-thread-mention-list-msg-1"
    assert attr_of(html, field, "enterkeyhint") == "send"
    assert attr_of(html, field, "data-placeholder") == "Reply in thread..."
    assert attr_of(html, field, "data-draft-key") == "thread-draft:msg-1"
    refute attr_of(html, field, "data-draft-key") =~ "chat-draft:"
    assert attr_of(html, field, "data-value-input") == "inline-thread-compose-value-msg-1"
    assert count(html, "#{field}[data-clear-on-submit]") == 1

    # The form value: a hidden text input named as the reply handler reads it.
    value = "#{@form} input#inline-thread-compose-value-msg-1"
    assert attr_of(html, value, "name") == "inline_thread_compose[text]"
    assert attr_of(html, value, "type") == "text"
    assert count(html, "#{value}[hidden]") == 1

    # The old plain text input is gone.
    assert count(html, "#{@form} input.thread-input") == 0
  end

  test "Send is disabled when the field is empty, and blocked without a participant" do
    html = thread_html([])
    send = "#{@form} button[type=submit]"
    assert count(html, "#{send}[disabled]") == 1
    assert attr_of(html, send, "data-send-blocked") == "false"
    assert attr_of(html, send, "data-staged") == "false"

    blocked = thread_html(participant: nil)
    assert attr_of(blocked, send, "data-send-blocked") == "true"
  end

  test "no inline absolute positioning and no hover: in the thread composer" do
    html = thread_html(source: "inline-thread-compose-form-msg-1", query: "")
    [composer] = html |> find(".thread-composer") |> Enum.map(&LazyHTML.to_html/1)

    styles = composer |> find("[style]") |> LazyHTML.attribute("style")
    refute Enum.any?(styles, &(&1 =~ "absolute")), "inline style positions: #{inspect(styles)}"
    refute composer =~ "position: relative"
    refute composer =~ "hover:"
  end

  test "app.css anchors the thread list to the box's top edge, at its width" do
    css = File.read!(@css_path)

    [body] =
      Regex.run(~r/\.thread-field-box \.mention-list\s*\{([^}]*)\}/, css, capture: :all_but_first)

    for decl <- ["position: absolute", "left: 0", "right: 0", "bottom: 100%", "margin: 0"] do
      assert body =~ decl, ".thread-field-box .mention-list lacks `#{decl}`"
    end

    refute body =~ "box-shadow"

    [box] = Regex.run(~r/\n\.thread-field-box\s*\{([^}]*)\}/, css, capture: :all_but_first)
    assert box =~ "position: relative"
  end
end

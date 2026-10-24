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
    assert LazyHTML.attribute(line, "class") |> hd() =~ "text-subtle"
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
      refute html =~ "federation-inbound-provenance"
    end
  end

  # Task 01a0d90f stage 5: a peer install's shared-space message.
  @federation_meta %{
    "source" => "federation_inbound",
    "skip_mention_scan" => true,
    "peer_id" => "019f0000-0000-7000-8000-000000000001",
    "remote_message_id" => "019f0000-0000-7000-8000-000000000002",
    "peer_display_name" => "Acme Suite",
    "remote_author" => "Pat"
  }

  test "a peer-install message renders the federation provenance line above the body" do
    html = row_html(@federation_meta)
    doc = LazyHTML.from_fragment(html)

    [line] =
      doc |> LazyHTML.query(~s([data-role="federation-inbound-provenance"])) |> Enum.to_list()

    assert LazyHTML.text(line) =~ "Shared from Acme Suite, by Pat"
    assert LazyHTML.attribute(line, "class") |> hd() =~ "text-xs"
    assert line |> LazyHTML.query(".hero-globe-alt") |> Enum.count() == 1
    refute html =~ "mail-inbound-provenance"

    {prov_at, _} = :binary.match(html, "federation-inbound-provenance")
    {body_at, _} = :binary.match(html, "chat-markdown")
    assert prov_at < body_at
  end

  test "federation provenance values are escaped, not rendered as markup" do
    html = row_html(Map.put(@federation_meta, "remote_author", "<img src=x onerror=alert(1)>"))
    refute html =~ "<img src=x"
    assert html =~ "&lt;img src=x"
  end

  # ── The message pill (redesign rung 9, task 01a1557a-9406) ──────────

  defp agent_row_html(metadata, opts) do
    agent? = Keyword.get(opts, :agent?, true)

    assigns = %{
      msg: %{
        id: "msg-a",
        space_id: "space-1",
        participant_id: "p-agent",
        content: "you need to take action on 6",
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-09-25 10:00:00.000000Z],
        day_label: nil,
        reactions: [],
        versions_count: 1,
        corrects_message_id: nil,
        metadata: metadata
      },
      agent_ids: if(agent?, do: MapSet.new(["p-agent"]), else: MapSet.new()),
      slots: Keyword.get(opts, :slots, %{}),
      highlighted: Keyword.get(opts, :highlighted),
      read_only: Keyword.get(opts, :read_only, false),
      quick_emojis: Keyword.get(opts, :quick_emojis, [])
    }

    rendered_to_string(~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-a"
      msg={@msg}
      current_participant={nil}
      agent_participant_ids={@agent_ids}
      agent_slots_map={@slots}
      highlighted_message_id={@highlighted}
      participants_map={%{"p-agent" => %{name: "Octavius", avatar_url: nil, avatar_seed: nil}}}
      quick_emojis={@quick_emojis}
      pinned_message_ids={MapSet.new()}
      canvases_by_id={%{}}
      attachments_map={%{}}
      thread_previews={%{}}
      expanded_threads={MapSet.new()}
      inline_thread_messages={%{}}
      read_only={@read_only}
    />
    """)
  end

  defp count_role(html, role) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="#{role}"]))
    |> Enum.count()
  end

  @with_context %{"reply_context" => "Six tasks await approval", "reply_to_message_id" => "q-1"}

  @pill_labels ["React with thumbs up", "Reply in thread", "Copy", "More actions"]

  defp pill(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(~s([data-role="message-pill"]))
  end

  defp pill_buttons(html), do: html |> pill() |> LazyHTML.query("button") |> Enum.to_list()

  defp classes_in(node) do
    [node | node |> LazyHTML.query("*") |> Enum.to_list()]
    |> Enum.flat_map(&LazyHTML.attribute(&1, "class"))
    |> Enum.flat_map(&String.split/1)
  end

  test "every non-read-only message renders the pill with the four actions, in order" do
    for {metadata, opts} <- [
          {@with_context, []},
          {%{}, []},
          {nil, [agent?: false]}
        ] do
      html = agent_row_html(metadata, opts)
      assert count_role(html, "message-pill") == 1

      [p] = html |> pill() |> Enum.to_list()
      assert LazyHTML.attribute(p, "role") == ["toolbar"]
      assert LazyHTML.attribute(p, "aria-label") == ["Message actions"]

      labels = for b <- pill_buttons(html), do: b |> LazyHTML.attribute("aria-label") |> hd()
      assert labels == @pill_labels
    end
  end

  test "the pill is neutral: no primary class anywhere in it, and no hover: utility" do
    [p] = agent_row_html(@with_context, []) |> pill() |> Enum.to_list()
    classes = classes_in(p)

    assert "bg-base-300" in classes
    assert "border-edge" in classes
    assert "text-subtle" in classes
    refute Enum.any?(classes, &String.contains?(&1, "primary")), inspect(classes)
    refute Enum.any?(classes, &String.contains?(&1, "hover:")), inspect(classes)
  end

  test "the pill's buttons do what their labels say" do
    quick = Platform.Chat.Emoji.quick_defaults()
    html = agent_row_html(@with_context, quick_emojis: quick)
    [thumbs, reply, copy, more] = pill_buttons(html)

    assert LazyHTML.attribute(thumbs, "phx-click") == ["react"]
    assert LazyHTML.attribute(thumbs, "phx-value-emoji") == [hd(quick)]
    assert LazyHTML.attribute(thumbs, "phx-value-message-id") == ["msg-a"]

    assert LazyHTML.attribute(reply, "phx-click") == ["open_inline_thread"]
    assert LazyHTML.attribute(reply, "phx-value-message-id") == ["msg-a"]

    # Copy is client-side (MessageGestures): no server event.
    assert LazyHTML.attribute(copy, "phx-click") == []
    assert LazyHTML.attribute(copy, "data-role") == ["message-pill-copy"]
    assert LazyHTML.attribute(copy, "data-clipboard-text") == ["you need to take action on 6"]

    assert LazyHTML.attribute(more, "phx-click") == ["open_message_actions"]
    assert LazyHTML.attribute(more, "phx-value-id") == ["msg-a"]
  end

  test "the row carries the MessageGestures hook and is focusable" do
    html = agent_row_html(@with_context, [])
    assert row_attr(html, "phx-hook") == ["MessageGestures"]
    assert row_attr(html, "tabindex") == ["0"]
  end

  test "an agent message with context renders no header Context button and no Summarise" do
    for metadata <- [@with_context, %{"reply_to_message_id" => "q-1"}, %{}, nil] do
      html = agent_row_html(metadata, [])
      assert count_role(html, "message-context-trigger") == 0
      assert count_role(html, "message-context-summarise") == 0
      refute html =~ ">Context<"
    end
  end

  test "there is no hover action row and no left-gutter reply" do
    for opts <- [[], [agent?: false], [read_only: true]] do
      html = agent_row_html(@with_context, opts)
      refute html =~ "message-action-row"
      refute html =~ "msg-reply-gutter"
    end
  end

  test "a read-only snapshot renders no pill, no hook and no tab stop" do
    html = agent_row_html(@with_context, read_only: true)
    assert count_role(html, "message-pill") == 0
    assert row_attr(html, "phx-hook") == []
    assert row_attr(html, "tabindex") == []
    refute html =~ "MessageGestures"
  end

  # A LiveView render cannot hit-test or apply a stylesheet, so these pin the
  # CSS the pill depends on against the classes the row actually renders.
  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  defp css_rules, do: @css_path |> File.read!() |> Platform.Design.CssRules.rules()

  defp rendered_element(html, selector) do
    [node] = html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list()
    [{tag, attrs, _}] = LazyHTML.to_tree(node)
    Platform.Design.CssRules.element(tag, attrs)
  end

  defp px(body, prop) do
    [_, n] = Regex.run(~r/(?:^|;|\s)#{prop}:\s*(-?\d+)px/, body)
    String.to_integer(n)
  end

  test "the pill is hidden at rest and shown by data-pill-open" do
    p = rendered_element(agent_row_html(@with_context, []), ~s([data-role="message-pill"]))

    [rest] =
      Enum.filter(css_rules(), fn r ->
        r.at == [] and r.selector == ".message-pill"
      end)

    assert rest.body =~ ~r/display:\s*none/
    assert Platform.Design.CssRules.matches?(rest.selector, p)

    assert Enum.any?(css_rules(), fn r ->
             r.at == [] and r.selector =~ "[data-pill-open]" and
               String.ends_with?(r.selector, ".message-pill") and r.body =~ ~r/display:\s*flex/
           end)
  end

  test "below lg each pill button carries a hit area 44px tall" do
    [btn | _] = agent_row_html(@with_context, []) |> pill_buttons()
    [{tag, attrs, _}] = LazyHTML.to_tree(btn)
    el = Platform.Design.CssRules.element(tag, attrs)

    [hit] =
      Enum.filter(css_rules(), fn r ->
        r.at == ["@media (width < 64rem)"] and String.ends_with?(r.selector, "::after") and
          Platform.Design.CssRules.matches?(r.selector, el)
      end)

    assert hit.body =~ ~r/position:\s*absolute/
    assert hit.body =~ ~r/content:\s*""/
    # The button is a 28px circle (`size-7`) below lg.
    assert "size-7" in (attrs |> Map.new() |> Map.fetch!("class") |> String.split())
    assert 28 - px(hit.body, "top") - px(hit.body, "bottom") >= 44
  end

  # ── Agent identity slot (task 01a1557a rung 3 stage 2) ──────────────

  defp row_attr(html, attr) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#row-a")
    |> LazyHTML.attribute(attr)
  end

  test "an agent row carries data-agent-slot for its stored slot" do
    for id <- Platform.Agents.ColorPalette.ids() do
      html = agent_row_html(nil, slots: %{"p-agent" => id})
      assert row_attr(html, "data-agent-slot") == [id]
    end
  end

  test "an agent missing from the slot map, or with an unknown id, is the blue slot" do
    assert row_attr(agent_row_html(nil, []), "data-agent-slot") == ["blue"]

    for stored <- [nil, "", "magenta"] do
      html = agent_row_html(nil, slots: %{"p-agent" => stored})
      assert row_attr(html, "data-agent-slot") == ["blue"], inspect(stored)
    end
  end

  test "a human row carries no slot, and no row carries an inline accent" do
    human = agent_row_html(nil, agent?: false, slots: %{"p-agent" => "teal"})
    assert row_attr(human, "data-agent-slot") == []

    for html <- [human, agent_row_html(nil, slots: %{"p-agent" => "teal"})] do
      refute html =~ "agent-accent"
      assert row_attr(html, "style") == []
    end
  end

  test "the agent name is msg-agent-name alone, and the pill is the uppercase AI badge" do
    doc = agent_row_html(nil, []) |> LazyHTML.from_fragment()
    [name] = doc |> LazyHTML.query(".msg-agent-name") |> Enum.to_list()
    # No Tailwind size or weight competing with the slot rule's own.
    assert LazyHTML.attribute(name, "class") == ["msg-agent-name"]
    [badge] = doc |> LazyHTML.query(".msg-agent-badge") |> Enum.to_list()
    assert LazyHTML.text(badge) |> String.trim() == "AI"
  end

  test "a highlighted agent row keeps its slot and the primary ring" do
    html = agent_row_html(nil, slots: %{"p-agent" => "rose"}, highlighted: "msg-a")
    assert row_attr(html, "data-agent-slot") == ["rose"]
    [class] = row_attr(html, "class")
    assert class =~ "msg-agent"
    assert class =~ "ring-primary/20"
  end
end

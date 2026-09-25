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

  # ── The "Context" trigger (task 01a0d8de stage 3) ───────────────────

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
      read_only: Keyword.get(opts, :read_only, false)
    }

    rendered_to_string(~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-a"
      msg={@msg}
      current_participant={nil}
      agent_participant_ids={@agent_ids}
      agent_colors_map={%{}}
      participants_map={%{"p-agent" => %{name: "Octavius", avatar_url: nil, avatar_seed: nil}}}
      quick_emojis={[]}
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

  test "the Context trigger renders after the time on an agent message with context" do
    html = agent_row_html(@with_context, [])
    assert count_role(html, "message-context-trigger") == 1

    [trigger] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="message-context-trigger"]))
      |> Enum.to_list()

    assert LazyHTML.text(trigger) =~ "Context"
    classes = trigger |> LazyHTML.attribute("class") |> hd()
    assert classes =~ "text-[10px]"
    assert classes =~ "text-base-content/40"
    assert classes =~ "shrink-0"
    assert LazyHTML.attribute(trigger, "phx-click") == ["open_message_context"]
    # The row, not the trigger, carries data-message-id.
    assert LazyHTML.attribute(trigger, "data-message-id") == []

    {time_at, _} = :binary.match(html, "message-time-msg-a")
    {trigger_at, _} = :binary.match(html, "message-context-trigger")
    assert time_at < trigger_at
  end

  test "the trigger renders for reply_to_message_id alone, the key built-in agents write" do
    html = agent_row_html(%{"reply_to_message_id" => "q-1"}, [])
    assert count_role(html, "message-context-trigger") == 1
  end

  test "no trigger on an agent message without context, nor on any human message" do
    for metadata <- [nil, %{}, %{"reply_context" => "   "}, %{"source" => "runtime"}] do
      assert count_role(agent_row_html(metadata, []), "message-context-trigger") == 0
    end

    assert count_role(agent_row_html(@with_context, agent?: false), "message-context-trigger") ==
             0
  end

  test "the trigger stays on a read-only snapshot, where the hover row does not" do
    html = agent_row_html(@with_context, read_only: true)
    assert count_role(html, "message-context-trigger") == 1
    refute html =~ "message-action-row"
  end

  test "Summarise what led here appears only on agent messages with no context" do
    html = agent_row_html(%{}, [])
    assert count_role(html, "message-context-summarise") == 1
    assert html =~ ~s(aria-label="Summarise what led here")

    assert count_role(agent_row_html(@with_context, []), "message-context-summarise") == 0
    assert count_role(agent_row_html(%{}, agent?: false), "message-context-summarise") == 0
    assert count_role(agent_row_html(%{}, read_only: true), "message-context-summarise") == 0
  end

  # ── Touch: the tap on Context must reach Context (task 01a0d8de stage 5) ──
  #
  # A LiveView render cannot hit-test, so these pin the two CSS rules the
  # browser measurement depends on, against the classes the row actually
  # renders. The measurement itself (tap at 375px opens the sheet,
  # `elementFromPoint` returns the trigger, 45px hit box) is the proof; these
  # go red when either rule is deleted, renamed or detached from the markup.
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

  test "on hover: none the rendered hover strip is hidden and inert, so a tap's focus cannot raise it" do
    strip = rendered_element(agent_row_html(@with_context, []), ".message-action-row")

    hidden =
      Enum.filter(css_rules(), fn r ->
        r.at == ["@media (hover: none)"] and not String.contains?(r.selector, ":") and
          Platform.Design.CssRules.matches?(r.selector, strip)
      end)

    assert [%{body: body}] = hidden,
           "expected exactly one unconditional `(hover: none)` rule hiding the strip; " <>
             "without it a tap that focuses the Context trigger reveals the strip over it " <>
             "and swallows the tap (reviewer measurement, 375px, 2 of 2)"

    assert body =~ ~r/(^|;|\s)opacity:\s*0\s*;/
    assert body =~ ~r/(^|;|\s)pointer-events:\s*none\s*;/

    # The only way back on a touch screen is KEYBOARD focus inside the strip.
    # A bare `:focus-within` / `:focus` re-reveal would reinstate the defect,
    # because a tap gives the trigger `:focus`.
    reveals =
      Enum.filter(css_rules(), fn r ->
        r.at == ["@media (hover: none)"] and String.contains?(r.selector, "message-action-row") and
          r.body =~ ~r/opacity:\s*1/
      end)

    assert reveals != []
    for r <- reveals, do: assert(r.selector =~ ":focus-visible", r.selector)
    for r <- reveals, do: refute(r.selector =~ ~r/:focus(-within)?(?!-visible)/, r.selector)
  end

  test "below lg the rendered Context trigger carries a hit area of at least 44px tall" do
    trigger =
      rendered_element(
        agent_row_html(@with_context, []),
        ~s([data-role="message-context-trigger"])
      )

    [hit] =
      Enum.filter(css_rules(), fn r ->
        r.at == ["@media (width < 64rem)"] and String.ends_with?(r.selector, "::after") and
          Platform.Design.CssRules.matches?(r.selector, trigger)
      end)

    assert hit.body =~ ~r/position:\s*absolute/
    assert hit.body =~ ~r/content:\s*""/

    # 15px is the trigger's own box at 10px text (measured, 375px). The
    # pseudo-element extends it by -top and -bottom.
    assert 15 - px(hit.body, "top") - px(hit.body, "bottom") >= 44

    [anchor] =
      Enum.filter(css_rules(), fn r ->
        r.at == [] and r.selector == ".message-context-trigger"
      end)

    assert anchor.body =~ ~r/position:\s*relative/
    assert Platform.Design.CssRules.matches?(anchor.selector, trigger)
  end
end

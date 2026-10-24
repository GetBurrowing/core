defmodule Platform.Design.MessageAttentionContrastGuardTest do
  @moduledoc """
  Holds the paint of redesign rung 12, "Get someone's attention" (task
  01a1557a-a30a stage 3), in all ten preset variants (Burrow, Midnight, Sand,
  Forest, High contrast; light and dark), with NO exemption. Modelled on
  `message_actions_contrast_guard_test.exs` (rung 9's guard on the same
  surfaces): slots are read from markup, tokens from app.css and
  theme_presets.css, `--subtle` painted on the worst pixel
  `PaintedComposite` allows.

  ## Pairs and floors

  | pair                                                                 | floor |
  |----------------------------------------------------------------------|-------|
  | added line: --subtle on every message band (painted)                 | 4.5   |
  | chip text: base-content on the primary tint, over every band         | 4.5   |
  | add-someone text: --subtle on the own-message bands (painted)        | 4.5   |
  | add-someone dashed border: its slot against the own-message bands    | 3     |
  | pill +@ glyph: --subtle on the pill fill (painted)                   | 4.5   |
  | sheet row @+ glyph: --subtle on the sheet / popover ground (painted) | 4.5   |
  | sheet row meta: --subtle on the sheet / popover ground (painted)     | 4.5   |
  | picker "added": --subtle on the sheet / popover ground (painted)     | 4.5   |

  ## The bands

  The added line renders inside `.message-row-inner`, so its ground is the
  band the row paints at that moment:

    * `chat`: the chat scroller's ground (someone else's human message);
    * `own`: the own row's `bg-<slot>/<n>` composited over the chat ground,
      every pixel the four `PaintedComposite` formulas allow;
    * `open`: the raised band behind an open pill (`[data-pill-open] >
      .message-row-inner` in app.css, pinned below), which also covers an
      own row because the inner band is opaque;
    * `agent <slot>`: an agent row's opaque `--ag-<slot>-tint`, every pixel
      `PaintedMix` recorded for it over base-100 (ten slots).

  The add-someone button only renders on the viewer's own human messages, so
  it is measured on `own` and `open`.

  ## The chip's tint is an unmeasured strength

  The chip paints `bg-<slot>/<n>`: the slot at n% ALPHA over the band.
  `PaintedComposite.contrast_min/3` refuses any n outside its measured
  corpus (55/57/60), and n is 15. So this guard does not call it for the
  chip. It takes the four formulas at n (`PaintedComposite.paint/4`, which
  every formula defines for any integer percent), per channel, widens every
  channel by `@chip_slack` bytes either way, and measures the chip text
  against the WORST pixel of that box. Over every byte pair the four formulas
  disagree by at most 2 levels per channel at 15% (as at 55% and 57%; 1 at
  60%), so the slack doubles the spread the measured builds were fitted
  within: the pair is held on a pixel set strictly larger than the model
  allows. The tightest chip cell is about 9:1, so the bound is not what
  carries it.

  ## Fixtures come from the components

  Every slot above is read from a RENDER of the real component
  (`ChatMessage.chat_message/1`, `Overlays.message_actions_sheet/1`,
  `Overlays.message_attention_sheet/1`), queried with LazyHTML, never from a
  hand-written copy of the markup, so a class edit is followed and measured.
  The chat ground is read from the composer's scroller tag (as rung 9's
  guard does), and three CSS-side slots are pinned below.

  A failing pair is fixed by choosing another slot in the direction palette,
  never by an exemption: there is no exemption list in this file.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Platform.Agents.ColorPalette
  alias Platform.Design.PaintedComposite
  alias Platform.Design.PaintedMix
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.WcagContrast, as: W

  @root Path.expand("../../..", __DIR__)
  @app_css_path Path.join(@root, "assets/css/app.css")
  @presets_path Path.join(@root, "assets/css/theme_presets.css")
  @composer "lib/platform_web/live/chat/partials/composer.ex"

  @aa_text 4.5
  @aa_non_text 3.0
  @chip_slack 2

  @variants [
    {"burrow", "light"},
    {"burrow", "dark"},
    {"burrow-midnight", "light"},
    {"burrow-midnight", "dark"},
    {"burrow-sand", "light"},
    {"burrow-sand", "dark"},
    {"burrow-forest", "light"},
    {"burrow-forest", "dark"},
    {"high-contrast", "light"},
    {"high-contrast", "dark"}
  ]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/
  @pct_form ~r/^(\d+)%$/

  @viewer %{id: "p-viewer", name: "Viewer"}

  setup_all do
    app_css = File.read!(@app_css_path)
    presets = File.read!(@presets_path)

    by_key =
      Map.new(Blocks.preset_blocks(presets), &{{&1.id, &1.mode}, &1})
      |> Map.put({"burrow", "light"}, Blocks.burrow_block(app_css, "light"))
      |> Map.put({"burrow", "dark"}, Blocks.burrow_block(app_css, "dark"))

    blocks =
      for {id, mode} = key <- @variants do
        Map.get(by_key, key) || flunk("no #{id} #{mode} block")
      end

    composer = File.read!(Path.join(@root, @composer))

    {:ok,
     blocks: blocks,
     app_css: app_css,
     composer: composer,
     own_html: row_html("p-viewer"),
     others_html: row_html("p-other"),
     actions_html: actions_html(),
     picker_html: picker_html()}
  end

  # ── fixtures, rendered from the components ─────────────────────────────

  defp message(author_id) do
    %{
      id: "msg-1",
      space_id: "space-1",
      participant_id: author_id,
      content: "can someone look at the tab bar spacing?",
      content_type: "text",
      canvas_id: nil,
      inserted_at: ~U[2026-10-24 10:00:00.000000Z],
      day_label: nil,
      reactions: [],
      versions_count: 1,
      corrects_message_id: nil,
      metadata: %{},
      attention: [
        %{
          participant_id: "p-agent",
          participant_type: "agent",
          display_name: "Scout",
          added_by_participant_id: "p-viewer",
          added_by_display_name: "Viewer",
          inserted_at: ~U[2026-10-24 10:01:00.000000Z]
        }
      ]
    }
  end

  defp row_html(author_id) do
    assigns = %{msg: message(author_id), viewer: @viewer}

    rendered_to_string(~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-1"
      msg={@msg}
      current_participant={@viewer}
      agent_participant_ids={MapSet.new(["p-agent"])}
      participants_map={
        %{
          "p-viewer" => %{name: "Viewer", avatar_url: nil, avatar_seed: nil},
          "p-other" => %{name: "Other", avatar_url: nil, avatar_seed: nil}
        }
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

  defp actions_html do
    assigns = %{msg: message("p-viewer"), viewer: @viewer}

    rendered_to_string(~H"""
    <PlatformWeb.ChatLive.Partials.Overlays.message_actions_sheet
      open_message_actions_id="msg-1"
      open_message_actions_msg={@msg}
      current_participant={@viewer}
      quick_emojis={[]}
    />
    """)
  end

  defp picker_html do
    assigns = %{
      attention: %{
        message_id: "msg-1",
        own?: true,
        title: "Get someone's attention",
        preview: "can someone look at the tab bar spacing?",
        query: nil,
        suggestions: [
          %{
            name: "Scout",
            principal_id: "agent-1",
            participant_type: "agent",
            not_in_space: false
          },
          %{name: "Other", principal_id: "user-2", participant_type: "user", not_in_space: false}
        ],
        added: MapSet.new(["agent-1"])
      }
    }

    rendered_to_string(~H"""
    <PlatformWeb.ChatLive.Partials.Overlays.message_attention_sheet open_message_attention={
      @attention
    } />
    """)
  end

  # ── reading the rendered markup ────────────────────────────────────────

  defp nodes(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list()
  end

  defp node!(html, selector) do
    case nodes(html, selector) do
      [node | _] -> node
      [] -> flunk("the render has no #{selector}")
    end
  end

  defp classes(node) do
    node |> LazyHTML.attribute("class") |> Enum.flat_map(&String.split/1)
  end

  defp one(list, what) do
    assert length(list) == 1, "expected exactly one #{what}, got #{inspect(list)}"
    hd(list)
  end

  # The single unprefixed `<prefix><slot>` utility in a class list, so a
  # responsive or state variant (`lg:hover:bg-…`, `active:bg-…`) is not
  # mistaken for the rest paint.
  defp rest_slot(classes, prefix, what) do
    one(
      for(c <- classes, String.starts_with?(c, prefix), do: String.trim_leading(c, prefix)),
      what
    )
  end

  defp text_slot(classes, what) do
    case for("text-" <> s <- classes, s in ["subtle", "base-content"], do: s) do
      [s] ->
        s

      other ->
        flunk("#{what}: expected one text-subtle or text-base-content, got #{inspect(other)}")
    end
  end

  # The chip's one `text-<slot>` colour utility, whatever slot it names (the
  # size utilities are not colours), so a swap to any token is measured
  # rather than refused by name.
  @sizes ~w(xs sm base lg xl 2xl 3xl left right center)
  defp colour_text_slot(classes, what) do
    one(
      for("text-" <> v <- classes, v not in @sizes, not String.starts_with?(v, "["), do: v),
      what
    )
  end

  # `bg-<slot>/<n>`: the slot and its alpha percent.
  defp alpha_fill(classes, what) do
    case for("bg-" <> v <- classes, do: v) do
      [v] ->
        case String.split(v, "/") do
          [slot, pct] -> {slot, String.to_integer(pct)}
          [slot] -> {slot, 100}
        end

      other ->
        flunk("#{what}: expected one bg-* class, got #{inspect(other)}")
    end
  end

  defp code(source) do
    source
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, ""))
    |> then(&Regex.replace(~r/@(?:moduledoc|doc)\s+"""\n.*?\n\s*"""/s, &1, ""))
    |> then(&Regex.replace(~r/^\s*#.*$/m, &1, ""))
  end

  defp chat_ground(composer) do
    re =
      ~r/<[a-zA-Z.]+\b(?:(?!>)[\s\S])*?id="chat-message-scroller"(?:(?!>)[\s\S])*?>/

    tag = Regex.run(re, code(composer)) || flunk("no #chat-message-scroller tag")

    case Regex.run(~r/\bclass="([^"]+)"/, hd(tag)) do
      [_, cls] -> cls |> String.split() |> rest_slot("bg-", "chat ground")
      nil -> flunk("no static class on #chat-message-scroller")
    end
  end

  defp slots(ctx) do
    own_row = node!(ctx.own_html, "[data-message-id]")
    chip = node!(ctx.own_html, ~s([data-role="message-attention-chip"]))
    others_line = node!(ctx.others_html, ~s([data-role="message-attention"]))
    own_line = node!(ctx.own_html, ~s([data-role="message-attention"]))
    add = node!(ctx.own_html, ~s([data-role="message-add-attention"]))
    pill = node!(ctx.own_html, ~s([data-role="message-pill"]))
    pill_at = node!(ctx.own_html, ~s([data-role="message-pill-attention"]))
    popover = node!(ctx.actions_html, "#message-actions-popover")

    row =
      node!(
        ctx.actions_html,
        ~s(#message-actions-popover [data-role="message-actions-attention"])
      )

    glyph =
      node!(
        ctx.actions_html,
        ~s(#message-actions-popover [data-role="message-actions-attention"] > span[aria-hidden="true"])
      )

    meta =
      node!(
        ctx.actions_html,
        ~s(#message-actions-popover [data-role="message-actions-attention-meta"])
      )

    picker = node!(ctx.picker_html, "#message-attention-popover")

    added =
      node!(ctx.picker_html, ~s(#message-attention-popover [data-role="mention-list-added"]))

    assert nodes(ctx.others_html, ~s([data-role="message-add-attention"])) == [],
           "the add-someone button rendered on someone else's message"

    {chip_slot, chip_pct} = alpha_fill(classes(chip), "chip fill")
    {own_slot, own_pct} = alpha_fill(classes(own_row), "own row band")

    %{
      chat: chat_ground(ctx.composer),
      own_slot: own_slot,
      own_pct: own_pct,
      line_text: text_slot(classes(others_line), "added line"),
      own_line_text: text_slot(classes(own_line), "own added line"),
      chip_text: colour_text_slot(classes(chip), "chip text"),
      chip_slot: chip_slot,
      chip_pct: chip_pct,
      add_text: text_slot(classes(add), "add-someone text"),
      add_border: border_slot(classes(add)),
      pill: rest_slot(classes(pill), "bg-", "pill fill"),
      pill_glyph: text_slot(classes(pill_at), "pill +@"),
      popover: rest_slot(classes(popover), "bg-", "popover ground"),
      row_text: text_slot(classes(row), "attention row"),
      glyph: text_slot(classes(glyph), "@+ glyph"),
      meta: text_slot(classes(meta), "meta"),
      picker: rest_slot(classes(picker), "bg-", "picker ground"),
      added_class: one(classes(added), "added label class")
    }
  end

  # `border border-dashed border-edge`: the colour utility is the one that is
  # neither the width nor the style.
  defp border_slot(classes) do
    one(
      for("border-" <> v <- classes, v not in ~w(dashed solid dotted), do: v),
      "add-someone border colour"
    )
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: Blocks.resolve!(b, token)
  # `--color-edge` is mapped once, in app.css's @theme, to the per-block
  # `--edge` (pinned below); the blocks declare `--edge` only.
  defp tok("edge"), do: "--edge"
  defp tok(slot), do: "--color-#{slot}"
  defp bytes(color), do: PaintedComposite.bytes(color)
  defp px(rgb), do: PaintedComposite.from_bytes(rgb)

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  # Every pixel the four formulas paint for `ink` at `p`% over `ground`,
  # channel by channel (a pixel may take different formulas per channel),
  # widened by `slack` levels either way.
  defp alpha_pixels(ink, ground, p, slack) do
    {ir, ig, ib} = bytes_of(ink)
    {gr, gg, gb} = bytes_of(ground)

    ch = fn i, g ->
      for(
        f <- PaintedComposite.formulas(),
        do: elem(PaintedComposite.paint(f, {i, 0, 0}, {g, 0, 0}, p), 0)
      )
      |> Enum.flat_map(fn v -> Enum.to_list(max(v - slack, 0)..min(v + slack, 255)) end)
      |> Enum.uniq()
    end

    for r <- ch.(ir, gr), g <- ch.(ig, gg), bl <- ch.(ib, gb), do: {r, g, bl}
  end

  defp bytes_of({_, _, _} = rgb) when is_integer(elem(rgb, 0)), do: rgb
  defp bytes_of(color), do: bytes(color)

  defp ag_pct(b) do
    value =
      Blocks.declaration(b.decls, "--ag-tint-pct") || flunk("#{b.id} #{b.mode}: no --ag-tint-pct")

    case Regex.run(@pct_form, value) do
      [_, pct] -> String.to_integer(pct)
      nil -> flunk("#{b.id} #{b.mode}: --ag-tint-pct is #{inspect(value)}")
    end
  end

  # Every band the added line can sit on: name => candidate 8-bit pixels.
  defp bands(b, s) do
    chat = bytes(c(b, tok(s.chat)))

    own =
      alpha_pixels(c(b, tok(s.own_slot)), chat, s.own_pct, 0)

    agents =
      for id <- ColorPalette.ids() do
        {"agent #{id}",
         PaintedMix.painted!(
           bytes(c(b, "--ag-#{id}")),
           bytes(c(b, "--color-base-100")),
           ag_pct(b)
         )}
      end

    [{s.chat, [chat]}, {"own", own}, {"open", [bytes(c(b, "--color-base-300"))]}] ++ agents
  end

  # Ink in a text slot on any of `grounds` (8-bit pixels): `subtle` painted
  # alpha on its worst pixel, everything else opaque.
  defp text_min(b, "subtle", grounds) do
    grounds
    |> Enum.map(fn g ->
      {r, _} = PaintedComposite.contrast_min(c(b, "--color-base-content"), px(g), subtle_pct(b))
      r
    end)
    |> Enum.min()
  end

  defp text_min(b, ink, grounds) do
    i = c(b, tok(ink))
    grounds |> Enum.map(&W.contrast(i, px(&1))) |> Enum.min()
  end

  defp chip_min(b, s, grounds) do
    fill = c(b, tok(s.chip_slot))

    fills =
      grounds
      |> Enum.flat_map(&alpha_pixels(fill, &1, s.chip_pct, @chip_slack))
      |> Enum.uniq()

    text_min(b, s.chip_text, fills)
  end

  defp min_over(bands, names, fun) do
    bands
    |> Enum.filter(fn {name, _} -> names == :all or name in names end)
    |> Enum.map(fn {name, grounds} -> {name, fun.(grounds)} end)
    |> Enum.min_by(&elem(&1, 1))
  end

  defp pairs(b, s) do
    bands = bands(b, s)
    own_bands = ["own", "open"]
    sheet = [bytes(c(b, tok(s.popover)))]

    [
      {"line #{s.line_text}", min_over(bands, :all, &text_min(b, s.line_text, &1)), @aa_text},
      {"own line #{s.own_line_text}",
       min_over(bands, own_bands, &text_min(b, s.own_line_text, &1)), @aa_text},
      {"chip #{s.chip_text} / #{s.chip_slot}/#{s.chip_pct}",
       min_over(bands, :all, &chip_min(b, s, &1)), @aa_text},
      {"add #{s.add_text}", min_over(bands, own_bands, &text_min(b, s.add_text, &1)), @aa_text},
      {"add border #{s.add_border}", min_over(bands, own_bands, &text_min(b, s.add_border, &1)),
       @aa_non_text},
      {"pill +@ #{s.pill_glyph} / #{s.pill}",
       {s.pill, text_min(b, s.pill_glyph, [bytes(c(b, tok(s.pill)))])}, @aa_text},
      {"row label #{s.row_text} / #{s.popover}", {s.popover, text_min(b, s.row_text, sheet)},
       @aa_text},
      {"@+ glyph #{s.glyph} / #{s.popover}", {s.popover, text_min(b, s.glyph, sheet)}, @aa_text},
      {"meta #{s.meta} / #{s.popover}", {s.popover, text_min(b, s.meta, sheet)}, @aa_text},
      {"added subtle / #{s.picker}",
       {s.picker, text_min(b, "subtle", [bytes(c(b, tok(s.picker)))])}, @aa_text}
    ]
  end

  defp f2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor on every band in all ten variants; the table prints",
       ctx do
    assert length(ctx.blocks) == 10
    s = slots(ctx)
    rows = for b <- ctx.blocks, do: {b, pairs(b, s)}
    first = rows |> hd() |> elem(1)

    IO.puts(
      "\nGet someone's attention AA table (min over bands; worst band in brackets):\n" <>
        "| Variant | " <>
        Enum.map_join(first, " | ", &elem(&1, 0)) <>
        " |\n| floor | " <>
        Enum.map_join(first, " | ", &f2(elem(&1, 2))) <>
        " |\n|---|" <>
        String.duplicate("---|", length(first)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <>
            Enum.map_join(ps, " | ", fn {_, {band, r}, _} -> "#{f2(r)} [#{band}]" end) <> " |"
        end) <>
        "\n" <>
        Enum.map_join(first |> Enum.with_index(), "\n", fn {{label, _, _}, i} ->
          {b, {band, r}} =
            rows
            |> Enum.map(fn {b, ps} -> {b, ps |> Enum.at(i) |> elem(1)} end)
            |> Enum.min_by(fn {_, {_, r}} -> r end)

          "min #{label}: #{f2(r)} (#{b.id} #{b.mode}, #{band})"
        end)
    )

    failures =
      for {b, ps} <- rows, {label, {band, r}, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} on #{band} #{f2(r)} < #{floor}"
      end

    assert failures == []
  end

  test "the slots read from the render are the direction palette's", ctx do
    s = slots(ctx)
    assert s.chat == "base-100"
    assert {s.own_slot, s.own_pct} == {"base-200", 60}
    assert s.line_text == "subtle"
    assert s.own_line_text == "subtle"
    assert s.chip_text == "base-content"
    assert {s.chip_slot, s.chip_pct} == {"primary", 15}
    assert s.add_text == "subtle"
    assert s.add_border == "subtle"
    assert s.pill == "base-300"
    assert s.pill_glyph == "subtle"
    assert s.popover == "base-100"
    assert s.row_text == "base-content"
    assert s.glyph == "subtle"
    assert s.meta == "subtle"
    assert s.picker == "base-100"
    assert s.added_class == "mention-list-added"
  end

  test "the grounds and colours the guard takes on trust from CSS are what it says",
       %{app_css: css} do
    # An open pill raises the row's inner band to base-300 (opaque).
    assert css =~
             ~r/\[data-pill-open\] > \.message-row-inner\s*\{[^}]*background-color:\s*var\(--color-base-300\)/

    # The phone sheet's panel paints base-100, the popover's slot.
    assert css =~ ~r/\.sheet-panel\s*\{[^}]*background:\s*var\(--color-base-100\)/
    # The picker's "added" label paints --subtle, and the pick-mode panel is
    # transparent, so it sits on the sheet / popover ground.
    assert css =~ ~r/\.mention-list-added\s*\{[^}]*color:\s*var\(--color-subtle\)/
    assert css =~ ~r/\.mention-list--pick \.mention-list-panel\s*\{[^}]*background:\s*transparent/
    # `border-edge` is the per-block `--edge`.
    assert css =~ ~r/--color-edge:\s*var\(--edge\);/
    # An agent row paints its slot's opaque tint.
    assert css =~ ~r/\.msg-agent\s*\{[^}]*background:\s*var\(--ag-tint\)/
  end

  test "the chip's alpha band is wider than every formula's disagreement (anti-vacuity)" do
    # The slack-free envelope at 15% is a strict subset of the guarded set,
    # and the guarded set is not a single pixel.
    ink = {200, 80, 20}
    ground = {250, 248, 245}
    tight = alpha_pixels(ink, ground, 15, 0)
    wide = alpha_pixels(ink, ground, 15, @chip_slack)
    assert tight -- wide == []
    assert length(wide) > length(tight)
  end
end

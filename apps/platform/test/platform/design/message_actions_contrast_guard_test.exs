defmodule Platform.Design.MessageActionsContrastGuardTest do
  @moduledoc """
  Holds the paint of redesign rung 9's message actions (task 01a1557a-9406
  stage 4: the tap pill, the 'Message' sheet and ⋯ popover, reaction pills,
  the thread chip, the version-history diff and the Delete icon) in all ten
  preset variants (Burrow, Midnight, Sand, Forest, High contrast; light and
  dark), with NO exemption.

  ## Pairs and floors

  | pair                                                              | floor |
  |-------------------------------------------------------------------|-------|
  | pill glyph: --subtle on the pill fill (painted)                   | 4.5   |
  | sheet / popover row: base-content on the popover ground           | 4.5   |
  | sheet / popover meta: --subtle on the popover ground (painted)    | 4.5   |
  | reaction pill text: base-content on the not-mine fill             | 4.5   |
  | reaction pill text: base-content on the mine fill                 | 4.5   |
  | mine outline: its border slot against the mine fill (non-text)    | 3     |
  | thread chip: --subtle on the chat ground (painted)                | 4.5   |
  | `del`: its text slot on the version-history ground (painted)      | 4.5   |
  | `ins`: its text slot on its own fill                              | 4.5   |
  | Delete icon: its fill slot on the popover ground (non-text)       | 3     |

  The guard does not assume the slots. It reads each from the markup that
  paints it: the pill's `bg-*`, the popover's `bg-*`, the reaction pill's
  mine / not-mine `bg-*` and `border-*`, the chat scroller's `bg-*`, the
  `del` and `ins` classes, and the Delete icon's `bg-*`. A slot edit is
  followed and measured, never assumed. The phone sheet paints the shared
  `.sheet-panel` ground, base-100, the same slot as the popover (pinned
  below), so one pair covers both frames. The thread chip's colour is
  `.thread-indicator`'s `var(--color-subtle)` in app.css (pinned below).

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, alpha
  over the ground, so every pair it is in is PAINTED (the worst pixel
  `Platform.Design.PaintedComposite` allows). Every other token is opaque and
  measured with `WcagContrast.contrast/2`. The table prints.

  A failing pair is fixed by choosing another slot in the direction palette
  (canvas 01a1666e node m1), never by an exemption: there is no exemption
  list in this file, and a pair that cannot pass in some variant is reported.

  ## The class scan

  Over chat_message.ex, overlays.ex, message_context.ex,
  chat_version_history.ex, message_actions_hooks.ex, and rung 12's
  message_attention_hooks.ex and mention_list.ex (the attention picker's
  rows; its paint is held by message_attention_contrast_guard_test.exs),
  with comments and
  docs stripped (they may NAME what is forbidden): no `hover:` outside
  `lg:hover:`, no `text-base-content/`, no `text-error`, and no `primary` in
  the pill, reaction pill or quick-strip markup.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.ThemeBlocks, as: Blocks

  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @root Path.expand("../../..", __DIR__)
  @app_css_path Path.join(@root, "assets/css/app.css")
  @presets_path Path.join(@root, "assets/css/theme_presets.css")

  @chat_message "lib/platform_web/components/chat_message.ex"
  @overlays "lib/platform_web/live/chat/partials/overlays.ex"
  @message_context "lib/platform_web/live/chat/partials/message_context.ex"
  @version_history "lib/platform_web/components/chat_version_history.ex"
  @actions_hooks "lib/platform_web/live/chat/message_actions_hooks.ex"
  @composer "lib/platform_web/live/chat/partials/composer.ex"
  @attention_hooks "lib/platform_web/live/chat/message_attention_hooks.ex"
  @mention_list "lib/platform_web/live/chat/partials/mention_list.ex"

  @scanned [
    @chat_message,
    @overlays,
    @message_context,
    @version_history,
    @actions_hooks,
    @attention_hooks,
    @mention_list
  ]

  @aa_text 4.5
  @aa_non_text 3.0

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

    sources = Map.new(@scanned ++ [@composer], &{&1, File.read!(Path.join(@root, &1))})

    {:ok, blocks: blocks, sources: sources, app_css: app_css}
  end

  # ── source reading ─────────────────────────────────────────────────────

  # The first opening tag (element or component) whose attributes contain
  # `marker`.
  defp tag_with(source, marker) do
    re = ~r/<[a-zA-Z.]+\b(?:(?!>)[\s\S])*?#{Regex.escape(marker)}(?:(?!>)[\s\S])*?>/

    case Regex.run(re, source) do
      [tag] -> tag
      nil -> flunk("no tag carrying #{marker}")
    end
  end

  defp static_classes(tag) do
    case Regex.run(~r/\bclass="([^"]+)"/, tag) do
      [_, classes] -> String.split(classes, ~r/\s+/, trim: true)
      nil -> flunk("no static class attribute in #{tag}")
    end
  end

  defp one(list, what) do
    assert length(list) == 1, "expected exactly one #{what}, got #{inspect(list)}"
    hd(list)
  end

  defp prefixed(classes, prefix, what) do
    one(
      for(c <- classes, String.starts_with?(c, prefix), do: String.trim_leading(c, prefix)),
      what
    )
  end

  # The reaction pill's two class strings, `do:` (mine) and `else:` (not mine).
  defp reaction_classes(source) do
    case Regex.run(
           ~r/if\(r\.reacted_by_me,\s*do: "([^"]+)",\s*else: "([^"]+)"\s*\)/,
           source
         ) do
      [_, mine, theirs] -> {String.split(mine), String.split(theirs)}
      nil -> flunk("chat_message.ex: the reaction pill's mine / not-mine classes moved")
    end
  end

  defp element_classes(source, element) do
    case Regex.run(~r/<#{element}\b[^>]*?\bclass="([^"]+)"/, source) do
      [_, classes] -> String.split(classes)
      nil -> flunk("no <#{element} class=...> in chat_version_history.ex")
    end
  end

  defp text_slot(classes, what) do
    case for("text-" <> s <- classes, s in ["subtle", "base-content"], do: s) do
      [s] ->
        s

      other ->
        flunk("#{what}: expected one text-subtle or text-base-content, got #{inspect(other)}")
    end
  end

  # Read from code only, so a tag quoted in a moduledoc is never mistaken
  # for the markup.
  defp slots(src) do
    cm = code(src[@chat_message])
    ov = code(src[@overlays])
    vh = code(src[@version_history])
    {mine, theirs} = reaction_classes(cm)

    %{
      pill:
        cm
        |> tag_with(~s(data-role="message-pill"))
        |> static_classes()
        |> prefixed("bg-", "pill fill"),
      popover:
        ov
        |> tag_with(~s(id="message-actions-popover"))
        |> static_classes()
        |> prefixed("bg-", "popover ground"),
      not_mine: prefixed(theirs, "bg-", "not-mine fill"),
      mine: prefixed(mine, "bg-", "mine fill"),
      mine_border: prefixed(mine, "border-", "mine border"),
      chat:
        src[@composer]
        |> code()
        |> tag_with(~s(id="chat-message-scroller"))
        |> static_classes()
        |> prefixed("bg-", "chat ground"),
      vh_ground:
        vh
        |> tag_with(~s(id="version-history-popover"))
        |> static_classes()
        |> prefixed("bg-", "history ground"),
      del: vh |> element_classes("del") |> text_slot("del"),
      ins_text: vh |> element_classes("ins") |> text_slot("ins"),
      ins_fill: vh |> element_classes("ins") |> prefixed("bg-", "ins fill"),
      delete_icon:
        ov
        |> tag_with(~s(name="hero-trash"))
        |> static_classes()
        |> prefixed("bg-", "Delete icon fill")
    }
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)
  defp tok(slot), do: "--color-#{slot}"

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  # Ink in a text slot: `subtle` is painted alpha, everything else opaque.
  defp ratio(b, "subtle", ground) do
    {r, _} =
      PaintedComposite.contrast_min(
        c(b, "--color-base-content"),
        c(b, tok(ground)),
        subtle_pct(b)
      )

    r
  end

  defp ratio(b, ink, ground), do: W.contrast(c(b, tok(ink)), c(b, tok(ground)))

  defp pairs(b, s) do
    [
      {"pill glyph subtle / #{s.pill}", ratio(b, "subtle", s.pill), @aa_text},
      {"row base-content / #{s.popover}", ratio(b, "base-content", s.popover), @aa_text},
      {"meta subtle / #{s.popover}", ratio(b, "subtle", s.popover), @aa_text},
      {"reaction base-content / #{s.not_mine}", ratio(b, "base-content", s.not_mine), @aa_text},
      {"reaction base-content / #{s.mine}", ratio(b, "base-content", s.mine), @aa_text},
      {"mine border #{s.mine_border} / #{s.mine}", ratio(b, s.mine_border, s.mine), @aa_non_text},
      {"chip subtle / #{s.chat}", ratio(b, "subtle", s.chat), @aa_text},
      {"del #{s.del} / #{s.vh_ground}", ratio(b, s.del, s.vh_ground), @aa_text},
      {"ins #{s.ins_text} / #{s.ins_fill}", ratio(b, s.ins_text, s.ins_fill), @aa_text},
      {"Delete icon #{s.delete_icon} / #{s.popover}", ratio(b, s.delete_icon, s.popover),
       @aa_non_text}
    ]
  end

  defp f2(r), do: :erlang.float_to_binary(r / 1, decimals: 2)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants, with no exemption; the table prints",
       %{blocks: blocks, sources: src} do
    assert length(blocks) == 10
    s = slots(src)
    rows = for b <- blocks, do: {b, pairs(b, s)}
    first = rows |> hd() |> elem(1)

    IO.puts(
      "\nMessage actions AA table (WCAG 2.x; subtle rows painted on the worst pixel):\n" <>
        "| Variant | " <>
        Enum.map_join(first, " | ", &elem(&1, 0)) <>
        " |\n| floor | " <>
        Enum.map_join(first, " | ", &f2(elem(&1, 2))) <>
        " |\n|---|" <>
        String.duplicate("---|", length(first)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", &f2(elem(&1, 1))) <> " |"
        end) <>
        "\n" <>
        (for({b, ps} <- rows, {label, r, _} <- ps, do: {label, b, r})
         |> Enum.min_by(&elem(&1, 2))
         |> then(fn {label, b, r} -> "tightest: #{label} #{f2(r)} (#{b.id} #{b.mode})" end))
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f2(r)} < #{floor}"
      end

    assert failures == []
  end

  test "the slots read from source are the direction palette's", %{sources: src} do
    s = slots(src)
    assert s.pill == "base-300"
    assert s.popover == "base-100"
    assert s.not_mine == "base-200"
    assert s.mine == "base-300"
    assert s.mine_border == "base-content"
    assert s.chat == "base-100"
    assert s.vh_ground == "base-100"
    assert s.del == "subtle"
    assert {s.ins_text, s.ins_fill} == {"base-content", "base-300"}
    assert s.delete_icon == "error"
  end

  test "the grounds the guard takes on trust from CSS are what it says", %{app_css: css} do
    # The phone sheet's panel paints base-100 by default (the popover's slot).
    assert css =~ ~r/\.sheet-panel\s*\{[^}]*background:\s*var\(--color-base-100\)/
    # The thread chip paints --subtle.
    assert css =~ ~r/\.thread-indicator\s*\{[^}]*color:\s*var\(--color-subtle\)/
  end

  # ── class scan ─────────────────────────────────────────────────────────

  # Code only: HEEx comments, @moduledoc / @doc heredocs and `#` comment
  # lines may name what this scan forbids.
  defp code(source) do
    source
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, ""))
    |> then(&Regex.replace(~r/@(?:moduledoc|doc)\s+"""\n.*?\n\s*"""/s, &1, ""))
    |> then(&Regex.replace(~r/^\s*#.*$/m, &1, ""))
  end

  test "the scan reads real markup (anti-vacuity)", %{sources: src} do
    for path <- @scanned, do: assert(byte_size(src[path]) > 0, path)
    cm = code(src[@chat_message])
    # Positive controls: each forbidden pattern's allowed neighbour is here.
    assert cm =~ "lg:hover:"
    assert cm =~ "text-base-content"
    assert code(src[@overlays]) =~ "bg-error"
    assert code(src[@version_history]) =~ "<del"
  end

  test "no hover: outside lg:hover:, no text-base-content/, no text-error", %{sources: src} do
    hits =
      for path <- @scanned,
          {line, n} <- src[path] |> code() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(~r/(?<!lg:)\bhover:|text-base-content\/|text-error/, line),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == []
  end

  test "no primary in the pill, the reaction pill or the quick strip", %{sources: src} do
    cm = code(src[@chat_message])
    ov = code(src[@overlays])

    pill =
      case Regex.run(~r/defp message_pill\(assigns\) do.*?\n  end\n/s, cm) do
        [body] -> body
        nil -> flunk("message_pill/1 moved")
      end

    reaction =
      case Regex.run(~r/<button\s[^>]*?data-role="reaction-pill".*?<\/button>/s, cm) do
        [body] -> body
        nil -> flunk("the reaction pill moved")
      end

    strip =
      case Regex.run(~r/-quick-reactions"}.*?<\/div>/s, ov) do
        [body] -> body
        nil -> flunk("the quick strip moved")
      end

    for {name, markup} <- [pill: pill, reaction: reaction, strip: strip] do
      assert markup =~ "class=", "#{name}: no markup read"
      refute markup =~ "primary", "#{name} uses primary"
    end
  end
end

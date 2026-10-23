defmodule Platform.Design.ChatListContrastGuardTest do
  @moduledoc """
  Holds the phone Chat list's paint (task 01a1557a-8562 stage 2) in all ten
  variants (Burrow, Midnight, Sand, Forest, High contrast; light and dark).

  The grounds follow Saru's ruling (canvas 01a15d7c, node `ground`): the list
  is base-200, a pressed row is base-100, and the notification banner lifts
  off the list on base-100 with `border-edge`. The banner border carries no
  floor: the banner is not a control, and its button draws its own boundary.

  ## Pairs and floors

  | pair                                              | floor |
  |---------------------------------------------------|-------|
  | row name: base-content on base-200 (rest)         | 4.5   |
  | row name: base-content on base-100 (pressed)      | 4.5   |
  | time / excerpt: --subtle on base-200 (painted)    | 4.5   |
  | time / excerpt: --subtle on base-100 (painted)    | 4.5   |
  | unread dot: primary on base-200                   | 3     |
  | unread dot: primary on base-100 (pressed)         | 3     |
  | button text: primary-content on primary           | 4.5   |
  | banner title: base-content on base-100            | 4.5   |
  | banner subtitle: --subtle on base-100 (painted)   | 4.5   |
  | switch track on: primary on base-100 (stage 3)    | 3     |
  | search snippet: --subtle on base-100 (painted)    | 4.5   |
  | sheet row pressed: base-content on base-200       | 4.5   |
  | sheet handle: --subtle on base-100 (painted)      | 3     |
  | move arrow (enabled): base-content on base-200    | 3     |
  | move arrow (disabled): disabled token             | exempt (inactive control) |
  | avatar initial: base-content on base-300          | 4.5   |

  The last row is not in the stage's list. The avatar is `aria-hidden` and
  the name beside it carries the row, so it is measured as the inventory's
  "base-300 disc + base-content" token pair and asserted at the text floor
  because the glyph is text.

  `--subtle` is alpha over its ground, so its pairs are PAINTED on the worst
  pixel `Platform.Design.PaintedComposite` allows, as rung 5's More sheet
  guard does. Every other token is opaque and measured with
  `WcagContrast.contrast/2`. The table prints.

  ## Structure (anti-vacuity first)

  The list's app.css rules (the row's `[data-role="chat-list-row"]` touch rule and
  the sheets' rules) are SLICED and asserted
  non-empty before its body is read. The component source is read for the
  token classes the pairs above assume, so a markup change that moves a
  ground cannot leave this table measuring the old one.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @component_path Path.expand(
                    "../../../lib/platform_web/live/chat/partials/chat_list.ex",
                    __DIR__
                  )

  @aa_text 4.5
  @non_text 3.0

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

  @colour_literal ~r/#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\boklch\(|\boklab\(|\blab\(|\blch\(|\bhwb\(/

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

    all_rules = CssRules.rules(app_css)
    list_rules = Enum.filter(all_rules, &String.contains?(&1.selector, "chat-list"))

    {:ok,
     blocks: blocks, rules: list_rules, all_rules: all_rules, source: File.read!(@component_path)}
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: Blocks.resolve!(b, token)
  defp ratio(b, ink, ground), do: W.contrast(c(b, ink), c(b, ground))

  defp subtle_pct(b) do
    value = Blocks.declaration(b.decls, "--subtle") || flunk("#{b.id} #{b.mode}: no --subtle")

    case Regex.run(@subtle_form, value) do
      [_, pct] ->
        String.to_integer(pct)

      nil ->
        flunk("#{b.id} #{b.mode}: --subtle is #{inspect(value)}; teach the guard to paint it")
    end
  end

  defp subtle_on(b, ground) do
    {r, _} =
      PaintedComposite.contrast_min(c(b, "--color-base-content"), c(b, ground), subtle_pct(b))

    r
  end

  defp pairs(b) do
    [
      {"name / base-200", ratio(b, "--color-base-content", "--color-base-200"), @aa_text},
      {"name / base-100 (pressed)", ratio(b, "--color-base-content", "--color-base-100"),
       @aa_text},
      {"subtle / base-200 (painted)", subtle_on(b, "--color-base-200"), @aa_text},
      {"subtle / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      {"dot / base-200", ratio(b, "--color-primary", "--color-base-200"), @non_text},
      {"dot / base-100 (pressed)", ratio(b, "--color-primary", "--color-base-100"), @non_text},
      {"primary-content / primary", ratio(b, "--color-primary-content", "--color-primary"),
       @aa_text},
      {"banner title / base-100", ratio(b, "--color-base-content", "--color-base-100"), @aa_text},
      {"banner subtitle / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      # Stage 3, the sheets (base-100 surface, pressed rows on base-200).
      {"switch track on: primary / base-100", ratio(b, "--color-primary", "--color-base-100"),
       @non_text},
      {"search snippet: subtle / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      {"sheet label pressed: base-content / base-200",
       ratio(b, "--color-base-content", "--color-base-200"), @aa_text},
      {"sheet handle: subtle / base-100 (painted)", subtle_on(b, "--color-base-100"), @non_text},
      # Stage 4: Edit order's ↑/↓ while enabled. Disabled ones paint the
      # disabled token and are exempt (WCAG 1.4.3/1.4.11 exempt inactive
      # controls), so they are not measured here.
      {"move arrow enabled: base-content / base-200",
       ratio(b, "--color-base-content", "--color-base-200"), @non_text},
      {"avatar initial / base-300", ratio(b, "--color-base-content", "--color-base-300"),
       @aa_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints", %{blocks: blocks} do
    assert length(blocks) == 10

    rows = for b <- blocks, do: {b, pairs(b)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nChat list AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "the list's one app.css rule is sliced, non-empty and colour-free", %{rules: rules} do
    assert [row] =
             Enum.filter(rules, &(&1.selector == ~s([data-role="chat-list-row"]) and &1.at == []))

    assert String.trim(row.body) != ""
    assert row.body =~ ~r/-webkit-touch-callout:\s*none;/
    assert row.body =~ ~r/user-select:\s*none;/

    offenders = for r <- rules, Regex.match?(@colour_literal, r.body), do: r.selector
    assert offenders == []
  end

  test "the sheets' rules: subtle handle, weight-only match, full-height search",
       %{rules: rules} do
    expected =
      MapSet.new([
        ~s([data-role="chat-list-row"]),
        ".chat-list-sheet .sheet-handle",
        ".chat-list-search-sheet .sheet-panel",
        ".chat-list-search-sheet mark",
        ~s(.chat-list-search-sheet input[type="search"]::-webkit-search-cancel-button),
        # The pending current bar (task 01a166be-b5b9 stage 2, nav_pending.js).
        ".chat-list-row[data-nav-pending]",
        ".chat-list-row[data-nav-pending]::before"
      ])

    # Sliced and non-empty before any body is read.
    assert MapSet.new(rules, & &1.selector) == expected
    assert Enum.all?(rules, &(String.trim(&1.body) != ""))

    [handle] = Enum.filter(rules, &(&1.selector == ".chat-list-sheet .sheet-handle"))
    assert handle.body =~ ~r/background:\s*var\(--color-subtle\);/

    [mark] = Enum.filter(rules, &(&1.selector == ".chat-list-search-sheet mark"))
    assert mark.body =~ ~r/background:\s*transparent;/
    assert mark.body =~ ~r/color:\s*inherit;/
    assert mark.body =~ ~r/font-weight:\s*500;/

    [panel] = Enum.filter(rules, &(&1.selector == ".chat-list-search-sheet .sheet-panel"))
    assert panel.body =~ ~r/min-height:\s*85dvh;/
  end

  test "no chat-list selector is qualified by data-theme", %{all_rules: all} do
    # Positive control: the reader sees the list's selector at all.
    assert Enum.any?(all, &String.contains?(&1.selector, "chat-list"))

    offenders =
      for r <- all,
          String.contains?(r.selector, "chat-list"),
          String.contains?(r.selector, "data-theme"),
          do: r.selector

    assert offenders == []
  end

  test "the component paints the grounds this table measures", %{source: src} do
    # Each class is asserted present before anything is refuted, so an empty
    # or moved source fails here rather than passing every refute below.
    assert src =~ ~s(id="chat-list")
    assert src =~ "flex-col bg-base-200 text-base-content lg:hidden"
    assert src =~ "active:bg-base-100"
    assert src =~ "border border-edge bg-base-100"
    assert src =~ "bg-primary"
    assert src =~ "rounded-full bg-base-300"
    assert src =~ "active:bg-base-200"
    # Edit order's arrows: base-content enabled, the disabled token at a
    # group's end, and no hover.
    assert src =~
             ~S|if(@enabled?, do: "text-base-content active:bg-base-100", else: "text-disabled")|

    assert src =~ ~S|if(@on?, do: "bg-primary", else: "bg-base-300")|

    # No hover anywhere in the list, and no opacity-suffixed body colour.
    refute src =~ "hover:"
    refute src =~ ~r/text-base-content\/\d/
    refute src =~ "bg-info"
  end
end

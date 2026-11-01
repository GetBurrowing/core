defmodule Platform.Design.MoreSheetContrastGuardTest do
  @moduledoc """
  Holds the More sheet's paint (task 01a1557a-807f stage 3) in all ten preset
  variants (Burrow, Midnight, Sand, Forest, High contrast; light and dark).

  ## Pairs and floors

  | pair                                          | floor |
  |-----------------------------------------------|-------|
  | row label: base-content on base-100           | 4.5   |
  | hover label: base-content on base-200         | 4.5   |
  | pressed label: base-content on base-300       | 4.5   |
  | current bar: base-content on base-100         | 3     |
  | row icon on base-100, and on base-200         | 3     |
  | check icon on base-200                        | 3     |
  | Settings subtitle: --subtle on base-100, base-200 | 4.5 |
  | chevron: --subtle on base-100                 | 3     |
  | badge text: primary-content on primary        | 4.5   |
  | badge against the sheet: primary on base-100  | 3     |
  | drag handle: its paint on base-100            | 3     |

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, alpha
  over the ground, so every pair it is in is PAINTED, never derived: the worst
  pixel `Platform.Design.PaintedComposite` allows at the block's declared
  strength (the method rung 4 used for its glass). Every other token is opaque
  and measured with `WcagContrast.contrast/2`. The table prints.

  ## Hypotheses (planner estimates), with verdicts measured here

    * H-handle: Saru's handle token, base-300, is under 3:1 on base-100. The
      guard asserts it in every variant where the handle would otherwise be
      painted with it, so if a variant's base-300 ever clears 3:1 in all ten
      the override in app.css can go and this clause says so.
    * H-badge: primary-content on primary clears 4.5 in all ten (a floor
      assertion above).

  ## Structure (anti-vacuity first)

  Every `.more-sheet*` rule is SLICED with `Platform.Design.CssRules` and the
  expected selector set is asserted before any body is read. Then: no colour
  literal in any of those bodies; no `[data-theme...]`-qualified More sheet
  selector; the panel's height rule caps it at `100dvh - 48px` beside rung 4's
  `padding-bottom: var(--bottom-nav-clearance)`, so the visible sheet is
  `100dvh - 48px - var(--bottom-nav-clearance)`; the rise is 200ms and the
  shared reduced-motion rule still removes it; the handle is painted with
  `--color-subtle`.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  # Rung 3's shared reader (lib/platform/design/theme_blocks.ex), as the preset guard uses.
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)

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
    {"high-contrast", "dark"},
    {"sage", "light"},
    {"sage", "dark"}
  ]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  # Every `.more-sheet*` rule app.css declares, by {at, selector}. Rung 4's
  # z-order and padding rules are in this list too: they are the More sheet's.
  @expected_selectors MapSet.new([
                        {[], ":root:has(#more-sheet.sheet-open) .bottom-nav"},
                        {[], ".more-sheet .sheet-panel"},
                        {[], ".more-sheet-list"},
                        {[], ".more-sheet-row"},
                        {[], ".more-sheet-settings"},
                        {["@media (hover: hover)"], ".more-sheet-row:hover"},
                        {[], ".more-sheet-row:active"},
                        {["@media (hover: hover)"], ".more-sheet-settings:hover"},
                        {[], ".more-sheet-settings:active"},
                        {[], ".more-sheet-row--current"},
                        {[], ".more-sheet-row--current::before"},
                        {[], ".more-sheet-icon"},
                        {[], ".more-sheet-check"},
                        {[], ".more-sheet .sheet-actions"},
                        {[], ".more-sheet .sheet-handle"},
                        # Fit and scroll cue: the body's padding, the sticky
                        # cue and the opaque last row that covers it.
                        {[], ".more-sheet .sheet-body"},
                        {[], ".more-sheet-cue"},
                        {[], ".more-sheet-row:last-child"},
                        # Optimistic navigation (task 01a166be-b5b9 stage 2):
                        # the tapped row keeps base-300 and the sheet leaves.
                        {[], ".more-sheet-row[data-nav-pending]"},
                        {[], ".more-sheet-settings[data-nav-pending]"},
                        {[], ".more-sheet:has([data-nav-pending])"},
                        {[], ".more-sheet:has([data-nav-pending]) .sheet-panel"},
                        {[], ".more-sheet:has([data-nav-pending]) .sheet-backdrop"}
                      ])

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

    more_rules =
      app_css
      |> CssRules.rules()
      |> Enum.filter(&String.contains?(&1.selector, "more-sheet"))

    {:ok, blocks: blocks, rules: more_rules, all_rules: CssRules.rules(app_css)}
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)
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

  # --subtle painted over `ground`, on the worst pixel the measured formulas allow.
  defp subtle_on(b, ground) do
    {r, _} =
      PaintedComposite.contrast_min(c(b, "--color-base-content"), c(b, ground), subtle_pct(b))

    r
  end

  defp pairs(b) do
    [
      {"row label / base-100", ratio(b, "--color-base-content", "--color-base-100"), @aa_text},
      {"hover label / base-200", ratio(b, "--color-base-content", "--color-base-200"), @aa_text},
      {"pressed label / base-300", ratio(b, "--color-base-content", "--color-base-300"),
       @aa_text},
      {"current bar / base-100", ratio(b, "--color-base-content", "--color-base-100"), @non_text},
      {"icon / base-100", ratio(b, "--color-base-content", "--color-base-100"), @non_text},
      {"icon / base-200", ratio(b, "--color-base-content", "--color-base-200"), @non_text},
      {"check / base-100", ratio(b, "--color-base-content", "--color-base-100"), @non_text},
      {"subtitle / base-100 (painted)", subtle_on(b, "--color-base-100"), @aa_text},
      {"subtitle / base-200 (painted)", subtle_on(b, "--color-base-200"), @aa_text},
      {"chevron / base-100 (painted)", subtle_on(b, "--color-base-100"), @non_text},
      {"badge text / primary", ratio(b, "--color-primary-content", "--color-primary"), @aa_text},
      {"badge / base-100", ratio(b, "--color-primary", "--color-base-100"), @non_text},
      {"handle (subtle) / base-100 (painted)", subtle_on(b, "--color-base-100"), @non_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints", %{blocks: blocks} do
    assert length(blocks) == 12

    rows =
      for b <- blocks do
        {b, pairs(b)}
      end

    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nMore sheet AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " | base-300 / base-100 (H-handle) |\n" <>
        "|---|" <>
        String.duplicate("---|", length(labels) + 1) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <>
            Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <>
            " | " <> f4(ratio(b, "--color-base-300", "--color-base-100")) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "H-handle: base-300 on base-100 is under 3:1, so the handle may not use it",
       %{blocks: blocks} do
    ratios =
      for b <- blocks, do: {"#{b.id} #{b.mode}", ratio(b, "--color-base-300", "--color-base-100")}

    # The override stands only while base-300 fails somewhere. If every
    # variant cleared 3:1, Saru's base-300 would do and the override should go.
    assert Enum.any?(ratios, fn {_, r} -> r < @non_text end), inspect(ratios)
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "the More sheet's rules are exactly the expected set (sliced before read)",
       %{rules: rules} do
    got = MapSet.new(rules, &{&1.at, &1.selector})
    assert got == @expected_selectors
    assert Enum.all?(rules, &(String.trim(&1.body) != ""))
  end

  test "no More sheet rule body holds a colour literal", %{rules: rules} do
    assert length(rules) >= MapSet.size(@expected_selectors)

    offenders =
      for r <- rules, Regex.match?(@colour_literal, r.body), do: {r.selector, String.trim(r.body)}

    assert offenders == []
  end

  test "no More sheet selector is qualified by data-theme", %{all_rules: all} do
    offenders =
      for r <- all,
          String.contains?(r.selector, "more-sheet"),
          String.contains?(r.selector, "data-theme"),
          do: r.selector

    # Positive control: the reader does see More sheet selectors.
    assert Enum.any?(all, &String.contains?(&1.selector, "more-sheet"))
    assert offenders == []
  end

  test "the panel: height capped above the bar, 200ms rise, reduced motion removes it",
       %{rules: rules, all_rules: all} do
    # ONE panel rule: rung 4's clearance and this stage's cap live together
    # (bottom_nav_glass_guard_test.exs reads it as one rule too).
    [panel] = Enum.filter(rules, &(&1.selector == ".more-sheet .sheet-panel" and &1.at == []))
    body = panel.body

    # Rung 4's clearance: the panel ends under the bar and pads by it.
    assert body =~ ~r/padding-bottom:\s*var\(--bottom-nav-clearance\);/
    # So the whole (border-box) panel is capped at 100dvh - 48px, leaving
    # 100dvh - 48px - clearance visible above the bar.
    assert body =~ ~r/max-height:\s*calc\(100dvh - 48px\);/
    assert body =~ ~r/transition-duration:\s*200ms;/
    refute body =~ "!important"

    reduced =
      Enum.filter(
        all,
        &(&1.at == ["@media (prefers-reduced-motion: reduce)"] and &1.selector == ".sheet-panel")
      )

    assert [r] = reduced
    assert r.body =~ ~r/transition:\s*none\s*!important;/
  end

  # 44px, the touch-target floor: at 52px, then 48px, the list was taller
  # than an iPhone's visible sheet (more_sheet_test.exs, "fits an iPhone").
  test "the handle paints with --color-subtle; rows stay at least 44px", %{rules: rules} do
    [handle] = Enum.filter(rules, &(&1.selector == ".more-sheet .sheet-handle"))
    assert handle.body =~ ~r/background:\s*var\(--color-subtle\);/

    [row] = Enum.filter(rules, &(&1.selector == ".more-sheet-row"))
    [_, px] = Regex.run(~r/min-height:\s*(\d+)px;/, row.body)
    assert String.to_integer(px) >= 44
    assert row.body =~ ~r/font-size:\s*15px;/
    assert row.body =~ ~r/color:\s*var\(--color-base-content\);/
  end

  # Four states, never sharing a look (task 01a166be-b5b9, press feedback
  # canvas 01a167b0): until then hover, :active and current all painted
  # base-200. Now hover is base-200 behind (hover: hover), pressed is base-300
  # and current has NO fill: a 3px base-content leading bar plus weight 600.
  test "hover, pressed and current resolve to different declarations", %{rules: rules} do
    body = fn at, sel ->
      case Enum.filter(rules, &(&1.selector == sel and &1.at == at)) do
        [r] -> r.body
        other -> flunk("expected one #{inspect(at)} `#{sel}` rule, found #{length(other)}")
      end
    end

    fill = fn b ->
      case Regex.run(~r/background(?:-color)?:\s*([^;]+);/, b) do
        [_, v] -> String.trim(v)
        nil -> nil
      end
    end

    for {hover_sel, active_sel} <- [
          {".more-sheet-row:hover", ".more-sheet-row:active"},
          {".more-sheet-settings:hover", ".more-sheet-settings:active"}
        ] do
      hover = body.(["@media (hover: hover)"], hover_sel)
      pressed = body.([], active_sel)

      assert fill.(hover) == "var(--color-base-200)", hover_sel
      assert fill.(pressed) == "var(--color-base-300)", active_sel
      # Press-in is instant.
      assert pressed =~ ~r/transition-duration:\s*0ms;/
    end

    # No unconditional :hover anywhere on a row: on touch it sticks.
    refute Enum.any?(rules, &(&1.at == [] and &1.selector =~ ":hover"))

    current = body.([], ".more-sheet-row--current")
    assert fill.(current) == nil, "current must not be a fill: a fill always means touch"
    assert current =~ ~r/font-weight:\s*600;/

    bar = body.([], ".more-sheet-row--current::before")
    assert bar =~ ~r/width:\s*3px;/
    assert bar =~ ~r/left:\s*0;/
    assert fill.(bar) == "var(--color-base-content)"

    # And the three looks are pairwise distinct.
    looks = [
      fill.(body.(["@media (hover: hover)"], ".more-sheet-row:hover")),
      fill.(body.([], ".more-sheet-row:active")),
      fill.(current)
    ]

    assert looks == Enum.uniq(looks)
  end
end

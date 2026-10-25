defmodule Platform.Design.VoiceTabContrastGuardTest do
  @moduledoc """
  Holds the Voice tab's paint (task 01a1557a-eab7 stage 2) in all ten preset
  variants (Burrow, Midnight, Sand, Forest, High contrast; light and dark).

  ## Pairs and floors

  | pair                                                     | floor |
  |----------------------------------------------------------|-------|
  | pill label: base-content on base-100                     | 4.5   |
  | "in:" and the none label: --subtle on base-100           | 4.5   |
  | pill chevron: --subtle on base-100                       | 3     |
  | agent bubble text: base-content on the --ag tint, every slot | 4.5 |
  | bubble .from: --ag-<id>-text on the --ag tint, every slot | 4.5  |
  | avatar initial: base-content on the --ag tint, every slot | 4.5  |
  | agent bar / avatar ring: --ag-<id> on base-100           | 3     |
  | listen line: --subtle on base-200                        | 4.5   |
  | day note: --subtle on base-200                           | 4.5   |
  | mic glyph: base-content on base-100                      | 3     |
  | mic on-state glyph: primary-content on primary           | 3     |
  | mic idle edge: --subtle on base-200                      | 3     |
  | unreachable line: error on base-200                      | 4.5   |
  | sheet handle: --subtle on base-100                       | 3     |
  | listening ring: primary, painted opaque, on base-200 (stage 3) | 3 |
  | live bubble dashed edge: primary on base-100 (stage 3)   | 3     |
  | on-state glyph: primary-content on primary (stage 3)     | 3     |
  | popover row text: base-content on base-200 (stage 4)     | 4.5   |
  | popover row subtitle: --subtle on base-200 (stage 4)     | 4.5   |
  | pill focus outline: primary on base-100 (stage 4)        | 3     |
  | pill focus outline: primary on base-200, its ground (stage 4) | 3 |

  ## The lg popovers (stage 4)

  At lg the partner and context sheets are popovers (`.voice-popover`, under
  `@media (min-width: 1024px)`). A row hovers (`lg:hover:bg-base-200`) or is
  selected on base-200, so its text and subtitle are measured there. The
  pills' focus-visible ring is a 2px primary outline offset onto the header's
  base-200 ground, next to the pill's base-100 fill, so it is measured on
  both. The structure test holds that the popover panel's edge and surface
  are tokens and its backdrop is clear.

  ## The listening ring is opaque (a recorded deviation, stage 3)

  The masters ring the mic `.on` in primary at 15%. A 15% primary halo over
  base-200 cannot reach 3:1 against base-200 in any variant (the ring would
  read as no ring), so `.voice-mic.on` paints an OPAQUE 2px primary ring past
  a 3px base-200 gap. The structure test below holds that the ring is
  `var(--color-primary)` and not a mix, so its painted opacity is 100% and
  `WcagContrast.contrast/2` measures it exactly.

  `--subtle` is `color-mix(in oklab, base-content N%, transparent)`, alpha over
  the ground, so every pair it is in is PAINTED: the worst pixel
  `Platform.Design.PaintedComposite` allows at the block's declared strength.
  The `--ag` tint is an opaque srgb mix into base-100, measured on every pixel
  `Platform.Design.PaintedMix` allows at the block's `--ag-tint-pct`. Every
  other token is opaque and measured with `WcagContrast.contrast/2`.

  ## The mic edge is --subtle, not --edge (a recorded deviation)

  The masters draw the idle mic's 1px edge in `--edge`. `--edge` is a hairline
  colour and fails 3:1 on base-200 (H-edge, asserted below), and the edge is
  the only boundary the 96px control has against the ground (its base-100 fill
  is close to base-200 too). So the mic paints its edge with `--subtle`, as
  the members sheet did for the same reason.

  ## Structure

  Every `.voice-*` rule in app.css is SLICED with `Platform.Design.CssRules`
  and the expected selector set is asserted before any body is read: no colour
  literal in any body, no `[data-theme]` qualification, no unconditional
  `:hover`, and the agent surfaces read only the slot pointers `--ag`,
  `--ag-text` and `--ag-tint`.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.ColorPalette
  alias Platform.Design.CssRules
  alias Platform.Design.PaintedComposite
  alias Platform.Design.PaintedMix
  alias Platform.Design.ThemeBlocks, as: Blocks
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
    {"high-contrast", "dark"}
  ]

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/
  @pct_form ~r/^(\d+)%$/

  @expected_selectors MapSet.new([
                        {[], ".voice-avatar"},
                        {[], ".voice-bubble-agent"},
                        {[], ".voice-bubble-from"},
                        {[], ".voice-mic"},
                        {[], ".voice-sheet .sheet-handle"},
                        {[], ".voice-sheet .sheet-body"},
                        {[], ".voice-meter i"},
                        {[], ".voice-area[data-live] .voice-meter i"},
                        {[], ".voice-mic.on"},
                        {[], ".voice-bubble-live"},
                        {[], ".voice-caret"},
                        {[], ".voice-dots i"},
                        {[], ".voice-dots i:nth-child(2)"},
                        {[], ".voice-dots i:nth-child(3)"},
                        {["@media (prefers-reduced-motion: reduce)"], ".voice-caret"},
                        {["@media (prefers-reduced-motion: reduce)"], ".voice-dots i"},
                        {["@media (prefers-reduced-motion: reduce)"], ".voice-meter i"},
                        {["@media (min-width: 1024px)"], ".voice-popover"},
                        {["@media (min-width: 1024px)"], ".voice-popover[data-anchor=\"end\"]"},
                        {["@media (min-width: 1024px)"], ".voice-popover .sheet-backdrop"},
                        {["@media (min-width: 1024px)"], ".voice-popover .sheet-panel"},
                        {["@media (min-width: 1024px)"],
                         ".voice-popover.sheet-open .sheet-panel"},
                        {["@media (min-width: 1024px)"], ".voice-popover .sheet-handle-button"},
                        {["@media (min-width: 1024px)"], ".voice-popover .sheet-body"}
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

    all = CssRules.rules(app_css)
    voice = Enum.filter(all, &String.contains?(&1.selector, ".voice-"))

    {:ok, blocks: blocks, rules: voice, all_rules: all}
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: Blocks.resolve!(b, token)
  defp ratio(b, ink, ground), do: W.contrast(c(b, ink), c(b, ground))

  defp pct(b, token, form) do
    value = Blocks.declaration(b.decls, token) || flunk("#{b.id} #{b.mode}: no #{token}")

    case Regex.run(form, value) do
      [_, n] ->
        String.to_integer(n)

      nil ->
        flunk("#{b.id} #{b.mode}: #{token} is #{inspect(value)}; teach the guard to paint it")
    end
  end

  defp subtle_on(b, ground) do
    {r, _} =
      PaintedComposite.contrast_min(
        c(b, "--color-base-content"),
        c(b, ground),
        pct(b, "--subtle", @subtle_form)
      )

    r
  end

  # The worst slot for `ink` on the painted --ag tint of that slot.
  defp on_tint_worst(b, ink_for) do
    p = pct(b, "--ag-tint-pct", @pct_form)

    ColorPalette.ids()
    |> Enum.map(fn id ->
      PaintedMix.text_min(c(b, ink_for.(id)), c(b, "--ag-#{id}"), c(b, "--color-base-100"), p)
    end)
    |> Enum.min()
  end

  defp bar_worst(b) do
    ColorPalette.ids()
    |> Enum.map(&ratio(b, "--ag-#{&1}", "--color-base-100"))
    |> Enum.min()
  end

  defp pairs(b) do
    [
      {"pill label / base-100", ratio(b, "--color-base-content", "--color-base-100"), @aa_text},
      {"in: + none label (subtle) / base-100", subtle_on(b, "--color-base-100"), @aa_text},
      {"chevron (subtle) / base-100", subtle_on(b, "--color-base-100"), @non_text},
      {"bubble text / ag tint (worst slot)", on_tint_worst(b, fn _ -> "--color-base-content" end),
       @aa_text},
      {".from ag-text / ag tint (worst slot)", on_tint_worst(b, &"--ag-#{&1}-text"), @aa_text},
      {"avatar initial / ag tint (worst slot)",
       on_tint_worst(b, fn _ -> "--color-base-content" end), @aa_text},
      {"agent bar / base-100 (worst slot)", bar_worst(b), @non_text},
      {"listen line (subtle) / base-200", subtle_on(b, "--color-base-200"), @aa_text},
      {"day note (subtle) / base-200", subtle_on(b, "--color-base-200"), @aa_text},
      {"mic glyph / base-100", ratio(b, "--color-base-content", "--color-base-100"), @non_text},
      {"primary-content glyph / primary", ratio(b, "--color-primary-content", "--color-primary"),
       @non_text},
      {"mic idle edge (subtle) / base-200", subtle_on(b, "--color-base-200"), @non_text},
      {"error line / base-200", ratio(b, "--color-error", "--color-base-200"), @aa_text},
      {"sheet handle (subtle) / base-100", subtle_on(b, "--color-base-100"), @non_text},
      {"listening ring (primary, opaque) / base-200",
       ratio(b, "--color-primary", "--color-base-200"), @non_text},
      {"live bubble dashed edge (primary) / base-100",
       ratio(b, "--color-primary", "--color-base-100"), @non_text},
      {"on-state glyph (primary-content) / primary",
       ratio(b, "--color-primary-content", "--color-primary"), @non_text},
      {"popover row text / base-200", ratio(b, "--color-base-content", "--color-base-200"),
       @aa_text},
      {"popover row subtitle (subtle) / base-200", subtle_on(b, "--color-base-200"), @aa_text},
      {"pill focus outline (primary) / base-100", ratio(b, "--color-primary", "--color-base-100"),
       @non_text},
      {"pill focus outline (primary) / base-200", ratio(b, "--color-primary", "--color-base-200"),
       @non_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints", %{blocks: blocks} do
    assert length(blocks) == 10

    rows = for b <- blocks, do: {b, pairs(b)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    mins =
      for {label, i} <- Enum.with_index(labels) do
        {label, rows |> Enum.map(fn {_, ps} -> ps |> Enum.at(i) |> elem(1) end) |> Enum.min()}
      end

    IO.puts(
      "\nVoice tab AA table (WCAG 2.x; painted rows on the worst pixel allowed):\n" <>
        "| Variant | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | " <> Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <> " |"
        end) <>
        "\nMinima: " <> Enum.map_join(mins, "; ", fn {l, r} -> "#{l} #{f4(r)}" end)
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end

  test "H-edge: --edge fails 3:1 on base-200 somewhere, so the mic edge may not use it",
       %{blocks: blocks} do
    ratios = for b <- blocks, do: {"#{b.id} #{b.mode}", ratio(b, "--edge", "--color-base-200")}
    # If every variant cleared 3:1 the masters' --edge would do and the
    # deviation should be undone.
    assert Enum.any?(ratios, fn {_, r} -> r < @non_text end), inspect(ratios)
  end

  test "H-ring: the masters' 15% primary ring fails 3:1 on base-200 everywhere, so it is opaque",
       %{blocks: blocks} do
    # The BEST pixel any measured browser formula paints for primary at 15%
    # over base-200. If any variant cleared 3:1 the masters' ring would do
    # there and the deviation should be revisited.
    best =
      for b <- blocks do
        ground = PaintedComposite.bytes(c(b, "--color-base-200"))
        ink = PaintedComposite.bytes(c(b, "--color-primary"))

        PaintedComposite.formulas()
        |> Enum.map(fn f ->
          W.contrast(
            PaintedComposite.from_bytes(PaintedComposite.paint(f, ink, ground, 15)),
            PaintedComposite.from_bytes(ground)
          )
        end)
        |> Enum.max()
      end

    assert Enum.all?(best, &(&1 < @non_text)), inspect(best)
  end

  # ── structure ──────────────────────────────────────────────────────────

  test "the Voice tab's rules are exactly the expected set (sliced before read)",
       %{rules: rules} do
    assert MapSet.new(rules, &{&1.at, &1.selector}) == @expected_selectors
    assert Enum.all?(rules, &(String.trim(&1.body) != ""))
  end

  test "no Voice rule holds a colour literal, a data-theme qualifier or a bare :hover",
       %{rules: rules} do
    assert length(rules) >= MapSet.size(@expected_selectors)

    literals = for r <- rules, Regex.match?(@colour_literal, r.body), do: r.selector
    themed = for r <- rules, String.contains?(r.selector, "data-theme"), do: r.selector
    hovers = for r <- rules, String.contains?(r.selector, ":hover"), do: r.selector

    assert literals == []
    assert themed == []
    assert hovers == []
  end

  test "agent surfaces read only the slot pointers; the mic edge and handle are --subtle",
       %{rules: rules} do
    body = fn sel ->
      case Enum.filter(rules, &(&1.selector == sel and &1.at == [])) do
        [r] -> r.body
        other -> flunk("expected one `#{sel}` rule, found #{length(other)}")
      end
    end

    bubble = body.(".voice-bubble-agent")
    assert bubble =~ ~r/background:\s*var\(--ag-tint\);/
    assert bubble =~ ~r/border-left:\s*3px solid var\(--ag\);/

    assert body.(".voice-bubble-from") =~ ~r/color:\s*var\(--ag-text\);/

    avatar = body.(".voice-avatar")
    assert avatar =~ ~r/background:\s*var\(--ag-tint\);/
    assert avatar =~ ~r/var\(--ag\)/
    assert avatar =~ ~r/color:\s*var\(--color-base-content\);/

    assert body.(".voice-mic") =~ ~r/border:\s*1px solid var\(--color-subtle\);/

    # Stage 3: the ring is opaque primary (painted at 100%, what the pair
    # above measures), the live bubble's edge is dashed primary, and the
    # live meter is primary.
    ring = body.(".voice-mic.on")
    assert ring =~ ~r/0 0 0 5px var\(--color-primary\)/
    refute ring =~ "color-mix"
    assert body.(".voice-bubble-live") =~ ~r/border:\s*1px dashed var\(--color-primary\);/

    assert body.(".voice-area[data-live] .voice-meter i") =~
             ~r/background:\s*var\(--color-primary\);/

    assert body.(".voice-sheet .sheet-handle") =~ ~r/background:\s*var\(--color-subtle\);/
  end

  test "the lg popover: an --edge hairline, a clear backdrop, no handle", %{rules: rules} do
    lg = ["@media (min-width: 1024px)"]

    body = fn sel ->
      case Enum.filter(rules, &(&1.selector == sel and &1.at == lg)) do
        [r] -> r.body
        other -> flunk("expected one lg `#{sel}` rule, found #{length(other)}")
      end
    end

    panel = body.(".voice-popover .sheet-panel")
    assert panel =~ ~r/border:\s*1px solid var\(--color-edge\);/
    refute panel =~ "background"
    assert body.(".voice-popover .sheet-backdrop") =~ ~r/background:\s*transparent;/
    assert body.(".voice-popover .sheet-handle-button") =~ ~r/display:\s*none;/
  end
end

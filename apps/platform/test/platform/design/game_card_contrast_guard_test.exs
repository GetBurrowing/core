defmodule Platform.Design.GameCardContrastGuardTest do
  @moduledoc """
  Holds the Files browser's game cards (Burrow redesign rung 21, task
  01a1557a-efdd stage 1) in all ten preset variants (Burrow, Midnight, Sand,
  Forest, High contrast; light and dark).

  ## Pairs and floors

  | pair                                                         | floor |
  |--------------------------------------------------------------|-------|
  | playable tag: success-content on success                     | 4.5   |
  | draft tag: on-viewer on shade painted over the thumb's mix   | 4.5   |
  | build tag: on-viewer on shade painted over the thumb's mix   | 4.5   |
  | tile glyph: on-viewer on the thumb's mix                     | 3     |
  | list icon glyph: on-viewer on the list tile's mix            | 3     |

  "The mix" is `color-mix(in oklab, var(--stage) 70%, var(--ag-teal))`: the
  grid thumb's LIGHTEST gradient stop (its other stop is `--stage` itself,
  darker in every variant, asserted below) and the list tile's flat fill. It
  is opaque, so it is mixed with `WcagContrast.mix_oklab/3` and quantised to
  the 8-bit pixel it paints as.

  `--shade` is translucent black (`rgba(0, 0, 0, a)`), so the tags' ground is
  PAINTED: `Platform.Design.PaintedComposite.envelope/3`, the worst pixel any
  measured formula paints for the shade at its declared alpha over the mix.
  Note: PaintedComposite's corpus was painted at 55/57/60%; the shade is
  declared at 50% (70% in high contrast), so `contrast_min/3` refuses it and
  this guard calls `envelope/3` directly. The margins printed below are wide
  (black at half strength over a near-black stage), but the strength itself is
  unmeasured.

  ## Structure (anti-vacuity first)

  The two new rules (`.browser-thumb-game`, `.browser-icon-game`) are SLICED
  with `Platform.Design.CssRules`, the expected selector set is asserted, and
  their bodies are checked for the exact mix this guard measures and for no
  colour literal, before any ratio is read. The markup is checked to paint
  the tags and glyphs with the slots measured here.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.PaintedComposite
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @components_path Path.expand(
                     "../../../lib/platform_web/live/files/browser_components.ex",
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

  @expected_selectors MapSet.new([{[], ".browser-thumb-game"}, {[], ".browser-icon-game"}])

  @mix "color-mix(in oklab, var(--stage) 70%, var(--ag-teal))"

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

    rules =
      app_css
      |> CssRules.rules()
      |> Enum.filter(&(&1.selector =~ ~r/browser-(thumb|icon)-game/))

    {:ok, blocks: blocks, rules: rules, components: File.read!(@components_path)}
  end

  # ── measurement ────────────────────────────────────────────────────────

  defp c(b, token), do: ThemeBlockAssertions.resolve!(b, token)

  # The 8-bit pixel a colour paints as.
  defp px(color), do: W.hex(W.to_hex(color))

  defp mix(b), do: px(W.mix_oklab(c(b, "--stage"), 70, c(b, "--ag-teal")))

  defp shade_alpha_pct(b) do
    value = Blocks.declaration(b.decls, "--shade") || flunk("#{b.id} #{b.mode}: no --shade")

    case Regex.run(~r/^rgba\(\s*0,\s*0,\s*0,\s*([\d.]+)\s*\)$/, value) do
      [_, a] -> round(String.to_float(a) * 100)
      nil -> flunk("#{b.id} #{b.mode}: --shade is #{inspect(value)}; teach the guard to paint it")
    end
  end

  # on-viewer text on the shade painted over the mix, on the worst pixel.
  defp on_shade_over_mix(b) do
    ground = PaintedComposite.bytes(mix(b))
    painted = PaintedComposite.envelope({0, 0, 0}, ground, shade_alpha_pct(b))
    W.contrast(c(b, "--on-viewer"), PaintedComposite.from_bytes(painted))
  end

  defp pairs(b) do
    on_mix = W.contrast(c(b, "--on-viewer"), mix(b))
    on_shade = on_shade_over_mix(b)

    [
      {"playable: success-content / success",
       W.contrast(c(b, "--color-success-content"), c(b, "--color-success")), @aa_text},
      {"draft tag: on-viewer / shade over mix (painted)", on_shade, @aa_text},
      {"build tag: on-viewer / shade over mix (painted)", on_shade, @aa_text},
      {"tile glyph: on-viewer / mix", on_mix, @non_text},
      {"list glyph: on-viewer / mix", on_mix, @non_text}
    ]
  end

  defp f4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  # ── structure (anti-vacuity first) ─────────────────────────────────────

  test "the game card rules are exactly the expected set", %{rules: rules} do
    assert MapSet.new(rules, &{&1.at, &1.selector}) == @expected_selectors
    assert Enum.all?(rules, &(String.trim(&1.body) != ""))
  end

  test "their bodies paint the measured mix and hold no colour literal", %{rules: rules} do
    body = fn sel -> rules |> Enum.find(&(&1.selector == sel)) |> Map.fetch!(:body) end
    flat = fn sel -> sel |> body.() |> String.split() |> Enum.join(" ") end

    assert flat.(".browser-icon-game") =~ "background: #{@mix};"

    assert flat.(".browser-thumb-game") =~
             "background: linear-gradient( 135deg, #{@mix}, var(--stage) );"

    offenders =
      for r <- rules, Regex.match?(@colour_literal, r.body), do: {r.selector, String.trim(r.body)}

    assert offenders == []
  end

  test "the markup paints the tags and glyphs with the measured slots", %{components: src} do
    assert src =~ ~s(class="browser-thumb-game relative)
    assert src =~ "browser-icon-game inline-flex"
    assert src =~ ~s(do: "bg-success text-success-content")
    assert src =~ ~s(else: "bg-shade text-on-viewer")

    assert src =~
             "rounded-full bg-shade px-[7px] py-0.5 text-xs font-bold tracking-[.05em] text-on-viewer"

    assert src =~ ~s(<.icon name="hero-puzzle-piece" class="size-10 text-on-viewer" />)
  end

  test "--stage is declared, never --color-stage, in every block", %{blocks: blocks} do
    for b <- blocks do
      assert Blocks.declaration(b.decls, "--stage"), "#{b.id} #{b.mode}"
      refute Blocks.declaration(b.decls, "--color-stage"), "#{b.id} #{b.mode}"
    end
  end

  test "the mix is the gradient's lighter stop in every variant", %{blocks: blocks} do
    for b <- blocks do
      assert W.luminance(mix(b)) >= W.luminance(px(c(b, "--stage"))), "#{b.id} #{b.mode}"
    end
  end

  # ── contrast ───────────────────────────────────────────────────────────

  test "every pair clears its floor in all ten variants; the table prints", %{blocks: blocks} do
    assert length(blocks) == 10

    rows = for b <- blocks, do: {b, pairs(b)}
    labels = rows |> hd() |> elem(1) |> Enum.map(&elem(&1, 0))

    IO.puts(
      "\nGame card AA table (WCAG 2.x; painted rows on the worst pixel PaintedComposite allows):\n" <>
        "| Variant | mix | shade a | " <>
        Enum.join(labels, " | ") <>
        " |\n|---|---|---|" <>
        String.duplicate("---|", length(labels)) <>
        "\n" <>
        Enum.map_join(rows, "\n", fn {b, ps} ->
          "| #{b.id} #{b.mode} | #{W.to_hex(mix(b))} | #{shade_alpha_pct(b)}% | " <>
            Enum.map_join(ps, " | ", fn {_, r, _} -> f4(r) end) <> " |"
        end)
    )

    failures =
      for {b, ps} <- rows, {label, r, floor} <- ps, r < floor do
        "#{b.id} #{b.mode}: #{label} #{f4(r)} < #{floor}"
      end

    assert failures == []
  end
end

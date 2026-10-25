defmodule Platform.Design.ErrorTokenContrastGuardTest do
  @moduledoc """
  The one shared guard for the error tokens (task 01a160c4 stage 1). It holds
  `--color-error` and `--color-error-content` in all ten preset variants
  (Burrow, Midnight, Sand, Forest, High contrast; light and dark).

  ## Pairs and floors

  | pair                                   | floor |
  |----------------------------------------|-------|
  | `--color-error` on `--color-base-100`  | 4.5   |
  | `--color-error` on `--color-base-200`  | 4.5   |
  | `--color-error-content` on `--color-error` | 4.5 |

  Error is TEXT wherever `text-error` paints it (a failed-action sentence, a
  validation line), so both grounds owe the 4.5:1 text floor. The content
  token is the label on an error fill, also text.

  ## The table prints before anything is asserted

  The designer's direction canvas 01a1618e asks that the next retune start
  from numbers. So the guard prints every variant/pair/ratio/floor row first,
  plus an advisory column: the ratio the OTHER achromatic content (white for
  black, black for white) would give, which says whether a retune has to flip
  the content colour. The advisory column is never asserted.

  ## Retune (task 01a160c4), measured by this guard

  Same hue, lower lightness, values from the designer's ruling. Burrow LIGHT is
  `#da1729` with WHITE content; Burrow DARK is `#f53c41` with BLACK content.
  The two Burrow blocks carry different reds by design and this guard asserts
  that they differ. The preset darks are `#e94c50` (midnight), `#ec4e52`
  (sand) and `#e94c51` (forest), all with black content. The preset lights
  (`#a3252a`) and high contrast (`#8f0000` / `#ff6b6b`) were untouched.

  ## The Stop and Undo hover and focus border (rung 18 stage 2)

  The meeting candidate rail's "Stop" and "Undo" buttons (`candidate_rail.ex`,
  `candidate-btn--stop` / `candidate-btn--undo`) sit on `.candidate-btn`'s
  `background: var(--color-base-300)` with a `var(--color-base-content)`
  label. Until rung 18 their hover and focus painted the LABEL in a darkened
  error mix (`--cc-stop-hover`, measured here at 4.5:1 as text). Rung 18's R3
  takes status hues off text, so hover (behind `@media (hover: hover) and
  (min-width: 1024px)`) and `:focus-visible` now change only `border-color`,
  to raw `var(--color-error)`, and the label stays base-content.

  So two pairs are owed, read from the rules in `app.css` rather than assumed:

    * the label, `--color-base-content` on `--color-base-300`: text, 4.5:1;
    * the border, `--color-error` on `--color-base-300` (the button's own
      fill) and on `--color-base-100` (the card around it): a state
      indicator, the 3:1 non-text floor (WCAG 1.4.11).

  `theme_presets.css` must declare no `--cc-` token, and `app.css` none at all:
  the rail palette is gone, so a per-preset override would be a shim.

  ## Anti-vacuity and the positive control

    * Exactly ten blocks are read, a missing one flunks, and every pair is
      resolved through `ThemeBlockAssertions.resolve!/2`, which flunks on an undeclared
      token rather than measuring a default.
    * Positive control: the PRE-retune values (Burrow `oklch(63% 0.22 25)`,
      preset dark `#e5484d`) are parsed with `WcagContrast.parse!/1` and
      measured on the same variant's base-100. Each is under 4.5, so the floor
      can fire on exactly these grounds.

  Mutations (task 01a160c4 stage 1, each on its own probe branch): sand dark
  back to `#e5484d`; Burrow light content back to black; Burrow dark error
  collapsed to the light `#da1729`. Each turns this file red.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules
  alias Platform.Design.ThemeBlocks, as: Blocks
  alias Platform.Design.ThemeBlockAssertions
  alias Platform.Design.WcagContrast, as: W

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)

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

  # {label, foreground token, ground token}
  @pairs [
    {"error on base-100", "--color-error", "--color-base-100"},
    {"error on base-200", "--color-error", "--color-base-200"},
    {"error-content on error", "--color-error-content", "--color-error"}
  ]

  # The values the retune replaced, keyed by the variants that carried them.
  @pre_retune [
    {{"burrow", "light"}, "oklch(63% 0.22 25)"},
    {{"burrow", "dark"}, "oklch(63% 0.22 25)"},
    {{"burrow-midnight", "dark"}, "#e5484d"},
    {{"burrow-sand", "dark"}, "#e5484d"},
    {{"burrow-forest", "dark"}, "#e5484d"}
  ]

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

    {:ok, blocks: blocks, app_css: app_css, presets: presets}
  end

  # An opaque slot's colour: `--color-<slot>`, else Burrow's bare `--<slot>`
  # (mirrors settings_contrast_guard_test.exs).
  defp opaque(b, "--color-" <> slot = token) do
    if Blocks.declaration(b.decls, token),
      do: ThemeBlockAssertions.resolve!(b, token),
      else: ThemeBlockAssertions.resolve!(b, "--#{slot}")
  end

  # The achromatic content a retune could flip to: white for black, black for white.
  defp other_content(color) do
    if W.luminance(color) > 0.5, do: W.hex("#000000"), else: W.hex("#FFFFFF")
  end

  defp measure(blocks) do
    for b <- blocks, {label, fg, ground} <- @pairs do
      fg_c = opaque(b, fg)
      ground_c = opaque(b, ground)
      ratio = W.contrast(fg_c, ground_c)

      advisory =
        if fg == "--color-error-content",
          do: Float.round(W.contrast(other_content(fg_c), ground_c), 4),
          else: nil

      %{variant: "#{b.id} #{b.mode}", pair: label, ratio: ratio, advisory: advisory}
    end
  end

  defp print_table(rows) do
    header =
      String.pad_trailing("variant", 22) <>
        String.pad_trailing("pair", 26) <>
        String.pad_trailing("ratio", 9) <> "floor  other-content"

    lines =
      Enum.map(rows, fn r ->
        String.pad_trailing(r.variant, 22) <>
          String.pad_trailing(r.pair, 26) <>
          String.pad_trailing(:erlang.float_to_binary(r.ratio, decimals: 4), 9) <>
          String.pad_trailing("#{@aa_text}", 7) <>
          if(r.advisory, do: :erlang.float_to_binary(r.advisory, decimals: 4), else: "")
      end)

    IO.puts("\n[error-token contrast]\n" <> Enum.join([header | lines], "\n"))
  end

  test "exactly ten variant blocks are read", %{blocks: blocks} do
    assert length(blocks) == 10
    assert Enum.map(blocks, &{&1.id, &1.mode}) == @variants
  end

  test "every error pair clears #{@aa_text}:1 in all ten variants (table prints first)",
       %{blocks: blocks} do
    rows = measure(blocks)
    print_table(rows)

    # Anti-vacuity: every variant contributed every pair.
    assert length(rows) == length(@variants) * length(@pairs)

    failures =
      rows
      |> Enum.filter(&(&1.ratio < @aa_text))
      |> Enum.map(&"#{&1.variant}: #{&1.pair} #{Float.round(&1.ratio, 4)}:1")

    assert failures == [],
           "error pairs under the #{@aa_text}:1 text floor:\n  " <> Enum.join(failures, "\n  ")
  end

  test "the Burrow light and dark blocks declare different --color-error values",
       %{blocks: blocks} do
    [light, dark] =
      for mode <- ["light", "dark"] do
        b = Enum.find(blocks, &(&1.id == "burrow" and &1.mode == mode))

        Blocks.declaration(b.decls, "--color-error") ||
          flunk("burrow #{mode}: no --color-error")
      end

    refute String.downcase(light) == String.downcase(dark),
           "the Burrow light and dark --color-error are both #{light}; the two blocks " <>
             "take different reds by design (task 01a160c4). Never collapse them."
  end

  test "positive control: the pre-retune reds fail the floor on these grounds",
       %{blocks: blocks} do
    measured =
      for {{id, mode}, value} <- @pre_retune do
        b = Enum.find(blocks, &(&1.id == id and &1.mode == mode))
        old = W.parse!(value)

        {id, mode, value, W.contrast(old, opaque(b, "--color-base-100")),
         W.contrast(old, opaque(b, "--color-base-200"))}
      end

    IO.puts(
      "\n[error-token positive control: pre-retune error on base-100 / base-200]\n" <>
        Enum.map_join(measured, "\n", fn {id, mode, value, on_100, on_200} ->
          String.pad_trailing("#{id} #{mode}", 22) <>
            String.pad_trailing(value, 20) <>
            :erlang.float_to_binary(on_100, decimals: 4) <>
            " / " <> :erlang.float_to_binary(on_200, decimals: 4)
        end)
    )

    # Only base-100 is asserted: it is the ground every pre-retune value
    # failed on. base-200 prints for the record.
    for {id, mode, value, ratio, _on_200} <- measured do
      assert ratio < @aa_text,
             "#{id} #{mode}: the pre-retune #{value} measures #{Float.round(ratio, 4)}:1 " <>
               "on base-100, so the #{@aa_text} floor could not tell it from the retune."
    end
  end

  # ── the Stop and Undo hover and focus border (rung 18 stage 2) ─────────

  @hover_media "@media (hover: hover) and (min-width: 1024px)"

  defp rule!(rules, selector, at) do
    case Enum.filter(rules, &(&1.selector == selector and &1.at == at)) do
      [r] -> r
      other -> flunk("expected one #{selector} rule at #{inspect(at)}, found #{length(other)}")
    end
  end

  defp decl(body, prop) do
    case Regex.run(~r/(?<![-\w])#{prop}\s*:\s*([^;]+);/, body) do
      [_, v] -> String.trim(v)
      nil -> nil
    end
  end

  defp f4(x), do: :erlang.float_to_binary(x, decimals: 4)

  test "Stop and Undo: hover and focus change only the border, to --color-error",
       %{app_css: app_css, presets: presets} do
    rules = CssRules.rules(app_css)
    btn = rule!(rules, ".candidate-btn", [])
    assert decl(btn.body, "background") == "var(--color-base-300)"
    assert decl(btn.body, "color") == "var(--color-base-content)"

    for sel <- [".candidate-btn--stop", ".candidate-btn--undo"],
        {selector, at} <- [{"#{sel}:hover", [@hover_media]}, {"#{sel}:focus-visible", []}] do
      r = rule!(rules, selector, at)
      assert decl(r.body, "border-color") == "var(--color-error)", selector
      assert decl(r.body, "color") == nil, "#{selector} paints its label: R3 keeps hue off text"
    end

    # No ungated hover: a phone never sees a sticky red edge.
    refute Enum.any?(
             rules,
             &(&1.selector =~ ~r/^\.candidate-btn--(stop|undo):hover$/ and &1.at == [])
           )

    refute Blocks.strip_comments(app_css) =~ ~r/--cc-[a-z]/,
           "app.css declares or reads a --cc- token; the rail palette was deleted in rung 18"

    refute Blocks.strip_comments(presets) =~ ~r/--cc-[a-z]/,
           "theme_presets.css declares a --cc- token"
  end

  test "Stop and Undo: label clears #{@aa_text}:1 and the error border #{@aa_non_text}:1 in all ten variants (table prints first)",
       %{blocks: blocks} do
    rows =
      for b <- blocks do
        error = opaque(b, "--color-error")
        btn = opaque(b, "--color-base-300")
        card = opaque(b, "--color-base-100")

        %{
          variant: "#{b.id} #{b.mode}",
          label: W.contrast(opaque(b, "--color-base-content"), btn),
          border_btn: W.contrast(error, btn),
          border_card: W.contrast(error, card)
        }
      end

    IO.puts(
      "\n[stop/undo: label on base-300, error border on base-300 / base-100]\n" <>
        String.pad_trailing("variant", 22) <>
        String.pad_trailing("label", 9) <>
        String.pad_trailing("border/300", 12) <>
        "border/100\n" <>
        Enum.map_join(rows, "\n", fn r ->
          String.pad_trailing(r.variant, 22) <>
            String.pad_trailing(f4(r.label), 9) <>
            String.pad_trailing(f4(r.border_btn), 12) <> f4(r.border_card)
        end)
    )

    assert length(rows) == 10

    failures =
      for r <- rows,
          {what, ratio, floor} <- [
            {"label", r.label, @aa_text},
            {"border on base-300", r.border_btn, @aa_non_text},
            {"border on base-100", r.border_card, @aa_non_text}
          ],
          ratio < floor,
          do: "#{r.variant}: #{what} #{f4(ratio)}:1 < #{floor}"

    assert failures == [], Enum.join(failures, "\n  ")
  end

  test "anti-vacuity: a base-200 border would fail the non-text floor", %{blocks: blocks} do
    # The floor can fire on these grounds: base-200 against base-300 is a
    # near-invisible edge in every variant.
    for b <- blocks do
      assert W.contrast(opaque(b, "--color-base-200"), opaque(b, "--color-base-300")) <
               @aa_non_text,
             "#{b.id} #{b.mode}"
    end
  end
end

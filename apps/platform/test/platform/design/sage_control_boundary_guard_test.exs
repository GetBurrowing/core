defmodule Platform.Design.SageControlBoundaryGuardTest do
  @moduledoc """
  Guards Sage's form-control boundary and its neutral (task 01a19555 stage 4,
  the failed review case on computed styles).

  WHAT WAS WRONG. Stage 2 sized Sage's `--edge` to clear 3:1 as "the boundary
  that identifies a control", on the premise that inputs, selects, checkboxes
  and radios paint `border-color: var(--edge)`. They do not. daisyUI 5 paints
  `.input`, `.select`, `.textarea` and `.file-input` with
  `border-color: var(--input-color)`, `--input-color` being base-content at 20%
  on the control itself, and `.checkbox`/`.radio` with
  `var(--input-color, <base-content or currentColor at 20%>)`. Under Sage that
  measured 1.60-1.80:1. Separately, the presets never override
  `--color-neutral`, so `text-neutral` in Sage dark painted app.css's dark
  #4d4647 at 1.7974:1 on base-100.

  WHAT IS HELD.

    * Sage declares `--control-border: var(--edge)` in both blocks, and it
      clears the non-text floor on base-100 and base-200.
    * No other preset, and not app.css, declares `--control-border`, so the
      layered rule in theme_presets.css paints them daisyUI's default.
    * That rule sits in `@layer utilities`, routes all six control classes
      through `--control-border`, keeps daisyUI's colour modifiers out of the
      field rule, and falls back to daisyUI's own default, read from
      `assets/vendor/daisyui.js`, character for character. A daisyUI upgrade
      that changes the default turns this red instead of silently diverging.
    * Sage declares `--color-neutral` and `--color-neutral-content` in both
      blocks: `text-neutral` clears 4.5:1 on all three grounds and
      `neutral-content` clears 4.5:1 on `neutral`.

  The computed-style proof (every control state, all 12 variants, before and
  after) is in the stage 4 test_pass evidence; this file holds the source
  shape that produces it.

  Named mutations, stage 4: (a) delete the field rule from the layered block
  and "the layered rule routes..." goes red; (b) set Sage dark
  `--color-neutral` back to #4d4647 and the neutral test goes red.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.WcagContrast, as: W
  alias Platform.Theming.ContrastPairs

  import Platform.Design.ThemeBlocks, only: [preset_blocks: 1, declaration: 2, strip_comments: 1]
  import Platform.Design.ThemeBlockAssertions, only: [resolve!: 2]

  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @daisyui_path Path.expand("../../../assets/vendor/daisyui.js", __DIR__)

  @modes ["light", "dark"]
  @non_text ContrastPairs.non_text()
  @aa_text ContrastPairs.aa_text()

  # daisyUI 5's resting defaults, as its plugin source spells them.
  @field_default "color-mix(in oklab, var(--color-base-content) 20%, #0000)"
  @checkbox_default "color-mix(in oklab, var(--color-base-content) 20%, #0000)"
  @radio_default "color-mix(in srgb, currentColor 20%, #0000)"

  @fields ["input", "select", "textarea", "file-input"]
  @modifier_colours ~w(neutral primary secondary accent info success warning error)

  setup_all do
    css = File.read!(@presets_path)

    {:ok,
     css: css,
     stripped: strip_comments(css),
     blocks: preset_blocks(css),
     app_css: File.read!(@app_css_path),
     daisyui: File.read!(@daisyui_path)}
  end

  defp sage(blocks, mode),
    do:
      Enum.find(blocks, &(&1.id == "sage" and &1.mode == mode)) || flunk("no sage #{mode} block")

  defp ratio(b, a, c), do: W.contrast(resolve!(b, a), resolve!(b, c))

  defp fixed4(r), do: :erlang.float_to_binary(r / 1, decimals: 4)

  test "Sage declares --control-border as var(--edge), clearing the non-text floor on base-100 and base-200",
       %{blocks: blocks} do
    failures =
      Enum.flat_map(@modes, fn mode ->
        b = sage(blocks, mode)
        declared = declaration(b.decls, "--control-border")

        decl =
          if declared == "var(--edge)",
            do: [],
            else: ["sage #{mode}: --control-border is #{inspect(declared)}, not var(--edge)"]

        low =
          for ground <- ["--color-base-100", "--color-base-200"],
              r = ratio(b, "--control-border", ground),
              r < @non_text,
              do: "sage #{mode}: --control-border on #{ground} #{fixed4(r)}:1"

        decl ++ low
      end)

    assert failures == [], Enum.join(failures, "\n")
  end

  test "no other preset and not app.css declares --control-border, so they paint daisyUI's default",
       %{blocks: blocks, app_css: app_css} do
    others =
      for b <- blocks,
          b.id != "sage",
          declaration(b.decls, "--control-border"),
          do: "#{b.id} #{b.mode}"

    assert others == [], "--control-border declared outside Sage: #{inspect(others)}"
    refute strip_comments(app_css) =~ ~r/--control-border\s*:/
    # Anti-vacuity: the declaration form this test looks for is the one Sage uses.
    assert length(blocks) == 10
  end

  test "the layered rule routes every daisyUI field, checkbox and radio border through --control-border",
       %{stripped: css, daisyui: daisyui} do
    # The defaults the fallbacks copy are daisyUI's own.
    assert daisyui =~ ~s("--input-color": "#{@field_default}")
    assert daisyui =~ "var(--input-color, #{@checkbox_default})"
    assert daisyui =~ "var(--input-color, #{@radio_default})"

    assert length(String.split(css, "@layer")) == 2, "theme_presets.css holds exactly one @layer"

    [_, tail] = String.split(css, "\n@layer utilities {\n", parts: 2)
    [layer | _] = String.split(tail, ~r/\n\}/, parts: 2)

    field =
      Regex.run(
        ~r/:is\(\.input, \.select, \.textarea, \.file-input\):not\(\s*:where\((.*?)\)\s*\)\s*\{\s*--input-color:\s*([^;]+);/s,
        layer
      ) ||
        flunk(
          "no field rule (.input/.select/.textarea/.file-input) in the @layer utilities block"
        )

    [_, exclusions, value] = field
    assert value == "var(--control-border, #{@field_default})"

    excluded = exclusions |> String.split(",") |> Enum.map(&String.trim/1)

    missing =
      for f <- @fields, c <- @modifier_colours, ".#{f}-#{c}" not in excluded, do: ".#{f}-#{c}"

    assert missing == [], "colour modifiers the field rule would override: #{inspect(missing)}"
    assert "[data-theme-preview] *" in excluded

    for {class, default} <- [{"checkbox", @checkbox_default}, {"radio", @radio_default}] do
      [_, v] =
        Regex.run(
          ~r/\.#{class}:not\(:where\(\[data-theme-preview\] \*, \[class\*="border-"\]\)\)\s*\{\s*border-color:\s*([^;]+);/,
          layer
        ) || flunk("no .#{class} rule in the @layer utilities block")

      assert v == "var(--input-color, var(--control-border, #{default}))"
    end

    # Nothing outside the layer reads --control-border: unlayered, a rule would
    # beat daisyUI's focus, checked and modifier states.
    outside = String.replace(css, layer, "")
    refute outside =~ "var(--control-border"
  end

  test "Sage --color-neutral clears #{@aa_text}:1 as text on all three grounds, and neutral-content on it",
       %{blocks: blocks} do
    failures =
      for mode <- @modes,
          b = sage(blocks, mode),
          {fg, bg} <- [
            {"--color-neutral", "--color-base-100"},
            {"--color-neutral", "--color-base-200"},
            {"--color-neutral", "--color-base-300"},
            {"--color-neutral-content", "--color-neutral"}
          ],
          r = ratio(b, fg, bg),
          r < @aa_text,
          do: "sage #{mode}: #{fg} on #{bg} #{fixed4(r)}:1"

    assert failures == [], Enum.join(failures, "\n")
  end
end

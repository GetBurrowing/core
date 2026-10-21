defmodule Platform.Design.BurrowPaletteGuardTest do
  @moduledoc """
  Pins the Burrow default palette (task 01a120c5 stage 1) in
  `apps/platform/assets/css/app.css`, and asserts every text/content pairing it
  produces clears WCAG AA.

  Source: Sam's 2026-10-05 "minimal recolor" spec. The values below were
  extracted from the spec's compiled light and dark mock stylesheets and match
  them, with three recorded deviations, all made for contrast:

    * dark `--color-success-content` is black, not the mock's inherited white.
      White on #6bae75 is 2.6460:1; black is 7.9365:1.
    * `--color-error-content` is black in both themes. The red is unchanged
      and the mock kept white, but white on `oklch(63% 0.22 25)` is 3.8948:1
      (it was before the recolor too); black is 5.3918:1.
    * light `--color-base-content` keeps main's black, not the spec's #221f1b
      (stage 4). Secondary text paints it at 55-60% (`text-subtle`, the
      `--subtle` token at 55%; `text-base-content/60`, daisyUI `.label`;
      `.empty-bot-author`), and the spec ink at 60% is 4.2312:1 on base-200, a
      text failure main's black (5.5683:1) did not have. At 55% only black
      clears all three warm grounds; the --subtle test below is what holds it.

  Two halves, deliberately separate:

    * VALUES. Each listed token equals its Burrow value in the theme it
      belongs to, read from that theme's own block (never file-wide).
    * CONTRAST. Each text/content pair clears 4.5:1, computed through
      `Platform.Design.WcagContrast` from the parsed declarations, and the
      focus ring clears 3:1 on all three grounds. A value pin alone would let
      a deliberate retune land a failing pair as long as the pin moved with
      it; the contrast half is what still reds then.

  Mutation (recorded in the stage-1 commit): set dark `--color-success-content`
  back to `oklch(100% 0 0)`. Both halves go red.

  Burrow token schema (task 01a1557a stage 1). daisyUI's slots stay the public
  API; the only new names are the ones daisyUI has no slot for: `--subtle`
  (the secondary-text tier), `--disabled` and `--decorative` (the two
  WCAG-exempt text colours, task 01a15902 stage 1) and the status `-dim` steps
  `--info-dim` / `--success-dim` / `--warning-dim` (fills and borders only,
  never text). Each is declared bare in both theme blocks and mapped to its
  `--color-*` key in `@theme inline`, like `--edge`. The guards: dark
  on-accent stays a passing (black) label; every new name is mapped; no `-dim`
  step is painted as text.

  The faint tier this schema used to carry was retired by task 01a15902
  stage 2 (direction canvas 01a15902-e3b2, Rulings 1): text has two colour
  levels, body and subtle. Its placeholders paint `--subtle`; the test that
  `--faint` is gone lives in `theme_presets_guard_test.exs`, which reads both
  CSS files.

  Mutations (recorded in the task 01a1557a stage-1 commit): dark
  `--color-primary-content` to `oklch(100% 0 0)`; delete a `--color-*` mapping
  line. Each turns this file red.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)

  @aa_text 4.5
  @non_text 3.0

  @burrow %{
    "light" => %{
      "--color-base-100" => "#fbfaf9",
      "--color-base-200" => "#f6f4f1",
      "--color-base-300" => "#efebe7",
      "--color-base-content" => "#000000",
      "--color-primary" => "#ad4b07",
      "--color-primary-content" => "#fbfaf9",
      "--color-secondary" => "#635b53",
      "--color-secondary-content" => "oklch(100% 0 0)",
      "--color-accent" => "#ad4b07",
      "--color-accent-content" => "#fbfaf9",
      "--color-info" => "#0e7382",
      "--color-success" => "#2d7638",
      "--color-warning" => "#925d0c",
      "--color-warning-content" => "#fbfaf9",
      "--color-error-content" => "oklch(0% 0 0)",
      "--edge" => "#d9d3c9",
      "--focus-ring" => "var(--color-interactive)",
      "--info-dim" => "#90d5df",
      "--success-dim" => "#95d09e",
      "--warning-dim" => "#ddb77e"
    },
    "dark" => %{
      "--color-base-100" => "#191b20",
      "--color-base-200" => "#111214",
      "--color-base-300" => "#25272b",
      "--color-base-content" => "#eeeff1",
      "--color-primary" => "#f47721",
      "--color-primary-content" => "oklch(0% 0 0)",
      "--color-secondary" => "#a9abb2",
      "--color-accent" => "#f47721",
      "--color-accent-content" => "oklch(0% 0 0)",
      "--color-info" => "#22d3ee",
      "--color-success" => "#6bae75",
      "--color-success-content" => "oklch(0% 0 0)",
      "--color-warning" => "#e5a33d",
      "--color-error-content" => "oklch(0% 0 0)",
      "--edge" => "#383b42",
      "--focus-ring" => "var(--color-primary)",
      "--info-dim" => "#175660",
      "--success-dim" => "#314936",
      "--warning-dim" => "#5b4522"
    }
  }

  @interactive %{"light" => "#8b3b04", "dark" => "#ff9b55"}

  # {text, ground} pairs that are text and owe 4.5:1.
  @text_pairs [
    {"--color-base-content", "--color-base-100"},
    {"--color-base-content", "--color-base-200"},
    {"--color-base-content", "--color-base-300"},
    {"--color-primary-content", "--color-primary"},
    {"--color-accent-content", "--color-accent"},
    {"--color-secondary-content", "--color-secondary"},
    {"--color-info-content", "--color-info"},
    {"--color-success-content", "--color-success"},
    {"--color-warning-content", "--color-warning"},
    {"--color-error-content", "--color-error"},
    {"--color-interactive", "--color-base-100"},
    {"--color-interactive", "--color-base-200"},
    {"--color-interactive", "--color-base-300"}
  ]

  @grounds ["--color-base-100", "--color-base-200", "--color-base-300"]

  # Burrow token schema (task 01a1557a): the names daisyUI has no slot for.
  # Each is declared bare in both theme blocks and mapped to a --color-* key in
  # @theme inline, exactly like --edge.
  @schema_tokens [
    "--subtle",
    "--disabled",
    "--decorative",
    "--info-dim",
    "--success-dim",
    "--warning-dim"
  ]

  # --subtle (task 01a1557a stage 5 r2): base-content at 55% in both Burrow
  # themes, the composite the retired 55% utility compiled to.
  @subtle_value "color-mix(in oklab, var(--color-base-content) 55%, transparent)"
  # --disabled and --decorative (task 01a15902 stage 1): the two WCAG-exempt
  # text colours, base-content at 40% (the look disabled controls have today).
  # Exempt, so no contrast floor; text_exemption_guard_test.exs holds where
  # each may be used.
  @exempt_value "color-mix(in oklab, var(--color-base-content) 40%, transparent)"
  @dim_tokens ["--info-dim", "--success-dim", "--warning-dim"]

  setup_all do
    {:ok, css: File.read!(@css_path)}
  end

  for theme <- ["light", "dark"] do
    describe "#{theme}" do
      @theme theme

      test "every Burrow token equals its spec value", %{css: css} do
        block = theme_block(css, @theme)
        expected = Map.fetch!(@burrow, @theme)

        refute expected == %{}

        for {token, want} <- expected do
          got = declaration(block, token) || flunk("#{@theme}: no #{token} in its theme block")

          assert String.downcase(got) == want,
                 "#{@theme} #{token} is #{inspect(got)}, the Burrow value is #{inspect(want)}."
        end
      end

      test "--color-interactive is the Burrow value in every scope that sets it", %{css: css} do
        decls = interactive_declarations(css, @theme)

        assert length(decls) == expected_interactive_scopes(@theme),
               "#{@theme}: found #{length(decls)} --color-interactive declarations: " <>
                 inspect(decls)

        for {scope, value} <- decls do
          assert String.downcase(value) == @interactive[@theme],
                 "#{@theme} --color-interactive under #{scope} is #{value}, " <>
                   "the Burrow value is #{@interactive[@theme]}."
        end
      end

      test "every text/content pair clears #{@aa_text}:1", %{css: css} do
        failures =
          @text_pairs
          |> Enum.map(fn {text, ground} -> {text, ground, ratio(css, @theme, text, ground)} end)
          |> Enum.filter(fn {_, _, r} -> r < @aa_text end)
          |> Enum.map(fn {text, ground, r} -> "#{text} on #{ground}: #{Float.round(r, 4)}:1" end)

        assert failures == [],
               "#{@theme} pairs under the #{@aa_text}:1 WCAG AA text floor:\n  " <>
                 Enum.join(failures, "\n  ")
      end

      # Secondary text is base-content at reduced strength: text-subtle
      # (--subtle, 55% here) and .empty-bot-author at 55%, /60 and daisyUI's
      # .label at 60%. Painted ratio: the composite is quantised to 8 bits, as
      # the browser paints it (axe read #777471 off the spec ink on base-200 at
      # 60%), on the worst pixel any measured browser formula allows
      # (PaintedComposite, stage 5 r2).
      test "--subtle is base-content at 55%", %{css: css} do
        assert declaration(theme_block(css, @theme), "--subtle") == @subtle_value
      end

      test "--disabled and --decorative are base-content at 40%", %{css: css} do
        block = theme_block(css, @theme)
        assert declaration(block, "--disabled") == @exempt_value
        assert declaration(block, "--decorative") == @exempt_value
      end

      for strength <- [55, 60] do
        @strength strength

        test "base-content at #{strength}% clears #{@aa_text}:1 on all three grounds", %{
          css: css
        } do
          failures =
            @grounds
            |> Enum.map(&{&1, painted(css, @theme, &1, @strength)})
            |> Enum.filter(fn {_, r} -> r < @aa_text end)
            |> Enum.map(fn {ground, r} -> "#{ground}: #{Float.round(r, 4)}:1" end)

          assert failures == [],
                 "#{@theme} secondary text (base-content at #{@strength}%) under " <>
                   "#{@aa_text}:1:\n  " <> Enum.join(failures, "\n  ")
        end
      end

      test "the --subtle comment records the computed ratios", %{css: css} do
        block = theme_block(css, @theme)

        missing =
          for g <- @grounds,
              r = painted(css, @theme, g, 55),
              not String.contains?(block, fixed4(r) <> ":1"),
              do: "--subtle on #{g}: #{fixed4(r)}:1"

        assert missing == [],
               "#{@theme}: the --subtle comment does not carry these computed ratios:\n  " <>
                 Enum.join(missing, "\n  ")
      end

      test "the focus ring clears #{@non_text}:1 on all three grounds", %{css: css} do
        for ground <- @grounds do
          r = ratio(css, @theme, "--focus-ring", ground)

          assert r >= @non_text,
                 "#{@theme} --focus-ring on #{ground} is #{Float.round(r, 4)}:1"
        end
      end

      test "the theme block declares the schema names bare, never as --color-*", %{css: css} do
        block = theme_block(css, @theme)

        for token <- @schema_tokens do
          bare = String.trim_leading(token, "--")

          assert declaration(block, token), "#{@theme}: no #{token} in its theme block"

          refute declaration(block, "--color-" <> bare),
                 "#{@theme} declares --color-#{bare} in its theme block. Declare #{token} " <>
                   "there; @theme inline maps the --color-* key, and a --color-* name in " <>
                   "the theme block makes that mapping self-referential."
        end
      end
    end
  end

  test "dark on-accent (primary-content) on the primary clears #{@aa_text}:1", %{css: css} do
    on_accent = ratio(css, "dark", "--color-primary-content", "--color-primary")

    assert on_accent >= @aa_text,
           "dark --color-primary-content on --color-primary is " <>
             "#{Float.round(on_accent, 4)}:1. The Burrow masters' white label is the " <>
             "AA defect; the label stays black here and theme.js changes, not app.css."

    # The comment beside the dark declaration names the white figure it refuses.
    white = W.contrast(W.parse!("oklch(100% 0 0)"), resolve!(css, "dark", "--color-primary"))

    assert String.contains?(theme_block(css, "dark"), fixed4(white) <> ":1"),
           "the dark block no longer records white on the primary (#{fixed4(white)}:1), " <>
             "the masters' defect this declaration exists to refuse."
  end

  test "each schema name is mapped to its --color-* key in @theme inline", %{css: css} do
    block = theme_inline_block(css)

    missing =
      for token <- @schema_tokens,
          key <- ["--color-" <> String.trim_leading(token, "--")],
          declaration(block, key) != "var(#{token})" do
        "#{key}: var(#{token});"
      end

    assert missing == [],
           "@theme inline is missing these mappings; without one Tailwind mints no " <>
             "utility for the token and every call site falls back to currentColor:\n  " <>
             Enum.join(missing, "\n  ")
  end

  test "the status -dim steps are never painted as text", %{css: css} do
    lib = Path.expand("../../../lib", __DIR__)

    utility_hits =
      Path.join(lib, "**/*.{ex,heex}")
      |> Path.wildcard()
      |> Enum.filter(&Regex.match?(~r/\btext-(info|success|warning)-dim\b/, File.read!(&1)))
      |> Enum.map(&Path.relative_to(&1, lib))

    css_hits =
      for token <- @dim_tokens,
          key <- [token, "--color-" <> String.trim_leading(token, "--")],
          Regex.match?(~r/(^|[;{\s])color\s*:\s*var\(#{Regex.escape(key)}\)/m, css),
          do: key

    assert utility_hits == [] and css_hits == [],
           "a -dim step is painted as text; they are fills and borders only: " <>
             "lib #{inspect(utility_hits)}, app.css #{inspect(css_hits)}"
  end

  test "dark edge is lighter than dark base-100, light edge darker than light", %{css: css} do
    lum = fn theme, token -> W.luminance(resolve!(css, theme, token)) end

    assert lum.("dark", "--edge") > lum.("dark", "--color-base-100")
    assert lum.("light", "--edge") < lum.("light", "--color-base-100")
  end

  # ── extraction ───────────────────────────────────────────────────────────

  defp ratio(css, theme, a, b), do: W.contrast(resolve!(css, theme, a), resolve!(css, theme, b))

  defp painted(css, theme, ground, strength) do
    ink = resolve!(css, theme, "--color-base-content")
    bg = resolve!(css, theme, ground)
    elem(PaintedComposite.contrast_min(ink, bg, strength), 0)
  end

  defp fixed4(r), do: :erlang.float_to_binary(r, decimals: 4)

  defp theme_inline_block(css) do
    case blocks_after(css, "@theme inline {") do
      [block] -> block
      other -> flunk("expected exactly one `@theme inline {` block, found #{length(other)}")
    end
  end

  defp expected_interactive_scopes("light"), do: 1
  defp expected_interactive_scopes("dark"), do: 2

  # Light: :root. Dark: [data-theme="dark"] AND the prefers-color-scheme
  # :root:not([data-theme="light"]) block; both must carry the dark value or
  # one way of entering dark mode paints the old colour.
  defp interactive_declarations(css, "light") do
    declared_in(css, "\n:root {", ":root")
  end

  defp interactive_declarations(css, "dark") do
    declared_in(css, ~s(\n[data-theme="dark"] {), ~s([data-theme="dark"])) ++
      declared_in(
        css,
        "\n  :root:not([data-theme=\"light\"]) {",
        "@media dark :root:not([data-theme=\"light\"])"
      )
  end

  defp declared_in(css, open, label) do
    css
    |> selector_blocks(open)
    |> Enum.map(&declaration(&1, "--color-interactive"))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{label, &1})
  end

  # Theme block first, then the theme-scoped selectors, then :root, following
  # var() aliases. Raises on any miss.
  defp resolve!(css, theme, var, depth \\ 0)

  defp resolve!(_css, theme, var, depth) when depth > 8,
    do: flunk("#{theme}: resolving #{var} did not terminate")

  defp resolve!(css, theme, var, depth) do
    value =
      Enum.find_value(scopes(css, theme), fn b -> declaration(b, var) end) ||
        flunk("#{theme}: no #{var} declaration reachable")

    case Regex.run(~r/^var\(\s*(--[A-Za-z0-9_-]+)\s*\)$/, value) do
      [_, next] -> resolve!(css, theme, next, depth + 1)
      nil -> W.parse!(value)
    end
  end

  defp scopes(css, "light"), do: [theme_block(css, "light") | selector_blocks(css, "\n:root {")]

  defp scopes(css, "dark") do
    [theme_block(css, "dark")] ++
      selector_blocks(css, ~s(\n[data-theme="dark"] {)) ++ selector_blocks(css, "\n:root {")
  end

  defp theme_block(css, name) do
    css
    |> blocks_after(@plugin_open)
    |> Enum.find(&Regex.match?(~r/^\s*name:\s*"#{name}";/m, &1)) ||
      flunk("no daisyui-theme block named #{inspect(name)} in #{@css_path}")
  end

  defp selector_blocks(css, open), do: blocks_after(css, open)

  defp blocks_after(css, open) do
    css
    |> :binary.matches(open)
    |> Enum.map(fn {at, len} ->
      start = at + len
      rest = binary_part(css, start, byte_size(css) - start)

      case Regex.run(~r/\n\s*\}/, rest, return: :index) do
        [{close, _}] -> binary_part(rest, 0, close)
        nil -> flunk("a block opened by #{inspect(open)} is never closed")
      end
    end)
  end

  defp declaration(block, var) do
    case Regex.run(~r/^\s*#{Regex.escape(var)}\s*:\s*([^;]+);/m, block) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end
end

defmodule Platform.Design.BurrowPaletteGuardTest do
  @moduledoc """
  Pins the Burrow default palette (task 01a120c5 stage 1) in
  `apps/platform/assets/css/app.css`, and asserts every text/content pairing it
  produces clears WCAG AA.

  Source: Harper's 2026-10-05 "minimal recolor" spec. The values below were
  extracted from the spec's compiled light and dark mock stylesheets and match
  them, with three recorded deviations, all made for contrast:

    * dark `--color-success-content` is black, not the mock's inherited white.
      White on #6bae75 is 2.6460:1; black is 7.9365:1.
    * `--color-error-content` is black in both themes. The red is unchanged
      and the mock kept white, but white on `oklch(63% 0.22 25)` is 3.8948:1
      (it was before the recolor too); black is 5.3918:1.
    * light `--color-base-content` keeps main's black, not the spec's #221f1b
      (stage 4). Secondary text paints it at 55-60% (`text-base-content/55`
      and `/60`, daisyUI `.label`, `.empty-bot-author`), and the spec ink at
      60% is 4.2312:1 on base-200, a text failure main's black (5.5683:1) did
      not have. At 55% only black clears all three warm grounds; the 55% test
      below is what holds it.

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
  """
  use ExUnit.Case, async: true

  alias Platform.Design.WcagContrast, as: W

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)

  @aa_text 4.5
  @non_text 3.0
  @secondary_alpha 0.55

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
      "--focus-ring" => "var(--color-interactive)"
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
      "--focus-ring" => "var(--color-primary)"
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

      # Secondary text is base-content at reduced strength: /60 and daisyUI's
      # .label at 60%, /55 and .empty-bot-author at 55%. 55% is the weakest
      # strength main's ink cleared AA at, so the ink must clear it here too.
      # Painted ratio: the composite is quantised to 8 bits, as the browser
      # paints it (axe read #777471 off the spec ink on base-200 at 60%).
      test "base-content at 55% clears #{@aa_text}:1 on all three grounds", %{css: css} do
        ink = resolve!(css, @theme, "--color-base-content")

        failures =
          @grounds
          |> Enum.map(fn ground ->
            bg = resolve!(css, @theme, ground)
            {ground, W.contrast_painted(W.composite(ink, @secondary_alpha, bg), bg)}
          end)
          |> Enum.filter(fn {_, r} -> r < @aa_text end)
          |> Enum.map(fn {ground, r} -> "#{ground}: #{Float.round(r, 4)}:1" end)

        assert failures == [],
               "#{@theme} secondary text (base-content at 55%) under #{@aa_text}:1:\n  " <>
                 Enum.join(failures, "\n  ")
      end

      test "the focus ring clears #{@non_text}:1 on all three grounds", %{css: css} do
        for ground <- @grounds do
          r = ratio(css, @theme, "--focus-ring", ground)

          assert r >= @non_text,
                 "#{@theme} --focus-ring on #{ground} is #{Float.round(r, 4)}:1"
        end
      end
    end
  end

  test "dark edge is lighter than dark base-100, light edge darker than light", %{css: css} do
    lum = fn theme, token -> W.luminance(resolve!(css, theme, token)) end

    assert lum.("dark", "--edge") > lum.("dark", "--color-base-100")
    assert lum.("light", "--edge") < lum.("light", "--color-base-100")
  end

  # ── extraction ───────────────────────────────────────────────────────────

  defp ratio(css, theme, a, b), do: W.contrast(resolve!(css, theme, a), resolve!(css, theme, b))

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

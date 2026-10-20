defmodule Platform.Design.FaintAdoptionTest do
  @moduledoc """
  Pins the consumers of the Burrow `--faint` token (task 01a1557a stage 2), the
  rung where the faint AA fix becomes painted.

  Stage 1 declared `--faint` in both daisyUI theme blocks and mapped it to
  `--color-faint` in `@theme inline` (guarded by `burrow_palette_guard_test.exs`).
  A declared token fixes nothing until a rule reads it. This file holds the
  reads:

    * `.thread-input::placeholder` reads `var(--faint)`, and the light-only
      override (`#888`, 3.5449:1 on the light `#ffffff` fill) is gone. The dark
      literal it replaced, `#666`, painted 2.4329:1 on the `#252c3d` fill.
    * `.compose-pill-bar textarea::placeholder` reads `var(--faint)`: the main
      composer, the design direction's signature element.
    * none of the four input sites still paints its placeholder at
      `placeholder:text-base-content/40` (3.34-3.48:1 in dark); each uses
      `placeholder:text-faint`.

  The placeholders sit on fills that are not theme grounds: the thread input
  is `#252c3d` in dark (bluer and darker than base-300) and `#ffffff` in light,
  and the composer pill is `oklch(0.21 0 0)` / `oklch(1 0 0)`. The palette
  guard only measures `--faint` on base-100/200/300, so the last test here
  measures it on these fills. It is what moved dark `--faint` from `#8a8d95`
  (4.1987:1 on `#252c3d`, read off screenshot pixels) to `#90939b`.

  Mutation (recorded in the stage-2 commit): put `#666` back on
  `.thread-input::placeholder`. The first test goes red.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.WcagContrast, as: W

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @lib Path.expand("../../../lib", __DIR__)

  @placeholder_rules [
    ".thread-input::placeholder",
    ".compose-pill-bar textarea::placeholder"
  ]

  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)
  @aa_text 4.5

  # {theme, the exact selector whose `background` paints behind the placeholder}
  @placeholder_fills [
    {"dark", ".thread-input"},
    {"light", ~s([data-theme="light"] .thread-input)},
    {"dark", ~s([data-theme="dark"] .compose-pill-bar)},
    {"light", ~s([data-theme="light"] .compose-pill-bar)}
  ]

  @template_sites [
    "platform_web/live/chat/partials/external_rail.ex",
    "platform_web/live/chat/partials/mobile_browser.ex",
    "platform_web/live/chat/partials/rail.ex",
    "platform_web/live/meeting_live.html.heex"
  ]

  setup_all do
    {:ok, css: File.read!(@css_path)}
  end

  for selector <- @placeholder_rules do
    @selector selector

    test "#{selector} paints var(--faint) and nothing else", %{css: css} do
      colors = color_declarations(css, @selector)

      assert colors != [], "no `#{@selector} { color: ... }` rule in #{@css_path}"

      assert Enum.all?(colors, &(&1 == "var(--faint)")),
             "#{@selector} paints #{inspect(colors)}; every rule for it must read " <>
               "var(--faint), the AA-checked faint text tier, in both themes."
    end
  end

  test "no theme-scoped override repaints the thread placeholder", %{css: css} do
    overrides =
      Regex.scan(~r/\[data-theme="(?:light|dark)"\][^{]*\.thread-input::placeholder\s*\{/, css)

    assert overrides == [],
           "a theme-scoped .thread-input::placeholder rule is back: #{inspect(overrides)}. " <>
             "--faint resolves per theme; an override paints a second, unguarded colour."
  end

  test "no input site paints its placeholder at base-content/40" do
    for rel <- @template_sites do
      source = File.read!(Path.join(@lib, rel))

      refute source =~ "placeholder:text-base-content/40",
             "#{rel} still paints a placeholder at text-base-content/40 (3.34-3.48:1 in dark)."

      assert source =~ "placeholder:text-faint",
             "#{rel} has no placeholder:text-faint; the site moved or its class changed."
    end
  end

  test "--faint clears #{@aa_text}:1 on the fills the placeholders paint on", %{css: css} do
    failures =
      @placeholder_fills
      |> Enum.map(fn {theme, selector} ->
        faint = W.parse!(theme_declaration!(css, theme, "--faint"))
        fill = W.parse!(exact_declaration!(selector, css, "background"))
        {theme, selector, W.contrast_painted(faint, fill)}
      end)
      |> Enum.filter(fn {_, _, r} -> r < @aa_text end)
      |> Enum.map(fn {theme, selector, r} ->
        "#{theme} --faint on `#{selector}` background: #{Float.round(r, 4)}:1"
      end)

    assert failures == [],
           "a faint placeholder is under the #{@aa_text}:1 AA text floor on the fill it " <>
             "paints on:\n  " <> Enum.join(failures, "\n  ")
  end

  # The value of `prop` in the rule whose selector list contains exactly
  # `selector`. oklch with a unitless lightness (`oklch(0.21 0 0)`) is
  # rewritten to the percentage form WcagContrast parses.
  defp exact_declaration!(selector, css, prop) do
    values =
      css
      |> rules()
      |> Enum.filter(fn {selectors, _} -> selector in selectors end)
      |> Enum.flat_map(fn {_, body} ->
        Regex.scan(~r/(?:^|;|\s)#{prop}\s*:\s*([^;]+);/, body, capture: :all_but_first)
      end)
      |> Enum.map(fn [v] -> String.trim(v) end)

    case List.last(values) do
      nil ->
        flunk("no `#{selector} { #{prop}: ... }` rule in #{@css_path}")

      value ->
        Regex.replace(~r/^oklch\(\s*([\d.]+)\s/, value, fn _, l ->
          {lightness, ""} = Float.parse(l)
          "oklch(#{lightness * 100}% "
        end)
    end
  end

  defp theme_declaration!(css, theme, var) do
    block =
      css
      |> :binary.matches(@plugin_open)
      |> Enum.map(fn {at, len} ->
        rest = binary_part(css, at + len, byte_size(css) - at - len)
        [{close, _}] = Regex.run(~r/\n\s*\}/, rest, return: :index)
        binary_part(rest, 0, close)
      end)
      |> Enum.find(&Regex.match?(~r/^\s*name:\s*"#{theme}";/m, &1)) ||
        flunk("no daisyui-theme block named #{theme}")

    case Regex.run(~r/^\s*#{Regex.escape(var)}\s*:\s*([^;]+);/m, block) do
      [_, value] -> String.trim(value)
      nil -> flunk("#{theme}: no #{var} in its theme block")
    end
  end

  # {[selector], body} for every innermost rule, comments stripped.
  defp rules(css) do
    ~r/(^|\})([^{}]*)\{([^{}]*)\}/m
    |> Regex.scan(Regex.replace(~r{/\*.*?\*/}s, css, ""), capture: :all_but_first)
    |> Enum.map(fn [_, selectors, body] ->
      {selectors |> String.split(",") |> Enum.map(&String.trim/1), body}
    end)
  end

  # Every `color:` declaration in a rule whose selector list contains exactly
  # `selector` (bare, or with a theme/ancestor prefix).
  defp color_declarations(css, selector) do
    css
    |> rules()
    |> Enum.filter(fn {selectors, _} ->
      Enum.any?(selectors, &(&1 == selector or String.ends_with?(&1, " " <> selector)))
    end)
    |> Enum.flat_map(fn {_, body} ->
      Regex.scan(~r/(?:^|;|\s)color\s*:\s*([^;]+);/, body, capture: :all_but_first)
    end)
    |> Enum.map(fn [value] -> String.trim(value) end)
  end
end

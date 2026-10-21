defmodule Platform.Design.PlaceholderContrastTest do
  @moduledoc """
  Placeholders paint the secondary-text token, `--subtle`, and clear 4.5:1
  where they actually paint (task 01a15902 stage 2; was
  `faint_adoption_test.exs`, task 01a1557a stage 2).

  Placeholder text is still text: WCAG 1.4.3 exempts only inactive controls,
  so a placeholder owes 4.5:1 (direction canvas 01a15902-e3b2, rule 1). The
  faint tier that used to paint placeholders is retired (Rulings 1); text has
  two levels, body and subtle. This file holds:

    * the GLOBAL default. Tailwind v4 preflight paints every `::placeholder`
      at `color-mix(in oklab, currentcolor 50%, transparent)`, measured in
      the compiled app.css on the stage-2 dev server. Black at 50% misses
      4.5:1 on light grounds (planner: 3.730 worst, sand light base-300), so
      app.css sets `::placeholder` to `var(--color-subtle)` in `@layer base`:
      after preflight in the same layer, and still beneath every
      `placeholder:` utility. daisyUI's 20% placeholder applies to
      `:disabled` controls only (vendor/daisyui.js), which 1.4.3 exempts; it
      is left as it is.
    * the two rule-painted placeholders, `.thread-input::placeholder` and
      `.compose-pill-bar textarea::placeholder`, read `var(--color-subtle)`
      and nothing else, with no theme-scoped override;
    * the four template sites paint `placeholder:text-subtle`, and neither the
      retired `placeholder:text-faint` nor the old
      `placeholder:text-base-content/40`;
    * the FILLS. These placeholders sit on literal fills, not theme grounds:
      the thread input is `#252c3d` in dark and `#ffffff` in light, the
      composer pill `oklch(0.21 0 0)` / `oklch(1 0 0)`. The theme guards
      measure `--subtle` on base-100/200/300 only, so the last test measures
      it on these fills, in all 12 variants (Burrow's two daisyUI blocks, which
      the masters' Burrow dark and Burrow light both resolve to, plus the 8
      preset blocks), painted at each block's declared strength on the worst
      pixel `Platform.Design.PaintedComposite` allows.

  Named mutations, task 01a15902 stage 2: (b) `placeholder:text-faint` back on
  rail.ex; (c) delete the global `::placeholder` rule; (d) sand light's
  `--subtle` at 50%. Each turns this file red.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite
  alias Platform.Design.WcagContrast, as: W

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @presets_path Path.expand("../../../assets/css/theme_presets.css", __DIR__)
  @lib Path.expand("../../../lib", __DIR__)

  @subtle "var(--color-subtle)"

  @placeholder_rules [
    ".thread-input::placeholder",
    ".compose-pill-bar textarea::placeholder"
  ]

  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)
  @aa_text 4.5

  # {mode, the exact selector whose `background` paints behind a placeholder}
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

  @subtle_form ~r/^color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\)$/

  setup_all do
    {:ok, css: File.read!(@css_path), presets: File.read!(@presets_path)}
  end

  test "every ::placeholder defaults to the subtle slot, in @layer base", %{css: css} do
    base =
      css
      |> strip_comments()
      |> layer_blocks("base")
      |> Enum.flat_map(&rules/1)

    colors =
      for {selectors, body} <- base,
          "::placeholder" in selectors,
          [value] <- Regex.scan(~r/(?:^|;|\s)color\s*:\s*([^;]+);/, body, capture: :all_but_first),
          do: String.trim(value)

    assert colors == [@subtle],
           "app.css's @layer base must hold exactly one `::placeholder { color: " <>
             "#{@subtle}; }` (found #{inspect(colors)}). Without it every input with no " <>
             "placeholder class paints Tailwind preflight's 50% currentColor, under 4.5:1 " <>
             "on light grounds."

    refute Regex.match?(~r/(^|\})\s*::placeholder\s*\{/m, unlayered(css)),
           "a bare ::placeholder rule outside @layer base beats every placeholder: utility."
  end

  # Guards built on Platform.Design.CssRules read which rules colour an
  # element. The global rule must not read as colouring a <p>: only a text
  # control has a placeholder.
  test "CssRules matches ::placeholder to text controls only" do
    alias Platform.Design.CssRules

    refute CssRules.matches?("::placeholder", CssRules.element("p", []))
    assert CssRules.matches?("::placeholder", CssRules.element("input", []))

    assert CssRules.matches?(
             ".x textarea::placeholder",
             CssRules.element("textarea", [], [CssRules.element("div", [{"class", "x"}])])
           )
  end

  for selector <- @placeholder_rules do
    @selector selector

    test "#{selector} paints #{@subtle} and nothing else", %{css: css} do
      colors = color_declarations(css, @selector)

      assert colors != [], "no `#{@selector} { color: ... }` rule in #{@css_path}"

      assert Enum.all?(colors, &(&1 == @subtle)),
             "#{@selector} paints #{inspect(colors)}; every rule for it must read " <>
               "#{@subtle}, the AA-checked secondary-text tier, in every theme."
    end
  end

  test "no theme-scoped override repaints the thread placeholder", %{css: css} do
    overrides =
      Regex.scan(~r/\[data-theme="(?:light|dark)"\][^{]*\.thread-input::placeholder\s*\{/, css)

    assert overrides == [],
           "a theme-scoped .thread-input::placeholder rule is back: #{inspect(overrides)}. " <>
             "--subtle resolves per theme; an override paints a second, unguarded colour."
  end

  test "the four input sites paint placeholder:text-subtle" do
    for rel <- @template_sites do
      source = File.read!(Path.join(@lib, rel))

      refute source =~ "placeholder:text-base-content/40",
             "#{rel} still paints a placeholder at text-base-content/40 (3.34-3.48:1 in dark)."

      refute source =~ "placeholder:text-faint",
             "#{rel} paints the retired faint tier; placeholders are text-subtle."

      assert source =~ "placeholder:text-subtle",
             "#{rel} has no placeholder:text-subtle; the site moved or its class changed."
    end
  end

  test "--subtle clears #{@aa_text}:1 on every placeholder fill, in all 12 variants", %{
    css: css,
    presets: presets
  } do
    variants = variants(css, presets)

    # 10 blocks; the masters' burrow-dark and burrow-light rows both resolve
    # to Burrow's two blocks, which is the 12-variant set.
    assert length(variants) == 10

    measured =
      for {label, mode, decls} <- variants,
          {fill_mode, selector} <- @placeholder_fills,
          fill_mode == mode do
        ink = W.parse!(declaration!(decls, "--color-base-content", label))
        strength = subtle_strength!(decls, label)
        fill = W.parse!(exact_declaration!(selector, css, "background"))
        {r, _formulas} = PaintedComposite.contrast_min(ink, fill, strength)
        {label, selector, strength, r}
      end

    assert length(measured) == 20

    failures =
      for {label, selector, strength, r} <- measured,
          r < @aa_text,
          do: "#{label}: --subtle (#{strength}%) on `#{selector}`: #{Float.round(r, 4)}:1"

    assert failures == [],
           "a subtle placeholder is under the #{@aa_text}:1 AA text floor on the fill it " <>
             "paints on:\n  " <> Enum.join(failures, "\n  ")
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # {label, mode, declarations} for Burrow's two daisyUI blocks and the 8
  # preset blocks.
  defp variants(css, presets) do
    burrow =
      for mode <- ["dark", "light"] do
        block =
          css
          |> plugin_blocks()
          |> Enum.find(&Regex.match?(~r/^\s*name:\s*"#{mode}";/m, &1)) ||
            flunk("no daisyui-theme block named #{mode}")

        {"burrow #{mode}", mode, strip_comments(block)}
      end

    preset =
      for [id, mode, body] <-
            Regex.scan(
              ~r/^\[data-preset="([a-z0-9-]+)"\]\[data-theme="(dark|light)"\][^\n{]*\{(.*?)\n\}/ms,
              presets,
              capture: :all_but_first
            ),
          do: {"#{id} #{mode}", mode, strip_comments(body)}

    burrow ++ preset
  end

  defp subtle_strength!(decls, label) do
    value = declaration!(decls, "--subtle", label)

    case Regex.run(@subtle_form, value) do
      [_, p] -> String.to_integer(p)
      nil -> flunk("#{label}: --subtle is #{inspect(value)}, not base-content at a strength")
    end
  end

  defp declaration!(decls, var, label) do
    case Regex.run(~r/^\s*#{Regex.escape(var)}\s*:\s*([^;]+);/m, decls) do
      [_, value] -> String.trim(value)
      nil -> flunk("#{label}: no #{var} in its block")
    end
  end

  defp plugin_blocks(css) do
    css
    |> :binary.matches(@plugin_open)
    |> Enum.map(fn {at, len} ->
      rest = binary_part(css, at + len, byte_size(css) - at - len)
      [{close, _}] = Regex.run(~r/\n\s*\}/, rest, return: :index)
      binary_part(rest, 0, close)
    end)
  end

  # The value of `prop` in the rule whose selector list contains exactly
  # `selector`. oklch with a unitless lightness (`oklch(0.21 0 0)`) is
  # rewritten to the percentage form WcagContrast parses.
  defp exact_declaration!(selector, css, prop) do
    values =
      css
      |> strip_comments()
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

  defp strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")

  # The bodies of every `@layer <name> { ... }` block, braces balanced.
  defp layer_blocks(css, name) do
    ~r/@layer\s+#{name}\s*\{/
    |> Regex.scan(css, return: :index)
    |> Enum.map(fn [{at, len}] -> balanced(css, at + len) end)
  end

  # The text from `start` up to the brace that closes the block opened just
  # before it.
  defp balanced(css, start) do
    rest = binary_part(css, start, byte_size(css) - start)

    {len, _} =
      rest
      |> String.graphemes()
      |> Enum.reduce_while({0, 1}, fn
        "{", {n, d} -> {:cont, {n + 1, d + 1}}
        "}", {n, 1} -> {:halt, {n, 0}}
        "}", {n, d} -> {:cont, {n + 1, d - 1}}
        c, {n, d} -> {:cont, {n + byte_size(c), d}}
      end)

    binary_part(rest, 0, len)
  end

  # app.css with every @layer block removed.
  defp unlayered(css) do
    css = strip_comments(css)

    case Regex.run(~r/@layer\s+[\w-]+\s*\{/, css, return: :index) do
      nil ->
        css

      [{at, len}] ->
        body = balanced(css, at + len)
        rest_at = at + len + byte_size(body) + 1
        binary_part(css, 0, at) <> unlayered(binary_part(css, rest_at, byte_size(css) - rest_at))
    end
  end

  # {[selector], body} for every innermost rule.
  defp rules(css) do
    ~r/(^|\}|\{)([^{}]*)\{([^{}]*)\}/m
    |> Regex.scan(css, capture: :all_but_first)
    |> Enum.map(fn [_, selectors, body] ->
      {selectors |> String.split(",") |> Enum.map(&String.trim/1), body}
    end)
  end

  # Every `color:` declaration in a rule whose selector list contains exactly
  # `selector` (bare, or with a theme/ancestor prefix).
  defp color_declarations(css, selector) do
    css
    |> strip_comments()
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

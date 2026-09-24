defmodule Platform.Design.FocusRingSlotTest do
  @moduledoc """
  Pins the theme-split focus-ring colour slot in
  `apps/platform/assets/css/app.css`: the `--focus-ring` declaration each theme
  block carries, the `@theme inline` mapping that turns it into a
  `ring-focus-ring` utility, and the WCAG 2.2 SC 1.4.11 ratio each theme's ring
  actually paints against that theme's three page grounds.

  ## The defect this closes

  WCAG 2.2 SC 1.4.11 Non-text Contrast requires 3:1 against every adjacent
  ground for a focus indicator. `--color-primary` (#06D5ED) cannot supply that
  in the light theme — it measures 1.7875:1 on light `--color-base-100`, and it
  gets worse, not better, on the other two grounds. The dark theme is the
  opposite case: the same cyan clears the floor by a factor of three there. One
  token cannot serve both, so the ring gets its own theme-split slot, exactly
  as `--edge` did in task 01a0740b.

  This stage mints the slot only. Repointing call sites is later stages, so a
  green run here does NOT mean any ring on screen has moved yet.

  ## Why the assertions are shaped the way they are

  The cheap version of this test asserts `--focus-ring` is DEFINED. That version
  passes on the exact defect the ticket exists to close: point light
  `--focus-ring` back at `var(--color-primary)` and a definition-only test stays
  green while every focus ring in the light theme goes back under the floor. So
  the assertion is on the measured RATIO, and it was verified to go red under
  exactly that mutation (M1) with the dark cases staying green as the control.

  Light and dark are deliberately separate tests rather than one test looping
  over both themes. If they shared a test, M1 would red it and there would be
  no way to show the dark half was unaffected — which is the only thing that
  distinguishes a genuinely per-theme extractor from one reading the file
  globally.

  Four further arrangements, each closing a way this could pass while proving
  nothing:

    * Values are extracted from inside the NAMED plugin theme block
      specifically, never file-wide. A matching value somewhere else in a
      7200-line stylesheet must not be able to satisfy this test.
    * Extraction failure raises. A regex that finds nothing must not return
      `nil` that then compares equal to something, and must not skip.
    * The ground list is asserted non-empty and complete before it is looped
      over. A `for` comprehension is vacuously satisfied by `[]`, so an
      extractor that matched no grounds would otherwise read as compliant
      having measured nothing.
    * Contrast and the `@theme inline` mapping are asserted separately, because
      neither can see the other's failure. Contrast arithmetic is blind to a
      missing utility (the var resolves fine; Tailwind just never mints
      `ring-focus-ring` and call sites fall back to `currentColor`), and the
      mapping is blind to a ring that is registered and unreadable. That
      independence is what mutation M2 checks.

  ## Every ratio here is computed, not transcribed

  Ratios come from `Platform.Design.WcagContrast` over the declarations parsed
  out of the stylesheet. No resolved colour is typed at a call site, and the
  comments in `app.css` are deliberately not a source: they are known to drift.
  The worked example was light `--color-base-200`, commented `#F5F5F5` while it
  rendered `#F2F2F2`; task 01a09333-d374 stage 6 corrected that comment, and
  not one ratio below moved, because none of them was reading it.

  `WcagContrast` carries floats through an `oklch()` conversion rather than
  quantizing to 8-bit first. That float-through convention belongs to the
  declaration-derived figures, e.g. the `.chip-soft` alpha ceilings; the figures
  `app.css` labels painted-pixel ("MEASURED ... in a browser") are hex-to-hex,
  and `WcagContrast.contrast_painted/2` is the named mechanism for that
  quantity. It matters here: quantizing light `--color-base-200` to `#F2F2F2`
  before measuring gives 4.1990:1 rather than 4.1847:1, and light
  `--color-base-300` gives 3.2661:1 rather than 3.2747:1. Both conventions
  clear the 3:1 floor, so nothing about the decision turns on it, but the
  pinned figures below are the float-through ones and a reader comparing them
  against a quantize-first calculator should expect the third decimal to
  disagree.

  ## What this test must not touch

  `.focus-visible-ring:focus-visible` and the `.input`/`.textarea`/`.select`
  no-offset variant still read `var(--color-primary)`; that is task
  `01a0785c`'s territory, and `primary_contrast_sweep_test.exs` has a case
  asserting the outer band still draws from `var(--color-primary)`.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.WcagContrast

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)

  # WCAG 2.2 SC 1.4.11 Non-text Contrast. Not a tunable: if a ring cannot clear
  # this against a ground it is adjacent to, the finding is that the colour is
  # wrong, never that the floor is too high.
  @min_ratio 3.0

  # The three page grounds every ring is drawn against. Asserted against what
  # the stylesheet actually declares, so an added or renamed ground surfaces as
  # a failure rather than going unmeasured.
  @grounds ["--color-base-100", "--color-base-200", "--color-base-300"]

  # The ratio each pair measures today, pinned to 4 decimals as well as
  # floored. A re-tune that still technically clears 3:1 therefore cannot land
  # silently — someone has to come here and say what the new number is.
  @light_ratios %{
    "--color-base-100" => 4.7007,
    "--color-base-200" => 4.1847,
    "--color-base-300" => 3.2747
  }

  @dark_ratios %{
    "--color-base-100" => 9.6304,
    "--color-base-200" => 11.5762,
    "--color-base-300" => 10.1049
  }

  setup_all do
    {:ok, css: File.read!(@css_path)}
  end

  # ── (a) the instrument ────────────────────────────────────────────────────

  describe "(a) the colour parser" do
    test "WcagContrast reproduces the oklch grounds this file declares" do
      known = [
        {"oklch(96% 0 0)", "#F2F2F2", "light --color-base-200"},
        {"oklch(88% 0 0)", "#D7D7D7", "light --color-base-300"},
        {"oklch(9% 0.018 240)", "#000306", "dark --color-base-200"},
        {"oklch(20% 0.028 240)", "#091821", "dark --color-base-300"}
      ]

      for {input, expected, slot} <- known do
        actual = input |> WcagContrast.parse!() |> WcagContrast.to_hex()

        assert actual == expected,
               "Platform.Design.WcagContrast turns #{input} (#{slot}) into #{actual}, " <>
                 "but that declaration renders #{expected}. Every ratio in this file is " <>
                 "computed with that module, so a wrong converter makes them all pass " <>
                 "for the wrong reason. Fix the converter before reading any other " <>
                 "failure here."
      end
    end
  end

  # ── (b) light theme ───────────────────────────────────────────────────────

  describe "(b) light theme: the focus ring clears SC 1.4.11" do
    test "the light plugin block declares a --focus-ring that resolves to a colour", %{css: css} do
      assert_declares_resolvable_ring(css, "light")
    end

    test "the light grounds are extracted before anything loops over them", %{css: css} do
      assert_grounds_extracted(css, "light")
    end

    test "the light ring is >= 3.0:1 on every light ground, at the pinned ratio", %{css: css} do
      assert_ring_clears_floor(css, "light", @light_ratios)
    end
  end

  # ── (c) dark theme ────────────────────────────────────────────────────────

  describe "(c) dark theme: the focus ring clears SC 1.4.11" do
    test "the dark plugin block declares a --focus-ring that resolves to a colour", %{css: css} do
      assert_declares_resolvable_ring(css, "dark")
    end

    test "the dark grounds are extracted before anything loops over them", %{css: css} do
      assert_grounds_extracted(css, "dark")
    end

    test "the dark ring is >= 3.0:1 on every dark ground, at the pinned ratio", %{css: css} do
      assert_ring_clears_floor(css, "dark", @dark_ratios)
    end
  end

  # ── (d) the Tailwind colour key ───────────────────────────────────────────

  describe "(d) the ring-focus-ring utility" do
    test "@theme inline maps --color-focus-ring to var(--focus-ring)", %{css: css} do
      block = theme_inline_block(css)

      assert squish(block) =~ "--color-focus-ring: var(--focus-ring);",
             "the @theme inline block does not map --color-focus-ring to " <>
               "var(--focus-ring). The vendored assets/vendor/daisyui-theme.js plugin " <>
               "only calls addBase: it writes the keys it is handed as plain custom " <>
               "properties under [data-theme=...] and registers NOTHING with Tailwind's " <>
               "theme. So declaring --focus-ring in the theme blocks does not create a " <>
               "ring-focus-ring utility; this mapping does. Without it every call site " <>
               "falls back to currentColor — a failure that reads as a styling opinion " <>
               "rather than a bug. `inline` is load-bearing too: plain @theme freezes " <>
               "the value at :root and one theme's ring paints under both. The block " <>
               "reads:\n#{block}"
    end

    test "neither theme block declares --color-focus-ring, which would self-reference", %{
      css: css
    } do
      for theme <- ["light", "dark"] do
        refute Regex.match?(~r/^\s*--color-focus-ring\s*:/m, theme_block(css, theme)),
               "the #{theme} daisyui-theme block declares --color-focus-ring. The theme " <>
                 "blocks must declare the bare --focus-ring; @theme inline is what maps " <>
                 "--color-focus-ring to var(--focus-ring). Naming it --color-focus-ring " <>
                 "in the theme block makes that mapping self-referential and it breaks. " <>
                 "This is also why task 01a0785c's slot could not be promoted as " <>
                 "written: it declares --color-focus-ring directly."
      end
    end
  end

  # ── the assertions themselves ─────────────────────────────────────────────

  # Two facts, both load-bearing: the declaration is in the theme's OWN plugin
  # block (not merely somewhere in the file), and the chain it starts resolves
  # all the way to a parseable colour. resolve!/3 raises on any miss, so
  # reaching the shape assertion is itself the resolution proof.
  defp assert_declares_resolvable_ring(css, theme) do
    block = theme_block(css, theme)

    assert declaration(block, "--focus-ring"),
           "the #{theme} daisyui-theme plugin block does not declare --focus-ring. " <>
             "A declaration elsewhere in app.css does not count: the whole point of the " <>
             "slot is that each theme names its own ring colour, and a single " <>
             "file-wide declaration would paint one theme's ring under both."

    hex = css |> resolve!(theme, "--focus-ring") |> WcagContrast.to_hex()

    assert Regex.match?(~r/^#[0-9A-F]{6}$/, hex),
           "#{theme} --focus-ring resolved to #{inspect(hex)}, which is not a colour."
  end

  defp assert_grounds_extracted(css, theme) do
    found = declared_grounds(css, theme)

    refute found == [],
           "no --color-base-* declarations were extracted from the #{theme} " <>
             "daisyui-theme plugin block. The contrast test loops over this list, and a " <>
             "`for` over [] asserts nothing at all — it would report green having " <>
             "measured no pair. Fix the extractor."

    assert found == @grounds,
           "the #{theme} daisyui-theme plugin block declares grounds #{inspect(found)}, " <>
             "not #{inspect(@grounds)}. Either a ground was renamed or added, in which " <>
             "case the focus ring has to be measured against it too, or the extractor " <>
             "has drifted."
  end

  defp assert_ring_clears_floor(css, theme, pinned_ratios) do
    ring = resolve!(css, theme, "--focus-ring")
    grounds = declared_grounds(css, theme)

    refute grounds == [],
           "no grounds extracted for #{theme}; every assertion below would be vacuous. " <>
             "See the extraction test in this file."

    for ground <- grounds do
      ground_color = resolve!(css, theme, ground)
      ratio = WcagContrast.contrast(ring, ground_color)
      pinned = Map.fetch!(pinned_ratios, ground)

      assert ratio >= @min_ratio,
             "#{theme} --focus-ring (#{WcagContrast.to_hex(ring)}) against #{ground} " <>
               "(#{WcagContrast.to_hex(ground_color)}) is #{Float.round(ratio, 4)}:1, " <>
               "under the #{@min_ratio}:1 WCAG 2.2 SC 1.4.11 Non-text Contrast floor. A " <>
               "focus indicator this faint is the defect this slot exists to close — " <>
               "light --color-primary is 1.7875:1 on white. Do not lower the floor; " <>
               "change the colour."

      assert Float.round(ratio, 4) == pinned,
             "#{theme} --focus-ring (#{WcagContrast.to_hex(ring)}) against #{ground} " <>
               "(#{WcagContrast.to_hex(ground_color)}) now measures " <>
               "#{Float.round(ratio, 4)}:1, but this file pins #{pinned}:1. The floor is " <>
               "separately asserted, so this is not a pass/fail question about " <>
               "accessibility — it is that a token moved and nobody recorded the new " <>
               "number. Re-measure, update the figure here AND the ratio written in the " <>
               "app.css comment beside the declaration, and say in the commit which " <>
               "token moved."
    end
  end

  # ── extraction ────────────────────────────────────────────────────────────

  # Resolves a custom property to a colour the way the cascade does for the
  # given theme: the theme's own plugin block first, then the theme-scoped
  # selectors, then :root. A `var(--x)` value is followed rather than parsed,
  # which is what lets --focus-ring be declared as an alias.
  #
  # Every failure path raises. A resolver that returned nil on a miss would let
  # a deleted declaration compare equal to another deleted declaration.
  defp resolve!(css, theme, var, seen \\ [])

  defp resolve!(_css, theme, var, seen) when length(seen) > 8 do
    flunk(
      "resolving #{var} in the #{theme} theme did not terminate; the chain was " <>
        "#{inspect(Enum.reverse(seen))}. A custom property in app.css points at itself, " <>
        "directly or through a cycle."
    )
  end

  defp resolve!(css, theme, var, seen) do
    value = lookup!(css, theme, var, seen)

    case Regex.run(~r/^var\(\s*(--[A-Za-z0-9_-]+)\s*\)$/, value) do
      [_, next] -> resolve!(css, theme, next, [var | seen])
      nil -> WcagContrast.parse!(value)
    end
  end

  defp lookup!(css, theme, var, seen) do
    scopes = scopes(css, theme)

    hits =
      Enum.flat_map(scopes, fn {label, blocks} ->
        blocks
        |> Enum.map(&declaration(&1, var))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&{label, &1})
      end)

    case hits do
      [] ->
        flunk(
          "no #{var} declaration reachable from the #{theme} theme. Searched, in " <>
            "cascade order: #{scopes |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}. " <>
            "Chain so far: #{inspect(Enum.reverse([var | seen]))}. This raises rather " <>
            "than returning nil on purpose: a missing declaration is the failure, not a " <>
            "reason to stop measuring."
        )

      [{_label, value} | _] ->
        case hits |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
          [_single] ->
            value

          _conflicting ->
            flunk(
              "#{var} is declared more than once with different values in the scopes " <>
                "that apply to the #{theme} theme: #{inspect(hits)}. Which one wins " <>
                "depends on source order and specificity, so this test refuses to guess " <>
                "rather than silently measuring the wrong one."
            )
        end
    end
  end

  # Cascade order, most specific first. The theme's plugin block is emitted
  # under [data-theme=<name>]; the hand-written selectors below it override
  # :root for the dark theme only. --color-interactive is the live example:
  # #087f93 at :root, #4dd7e8 under [data-theme="dark"].
  defp scopes(css, "light") do
    [
      {"the light daisyui-theme plugin block", [theme_block(css, "light")]},
      {":root", selector_blocks(css, ":root")}
    ]
  end

  defp scopes(css, "dark") do
    [
      {"the dark daisyui-theme plugin block", [theme_block(css, "dark")]},
      {~s([data-theme="dark"]), selector_blocks(css, ~s([data-theme="dark"]))},
      {":root", selector_blocks(css, ":root")}
    ]
  end

  # The --color-base-* grounds declared inside the named plugin block. Read out
  # of the stylesheet rather than assumed, and sorted so the comparison against
  # @grounds is about membership rather than declaration order.
  defp declared_grounds(css, theme) do
    ~r/^\s*(--color-base-(?:100|200|300))\s*:/m
    |> Regex.scan(theme_block(css, theme))
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp theme_block(css, name) do
    css
    |> plugin_blocks()
    |> Enum.find(&Regex.match?(~r/^\s*name:\s*"#{name}";/m, &1))
    |> case do
      nil ->
        flunk(
          "no `@plugin \"../vendor/daisyui-theme\"` block named #{inspect(name)} in " <>
            "#{@css_path}. The themes this test guards are gone."
        )

      block ->
        block
    end
  end

  defp plugin_blocks(css), do: blocks_after(css, @plugin_open, "a daisyui-theme plugin block")

  defp selector_blocks(css, selector),
    do: blocks_after(css, "\n" <> selector <> " {", "a `#{selector}` block")

  defp theme_inline_block(css) do
    case blocks_after(css, "@theme inline {", "the `@theme inline` block") do
      [] ->
        flunk(
          "no `@theme inline {` block in #{@css_path}. Plain `@theme` is not a " <>
            "substitute: it freezes the value at :root, so one theme's ring would be " <>
            "painted under both. The vendored daisyui-theme plugin registers nothing " <>
            "with Tailwind's theme on its own, so without this block there is no " <>
            "ring-focus-ring utility at all."
        )

      [block | _] ->
        block
    end
  end

  defp blocks_after(css, open, description) do
    css
    |> :binary.matches(open)
    |> Enum.map(fn {at, len} ->
      after_open = at + len
      rest = binary_part(css, after_open, byte_size(css) - after_open)

      case :binary.match(rest, "\n}") do
        {close, _} -> binary_part(rest, 0, close)
        :nomatch -> flunk("#{description} is never closed in #{@css_path}.")
      end
    end)
  end

  defp declaration(block, var) do
    case Regex.run(~r/^\s*#{Regex.escape(var)}\s*:\s*([^;]+);/m, block) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end

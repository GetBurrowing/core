defmodule Platform.Design.BorderTokenDirectionTest do
  @moduledoc """
  Pins the DIRECTION of the dark theme's border token in
  `apps/platform/assets/css/app.css`: `--edge` must be LIGHTER than the surface
  it is drawn on.

  ## The defect this closes

  Dark `--color-base-300` is `oklch(20% 0.028 240)`, which renders #091821.
  Dark `--color-base-100` is `#171b25`. So `border-base-300` on a `bg-base-100`
  card was #091821 on #171B25 — 1.0478:1, an edge nobody can see. Cards, inputs
  and panels shipped with borders that are not there.

  It could not be fixed by retuning `--color-base-300`, because that token also
  serves as a raised fill on the near-black `--color-base-200` ground (#000306),
  where being darker than the surrounding surface is correct (1.1463:1 the other
  way). One token, two jobs, opposite requirements. So the border job moved to
  its own slot, `--edge`.

  ## Why the assertions are shaped the way they are

  The cheap version of this test asserts that `--edge` is DEFINED. That version
  passes on the exact defect the ticket exists to close: point `--edge` back at
  `oklch(20% 0.028 240)` and a definition-only test stays green while every
  border in the product goes invisible again. So the assertion is on the
  RELATIONSHIP — luminance of `--edge` strictly greater than luminance of
  `--color-base-100`, plus a floor on the ratio — and it was verified to go red
  under exactly that mutation.

  Two further arrangements:

    * Both values are extracted from inside the `name: "dark"` plugin block
      specifically, never file-wide. A matching value somewhere else in a
      5900-line stylesheet must not be able to satisfy this test.
    * The oklch converter is checked against three known conversions before it
      is trusted for anything (test (a)). A wrong converter would make every
      assertion below pass for the wrong reason.

  ## Burrow (task 01a120c5)

  The Burrow palette replaced every value named above: dark base-100 is
  #191b20, base-200 #111214, base-300 #25272b (now LIGHTER than the panel) and
  --edge #383b42 (1.5361:1). Light base-100 is #fbfaf9 and light --edge is its
  own warm grey, #d9d3c9, no longer a copy of base-300 (#efebe7 is only
  1.1376:1 on the surface). The directions this file pins are unchanged. The
  history below is the pre-Burrow record.

  ## Light is the opposite direction, on purpose

  Light `--color-base-100` is pure white, so a LIGHTER edge is arithmetically
  impossible there, and light `--color-base-300` on white is already 1.4393:1 —
  a visible edge. This defect is dark-theme only. Light `--edge` is therefore
  declared byte-identically to light `--color-base-300`, which is what keeps the
  light theme pixel-identical to what shipped before this ticket. Test (c) pins
  both halves of that: the identical declaration text, and the inverted
  direction.

  ## The utility has to exist

  The vendored `assets/vendor/daisyui-theme.js` plugin only calls `addBase`. It
  writes the keys it is handed as plain custom properties under the
  `[data-theme=...]` selector and registers NOTHING with Tailwind's theme, which
  is why `--color-pipeline-human` is consumed as an inline `var(...)` and has no
  `bg-pipeline-human` utility anywhere in the repo. Declaring `--edge` in the
  theme blocks alone therefore does not create a `border-edge` utility; the
  `@theme inline` block does, and `inline` is load-bearing so the utility emits
  `border-color: var(--edge)` and resolves per theme at the element instead of
  being frozen at `:root`. Test (d) pins it, because without it every renamed
  call site silently falls back to `currentColor` — a failure that looks like a
  styling opinion rather than a bug.

  ## The call sites have to have moved (stage 2)

  A correct token nothing points at fixes nothing, so test (e) pins the residue:
  after the repoint, `border-base-300` may survive only as backticked prose in a
  comment, or at a site on the `@allowed_live` list below, where the element
  carries `border-base-300` AND `bg-base-300` and the sameness is the point.

  Three things are pinned separately because each covers a different way the
  rule rots. The unexpected-sites test catches a new or reverted call site. The
  stale-entry test catches an allowlist that outlived its call site, which would
  otherwise leave a hole the scan cannot see through. The count test catches a
  SECOND occurrence inside an already-allowlisted file, which the substring
  match would happily wave through. The fourth test requires the reason to be
  written at the site, since an allowlist entry with no explanation next to the
  code is indistinguishable from an oversight the next reader will "fix".

  The scan covers `test/` as well as `lib/` and `assets/`. A test still
  asserting the old class is how a repoint half-lands while the suite stays
  green.
  """
  use ExUnit.Case, async: true

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  # The floor was set just under the pre-Burrow 1.1966:1 so a re-tune has a
  # little room, and well above the 1.0478:1 defect so the defect cannot creep
  # back. The Burrow edge clears it at 1.5361:1 (task 01a120c5).
  @min_dark_edge_ratio 1.15

  @app_root Path.expand("../../..", __DIR__)

  # Where a border-base-300 could hide. Deliberately covers test/ too: a stale
  # assertion pinning the old class is how the repoint half-lands, green.
  @scan_globs [
    "lib/**/*.ex",
    "lib/**/*.heex",
    "assets/css/**/*.css",
    "assets/js/**/*.js",
    "assets/test/**/*.js",
    "test/**/*.exs"
  ]

  # Sites where the element carries border-base-300 AND bg-base-300, and the
  # sameness is the point. Repointing these draws a ring that was never meant
  # to be there. Each one must also carry the reason at the site.
  #
  # Empty since task 01a1557a stage 3, which deleted its only entry: the
  # unreachable `Layouts.theme_toggle/1` pill (its 2px border was a structural
  # gutter matched to the fill). The tests below still hold for an empty list:
  # a new collision site has to be added here with its reason.
  @allowed_live []

  # Prose convention in this repo: a class name discussed in a comment or a
  # docstring is wrapped in backticks. That is what separates a mention from a
  # use here. It is a convention, not a parser. A future unbackticked prose
  # mention will red this suite, and the fix is to backtick it.
  @prose_mention ~r/`[^`\n]*border-base-300[^`\n]*`/

  # This file is the one place that must name the token in live code: the
  # allowlist, the scan itself and every failure message spell it out. Scanning
  # itself would make the suite permanently red for the wrong reason.
  @self Path.relative_to(__ENV__.file, Path.expand("../../..", __DIR__))

  setup_all do
    css = File.read!(@css_path)

    {:ok, css: css, light: theme_block(css, "light"), dark: theme_block(css, "dark")}
  end

  # ── (a) the instrument ────────────────────────────────────────────────────

  describe "(a) the oklch converter" do
    test "reproduces three known oklch → sRGB conversions" do
      known = [
        {"oklch(20% 0.028 240)", "#091821", "dark --color-base-300"},
        {"oklch(9% 0.018 240)", "#000306", "dark --color-base-200"},
        {"oklch(88% 0 0)", "#D7D7D7", "light --color-base-300"}
      ]

      for {input, expected, slot} <- known do
        actual = input |> to_rgb255() |> hex()

        assert actual == expected,
               "the converter in this test module turns #{input} (#{slot}) into " <>
                 "#{actual}, but that value renders #{expected}. Every luminance " <>
                 "assertion below is computed with this converter, so a wrong " <>
                 "converter makes them all pass for the wrong reason. Fix the " <>
                 "converter before reading any other failure in this file."
      end
    end
  end

  # ── (b) the relationship, dark theme ──────────────────────────────────────

  describe "(b) dark theme: --edge is lighter than the surface" do
    test "--edge luminance is strictly greater than --color-base-100 luminance", %{dark: dark} do
      edge = declaration(dark, "--edge")
      surface = declaration(dark, "--color-base-100")

      edge_lum = luminance(edge)
      surface_lum = luminance(surface)

      assert edge_lum > surface_lum,
             "dark --edge (#{edge} → #{hex(to_rgb255(edge))}, luminance " <>
               "#{edge_lum}) is not lighter than dark --color-base-100 " <>
               "(#{surface} → #{hex(to_rgb255(surface))}, luminance " <>
               "#{surface_lum}). A border DARKER than the surface it sits on is " <>
               "the exact defect this token exists to fix: --color-base-300 was " <>
               "1.0478:1 against this surface and shipped invisible. The border " <>
               "must be lighter than the pane in dark, not darker."
    end

    test "the dark edge clears the #{@min_dark_edge_ratio}:1 perceptibility floor", %{dark: dark} do
      edge = declaration(dark, "--edge")
      surface = declaration(dark, "--color-base-100")

      ratio = contrast_ratio(luminance(edge), luminance(surface))

      assert ratio >= @min_dark_edge_ratio,
             "dark --edge vs --color-base-100 is #{ratio}:1, under the " <>
               "#{@min_dark_edge_ratio}:1 floor. The approved value #232A38 gives " <>
               "1.1966:1; the defect value oklch(20% 0.028 240) gives 1.0478:1. " <>
               "A value in between is a border that is technically present and " <>
               "practically still invisible."
    end

    test "the dark edge is not just base-300 wearing a new name", %{dark: dark} do
      assert declaration(dark, "--edge") != declaration(dark, "--color-base-300"),
             "dark --edge and dark --color-base-300 have the same value. The " <>
               "whole point of splitting the slot is that base-300 keeps its " <>
               "raised-fill job on the near-black --color-base-200 ground, where " <>
               "being dark is correct, while --edge takes the border job, where " <>
               "being dark is the bug."
    end
  end

  # ── (c) light does not move ───────────────────────────────────────────────

  describe "(c) light theme: unchanged, and deliberately the other direction" do
    # Was "declared byte-identically to light --color-base-300". The Burrow
    # spec (task 01a120c5) gives light its own edge, because Burrow base-300 is
    # too faint against the surface to be one. What is pinned now is that the
    # light edge is at least as visible as base-300 would have been.
    test "light --edge is darker than light --color-base-300, a stronger edge", %{light: light} do
      edge_lum = luminance(declaration(light, "--edge"))
      base_300_lum = luminance(declaration(light, "--color-base-300"))

      assert edge_lum < base_300_lum,
             "light --edge (luminance #{edge_lum}) is not darker than light " <>
               "--color-base-300 (luminance #{base_300_lum}); an edge fainter than " <>
               "the raised fill does not separate anything."
    end

    test "light --edge is DARKER than light --color-base-100, the opposite of dark", %{
      light: light
    } do
      edge_lum = luminance(declaration(light, "--edge"))
      surface_lum = luminance(declaration(light, "--color-base-100"))

      assert edge_lum < surface_lum,
             "light --edge (luminance #{edge_lum}) is not darker than light " <>
               "--color-base-100 (luminance #{surface_lum}). Light base-100 is " <>
               "near-white, so a lighter edge is barely possible; the direction is " <>
               "inverted between themes on purpose."
    end
  end

  # ── (d) the utility exists ────────────────────────────────────────────────

  describe "(d) the Tailwind colour key" do
    test "app.css maps --color-edge to var(--edge) in an @theme inline block", %{css: css} do
      block = theme_inline_block(css)

      assert squish(block) =~ "--color-edge: var(--edge);",
             "the @theme inline block does not map --color-edge to var(--edge). " <>
               "Without that mapping Tailwind emits no .border-edge utility at " <>
               "all, and every call site using it falls back to currentColor — a " <>
               "failure that reads as a styling opinion rather than a bug. The " <>
               "block reads:\n#{block}"
    end

    test "neither theme block declares --color-edge, which would self-reference", %{
      light: light,
      dark: dark
    } do
      for {name, block} <- [{"light", light}, {"dark", dark}] do
        refute Regex.match?(~r/^\s*--color-edge\s*:/m, block),
               "the #{name} daisyui-theme block declares --color-edge. The theme " <>
                 "blocks must declare --edge; @theme inline is what maps " <>
                 "--color-edge to var(--edge). Declaring --color-edge in the theme " <>
                 "block makes that mapping self-referential and it breaks."
      end
    end
  end

  # ── (e) call-site residue ─────────────────────────────────────────────────

  describe "(e) call-site residue" do
    test "no live border-base-300 call site survives outside the allowlist" do
      unexpected =
        live_occurrences()
        |> Enum.reject(&allowlisted?/1)

      assert unexpected == [],
             "border-base-300 is still used as a border colour at " <>
               "#{length(unexpected)} call site(s) outside the allowlist. The " <>
               "token is a FILL token now; borders come from --edge via the " <>
               "border-edge class (task 01a0740b). Either repoint the site, or " <>
               "add it to @allowed_live in this file with the reason its " <>
               "border and fill are meant to be the same colour.\n\n" <>
               render(unexpected)
    end

    test "every allowlist entry still matches a real call site" do
      live = live_occurrences()

      stale =
        Enum.reject(@allowed_live, fn {path, needle, _why} ->
          Enum.any?(live, fn {p, _l, line} ->
            p == path and String.contains?(line, needle)
          end)
        end)

      assert stale == [],
             "these @allowed_live entries no longer match anything. An " <>
               "allowlist that outlives its call sites stops being a record of " <>
               "a decision and starts being a hole this test cannot see " <>
               "through. Delete them:\n\n" <>
               Enum.map_join(stale, "\n", fn {path, needle, _why} ->
                 "  #{path}: #{needle}"
               end)
    end

    test "the allowlist is exactly as long as the set of live call sites" do
      live = live_occurrences()

      assert length(live) == length(@allowed_live),
             "there are #{length(live)} live border-base-300 call sites but " <>
               "#{length(@allowed_live)} allowlist entries. A second occurrence " <>
               "in an allowlisted FILE is waved through by the substring match " <>
               "in the test above, so the count is pinned separately.\n\n" <>
               render(live)
    end

    test "each allowlisted site carries a comment explaining the collision" do
      for {path, _needle, _why} <- @allowed_live do
        source = File.read!(Path.join(@app_root, path))

        assert source =~ "DELIBERATELY still on `border-base-300`",
               "#{path} is allowlisted as a deliberate border/fill collision " <>
                 "but carries no comment saying so. The next person to read " <>
                 "this file must find the decision at the site, not in a task " <>
                 "description. Write it down."
      end
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp live_occurrences do
    for glob <- @scan_globs,
        path <- Path.wildcard(Path.join(@app_root, glob)),
        Path.relative_to(path, @app_root) != @self,
        {line, number} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
        String.contains?(line, "border-base-300"),
        not Regex.match?(@prose_mention, line) do
      {Path.relative_to(path, @app_root), number, String.trim(line)}
    end
  end

  defp allowlisted?({path, _number, line}) do
    Enum.any?(@allowed_live, fn {allowed_path, needle, _why} ->
      path == allowed_path and String.contains?(line, needle)
    end)
  end

  defp render(occurrences) do
    Enum.map_join(occurrences, "\n", fn {path, number, line} ->
      "  #{path}:#{number}\n    #{line}"
    end)
  end

  @plugin_open ~s(@plugin "../vendor/daisyui-theme" {)

  # The body of the daisyui-theme plugin block carrying `name: "<name>";`.
  # Deliberately block-scoped: a value that happens to appear elsewhere in
  # app.css must not be able to satisfy any assertion above.
  defp theme_block(css, name) do
    css
    |> plugin_blocks()
    |> Enum.find(&Regex.match?(~r/^\s*name:\s*"#{name}";/m, &1))
    |> case do
      nil ->
        flunk(
          "no `@plugin \"../vendor/daisyui-theme\"` block named #{inspect(name)} " <>
            "in #{@css_path}. The themes this test guards are gone."
        )

      block ->
        block
    end
  end

  defp plugin_blocks(css) do
    css
    |> :binary.matches(@plugin_open)
    |> Enum.map(fn {at, len} ->
      after_open = at + len
      rest = binary_part(css, after_open, byte_size(css) - after_open)

      case :binary.match(rest, "\n}") do
        {close, _} -> binary_part(rest, 0, close)
        :nomatch -> flunk("a daisyui-theme plugin block is never closed in #{@css_path}.")
      end
    end)
  end

  defp theme_inline_block(css) do
    case :binary.match(css, "@theme inline {") do
      {at, len} ->
        after_open = at + len
        rest = binary_part(css, after_open, byte_size(css) - after_open)

        case :binary.match(rest, "\n}") do
          {close, _} -> binary_part(rest, 0, close)
          :nomatch -> flunk("the `@theme inline {` block is never closed in #{@css_path}.")
        end

      :nomatch ->
        flunk(
          "no `@theme inline {` block in #{@css_path}. Plain `@theme` is not a " <>
            "substitute: it freezes the value at :root, so one theme's edge would " <>
            "be used under both. The vendored daisyui-theme plugin registers " <>
            "nothing with Tailwind's theme on its own, so without this block there " <>
            "is no .border-edge utility."
        )
    end
  end

  # The value text of one custom-property declaration, anchored at line start
  # inside the given block.
  defp declaration(block, var) do
    case Regex.run(~r/^\s*#{Regex.escape(var)}\s*:\s*([^;]+);/m, block) do
      [_, value] ->
        String.trim(value)

      nil ->
        flunk("no `#{var}` declaration in this theme block. Block reads:\n#{block}")
    end
  end

  defp luminance(value), do: value |> to_rgb255() |> relative_luminance()

  defp to_rgb255("#" <> hex) do
    case String.downcase(String.trim(hex)) do
      <<r::binary-2, g::binary-2, b::binary-2>> ->
        Enum.map([r, g, b], &String.to_integer(&1, 16))

      other ->
        flunk(
          "cannot parse the hex colour " <>
            inspect("#" <> other) <> " — only 6-digit hex is supported here."
        )
    end
  end

  defp to_rgb255(value) do
    case Regex.run(~r/^oklch\(\s*([0-9.]+)%\s+([0-9.]+)\s+([0-9.]+)\s*\)$/, String.trim(value)) do
      [_, l, c, h] ->
        oklch_to_rgb255(num(l) / 100.0, num(c), num(h))

      nil ->
        flunk(
          "cannot parse colour value #{inspect(value)}. This test understands " <>
            "6-digit hex and `oklch(L% C H)`; extend the parser rather than " <>
            "weakening the assertion that needed it."
        )
    end
  end

  defp num(text) do
    case Float.parse(text) do
      {value, ""} -> value
      _ -> flunk("cannot parse #{inspect(text)} as a number.")
    end
  end

  # oklch → oklab → LMS → linear sRGB → gamma-encoded sRGB, Ottosson's
  # coefficients. Checked against three known values in test (a).
  defp oklch_to_rgb255(lightness, chroma, hue_deg) do
    hue = hue_deg * :math.pi() / 180.0
    a = chroma * :math.cos(hue)
    b = chroma * :math.sin(hue)

    l_ = lightness + 0.3963377774 * a + 0.2158037573 * b
    m_ = lightness - 0.1055613458 * a - 0.0638541728 * b
    s_ = lightness - 0.0894841775 * a - 1.2914855480 * b

    l = l_ * l_ * l_
    m = m_ * m_ * m_
    s = s_ * s_ * s_

    red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

    Enum.map([red, green, blue], fn channel ->
      channel |> gamma_encode() |> to_byte()
    end)
  end

  defp gamma_encode(channel) when channel <= 0.0031308, do: 12.92 * channel
  defp gamma_encode(channel), do: 1.055 * :math.pow(channel, 1 / 2.4) - 0.055

  defp to_byte(channel), do: channel |> max(0.0) |> min(1.0) |> Kernel.*(255) |> round()

  # WCAG 2.x relative luminance, taken on the 8-bit values the browser actually
  # paints rather than on the unquantised floats.
  defp relative_luminance([red, green, blue]) do
    0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
  end

  defp linearize(byte) do
    channel = byte / 255.0

    if channel <= 0.04045 do
      channel / 12.92
    else
      :math.pow((channel + 0.055) / 1.055, 2.4)
    end
  end

  defp contrast_ratio(one, other) do
    hi = max(one, other)
    lo = min(one, other)
    (hi + 0.05) / (lo + 0.05)
  end

  defp hex(rgb), do: "#" <> Base.encode16(:erlang.list_to_binary(rgb))

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end

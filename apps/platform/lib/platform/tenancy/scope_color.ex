defmodule Platform.Tenancy.ScopeColor do
  @moduledoc """
  Solves an org's scope colour ramp from a hue and a chroma. Pure — no Repo,
  no config, no I/O.

  ## Why this exists

  Task 01a09287. An org's colour used to be six hand-authored blocks in
  `app.css`, so standing up a tenant needed a deploy. The values in those
  blocks are not arbitrary: they are the solution to a contrast problem,
  which means they are computable, which means they never needed to be code.

  ## Why the answer is a PAIR, not a value

  The two theme grounds are 17.21:1 apart — light `--color-base-100` is
  `oklch(100% 0 0)`, dark is `#171b25`. WCAG AA as text needs 4.5:1, and a
  single colour that cleared 4.5 against both would need the grounds to be
  at least 4.5² = 20.25 apart. 17.21 < 20.25, so **no single colour clears
  AA as text on both themes**. `derive/2` therefore returns `label_light`
  and `label_dark` separately, and `fill` — the full-saturation dot / active
  pill value — is never used as text on a light ground.

  ## The solve

  `fill` is the starting point, and each label walks away from it until AA
  is met against EVERY ground that label will actually sit on. The chip's
  background is a tint of `fill` composited over the surface behind it, so
  the label's real background is that composite and not the base colour —
  and there is more than one of them. `cells/1` enumerates them: two tint
  alphas (resting 12%, hovered 22%) x two surfaces (`base-100`, the chat
  pane; `base-200`, the scope rail).

    * `label_light` — walk L DOWN from the fill in 0.5% steps until contrast
      is >= 4.5 against all four light composites.
    * `label_dark` — walk L UP from the fill in 0.5% steps until contrast
      is >= 4.5 against all four dark composites.

  `contrast_light` / `contrast_dark` report the WORST of those four, and
  `worst_light` / `worst_dark` name which cell it was. Solving and reporting
  read the same list, which is the point: until task 01a09287 stage 5 this
  module solved against the single resting-on-base-100 cell while the admin
  colour picker printed the worst of four from its own private copy of the
  enumeration. The picker therefore printed 3.74-3.81 — flat, at every hue
  on the circle, in light — and a shortfall that does not move with hue is a
  constant offset between two definitions rather than a property of any
  colour.

  Steps are half-percent, not whole. `app.css` records cyberdyne needing
  `55.5%` at hue 340 precisely because whole-percent steps overshoot the
  4.56-4.66 band there. Walking from the fill (rather than taking the
  minimal qualifying L) is what reproduces the shipped ramp: fabrikam's dark
  label is `72%`, its fill, even though `66.5%` already clears AA.

  ## Known divergence from the shipped CSS

  The six shipped `fill` lightnesses (72/80/70/68/65/66 percent) are NOT a
  function of hue and chroma — they were picked by hand and no rule
  reproduces all six. `derive/2` therefore uses a fixed 72% fill, the value
  the design canvas works through, and `derive/3`
  takes an explicit fill lightness for callers reproducing a shipped org.

  The six shipped LABELS diverge on a second axis too: they were solved
  against the resting-on-base-100 cell alone, so `derive/3` alone no longer
  reproduces them — a caller that wants the shipped pair passes
  `&tuned_cells/1` as `derive/4`'s cell set and thereby says out loud which
  narrower target it is reproducing. Re-solving the six against all four
  cells would move every shipped org's label darker on every install, which
  is a brand call filed as task 01a09333-d374 (sponsor Marlowe) and is
  deliberately NOT taken here. Nothing in this module writes `app.css`; the
  six stay on their hand-authored blocks and only orgs on the runtime var
  path are solved by `derive/2`.
  """

  @default_fill_lightness 0.72
  @step 0.005
  @aa 4.5
  @tint 0.12
  @default_chroma 0.15

  @light_ground {1.0, 1.0, 1.0}
  @dark_ground {0x17 / 255, 0x1B / 255, 0x25 / 255}

  # ── The cells a scope label actually lands in ────────────────────────
  #
  # THE single source of truth for "where does this label appear". It used
  # to be duplicated: this module solved against ONE cell (12% over
  # base-100) while `PlatformWeb.AdminOrgsLive` enumerated FOUR and printed
  # the worst. A solver aimed at the best of four, read against the worst of
  # four, fails by construction at every hue — measured flat at 3.74-3.81
  # across all 14 light hues a reviewer swept, and a shortfall that does not
  # move with hue is the signature of a constant offset between two
  # definitions, not of a colour problem. So the list lives HERE and the
  # panel reads it, which is what makes the two incapable of disagreeing
  # again.
  #
  # `tint` is the chip's background alpha: rest is `.scope-tint` / the
  # `bg-<slug>` 12% blocks, hovered is `chip_hover_classes/1`'s
  # `bg-<slug>/22` in `scope_pill.ex`. `surface` is what the chip sits on:
  # the chat pane is `bg-base-100`, the scope rail is `bg-base-200`.
  #
  # Surface values are read from the `:root` / `[data-theme=dark]` blocks in
  # app.css, NOT from the hex comments beside them — those comments are
  # known to drift, and app.css says so itself (light base-200 is
  # `oklch(96% 0 0)`, and the `#F5F5F5` note next to it is wrong by three
  # per channel).
  @surfaces %{
    light: [
      {"base-100", "oklch(100% 0 0)"},
      {"base-200", "oklch(96% 0 0)"}
    ],
    dark: [
      {"base-100", "#171b25"},
      {"base-200", "oklch(9% 0.018 240)"}
    ]
  }

  @tints [{"rest", 0.12}, {"hovered", 0.22}]

  @type cell :: %{tint: String.t(), surface: String.t(), alpha: float(), color: String.t()}

  @type ramp :: %{
          fill: String.t(),
          label_light: String.t(),
          label_dark: String.t(),
          contrast_light: float(),
          contrast_dark: float(),
          floor_light: float(),
          floor_dark: float(),
          worst_light: cell(),
          worst_dark: cell()
        }

  @doc """
  Every cell a scope-pill label lands in for `theme`, as data.

  Two tint alphas x two base surfaces. `derive/2` solves against the worst
  of these and `PlatformWeb.AdminOrgsLive` prints the worst of these; both
  read this function, so the number an operator approves is the number the
  solver met.
  """
  @spec cells(:light | :dark) :: [cell()]
  def cells(theme) when theme in [:light, :dark] do
    for {tint_name, alpha} <- @tints, {surface_name, surface} <- Map.fetch!(@surfaces, theme) do
      %{tint: tint_name, surface: surface_name, alpha: alpha, color: surface}
    end
  end

  @doc """
  The one cell the six shipped orgs in `app.css` were hand-tuned against:
  the resting 12% chip on `base-100`.

  It is the BEST of the four `cells/1` returns, which is exactly why it is
  not the solver's target any more. Exposed so a caller reproducing a
  shipped ramp can name the narrower target as an argument rather than
  inherit it silently — see the "Known divergence" note in the moduledoc.
  """
  @spec tuned_cells(:light | :dark) :: [cell()]
  def tuned_cells(theme) when theme in [:light, :dark] do
    cells(theme) |> Enum.filter(&(&1.tint == "rest" and &1.surface == "base-100"))
  end

  @doc """
  The chroma an org is stored and rendered at when it has none of its own.

  THE single naming of that value. `Platform.Tenancy`'s NULL fallback,
  `PlatformWeb.AdminOrgsLive`'s preview and `ScopeColorStyles`' emitter all
  read it here. It used to be written out in each of those three plus a
  fourth, different value (0.16) as a DB column default, so the panel
  previewed 0.15 while the row stored 0.16 and the rail painted 0.16 —
  three places naming a default, two answers. Task 01a09287 stage 5.
  """
  @spec default_chroma() :: float()
  def default_chroma, do: @default_chroma

  @doc """
  Solves the ramp for `hue` (0..359 degrees) and `chroma`, using the default
  fill lightness of 72% and targeting the worst of `cells/1`.
  """
  @spec derive(number(), number()) :: ramp()
  def derive(hue, chroma), do: derive(hue, chroma, @default_fill_lightness)

  @doc """
  Solves the ramp with an explicit fill lightness (0.0..1.0).

  Pass the shipped value when reproducing an existing org's ramp; see the
  "Known divergence" note in the moduledoc for why that is a parameter.
  """
  @spec derive(number(), number(), number()) :: ramp()
  def derive(hue, chroma, fill_lightness), do: derive(hue, chroma, fill_lightness, &cells/1)

  @doc """
  Solves the ramp against an explicit cell set.

  `cell_fun` is `(:light | :dark) -> [cell()]`. Pass `&tuned_cells/1` to
  reproduce a shipped org's hand-authored ramp, which was solved against the
  resting-on-base-100 cell alone. Anything on the runtime var path wants the
  default `&cells/1`.
  """
  @spec derive(number(), number(), number(), (atom() -> [cell()])) :: ramp()
  def derive(hue, chroma, fill_lightness, cell_fun)
      when is_number(hue) and is_number(chroma) and is_number(fill_lightness) and
             is_function(cell_fun, 1) do
    hue = hue * 1.0
    chroma = chroma * 1.0
    fill = oklch_string(fill_lightness, chroma, hue)

    light_grounds = grounds(fill, cell_fun.(:light))
    dark_grounds = grounds(fill, cell_fun.(:dark))

    l_light = walk(fill_lightness, chroma, hue, light_grounds, -@step)
    l_dark = walk(fill_lightness, chroma, hue, dark_grounds, @step)

    label_light = oklch_string(l_light, chroma, hue)
    label_dark = oklch_string(l_dark, chroma, hue)
    worst_light = worst(label_light, light_grounds)
    worst_dark = worst(label_dark, dark_grounds)

    %{
      fill: fill,
      label_light: label_light,
      label_dark: label_dark,
      contrast_light: worst_light.contrast,
      contrast_dark: worst_dark.contrast,
      floor_light: floor_contrast(oklch_to_srgb(l_light, chroma, hue), light_grounds),
      floor_dark: floor_contrast(oklch_to_srgb(l_dark, chroma, hue), dark_grounds),
      worst_light: worst_light,
      worst_dark: worst_dark
    }
  end

  @doc """
  The one-byte noise floor: the WORST contrast `rgb` reaches against any of
  `grounds` under a +/-1 perturbation of its green channel.

  ## Why green, and why perturb at all

  Solving to exactly 4.5 means shipping labels that fail on a rounding
  difference. Independently reproduced on two machines, three of the six
  shipped hues flip below 4.5 under a `+1` on the label's green channel —
  and a derived sRGB byte in this codebase has been wrong by one unit
  repeatedly. Green carries 0.7152 of the luminance sum, so it is the
  dominant sensitivity axis for five of the six.

  BOTH directions, not just `+1`. A light-theme label is darker than its
  ground, so `+1` costs contrast; a dark-theme label is LIGHTER than its
  ground, so `-1` is the harmful direction there. Perturbing one way would
  have bought the light theme a margin and the dark theme nothing, while
  reading as though both were covered.
  """
  @spec floor_contrast({float(), float(), float()}, [map()]) :: float()
  def floor_contrast({r, g, b}, grounds) do
    for candidate <- [{r, g, b}, {r, clamp(g + 1 / 255), b}, {r, clamp(g - 1 / 255), b}],
        ground <- grounds do
      contrast_rgb(candidate, ground.ground)
    end
    |> Enum.min()
  end

  defp clamp(x), do: x |> max(0.0) |> min(1.0)

  @doc """
  The WORST of `cells` for a `label` on a `fill`, as a cell map with a
  `:contrast` key and a human `:cell` name.

  Reports rather than repairs: the six shipped orgs in `app.css` are NOT
  solved through `derive/2` and most of them fail here, which is the
  pre-existing defect ticket 01a09333-d374 owns.
  """
  @spec worst_cell(String.t(), String.t(), :light | :dark) :: map()
  def worst_cell(fill, label, theme), do: worst(label, grounds(fill, cells(theme)))

  defp grounds(fill, cells) do
    Enum.map(cells, fn cell ->
      Map.put(cell, :ground, composite_ground(fill, cell.alpha, cell.color))
    end)
  end

  defp worst(label, grounds) do
    rgb = parse_color(label)

    grounds
    |> Enum.map(fn g ->
      g
      |> Map.put(:contrast, contrast_rgb(rgb, g.ground))
      |> Map.put(:cell, "#{g.tint} chip on #{g.surface}")
    end)
    |> Enum.min_by(& &1.contrast)
  end

  @doc """
  WCAG 2.1 contrast ratio between two colours, via OKLCH -> sRGB -> relative
  luminance.

  Both arguments accept an `oklch(L% C H)` string or a `#rrggbb` hex string;
  `ground` also accepts an already-composited `{r, g, b}` tuple as returned
  by `tint_ground/2`, since the ground a scope-pill label really sits on is
  a composite with no CSS colour literal of its own.
  """
  @spec contrast(String.t(), String.t() | {float(), float(), float()}) :: float()
  def contrast(color, ground) when is_binary(color) and is_binary(ground) do
    contrast_rgb(parse_color(color), parse_color(ground))
  end

  def contrast(color, {_, _, _} = ground) when is_binary(color) do
    contrast_rgb(parse_color(color), ground)
  end

  @doc """
  The sRGB tuple a `bg-<slug>` scope-pill tint composites to over `ground`.

  `ground` is `:light` or `:dark`; exposed so callers can check a label they
  did not derive here against the background it will really sit on.
  """
  @spec tint_ground(String.t(), :light | :dark) :: {float(), float(), float()}
  def tint_ground(fill, :light), do: composite(parse_color(fill), @tint, @light_ground)
  def tint_ground(fill, :dark), do: composite(parse_color(fill), @tint, @dark_ground)

  @doc """
  The sRGB tuple `fill` composites to at `alpha` over an arbitrary `surface`.

  `tint_ground/2` answers for the one cell the shipped ramp was tuned
  against — 12% over `--color-base-100`. It is not the only cell a scope
  chip appears in: the pill's hover state is `bg-<slug>/22` and the chat
  rail root is `bg-base-200`, so the same label also has to survive 22% over
  base-200. Measured, most of the shipped ramp does not. Callers that need
  to report the WORST cell rather than the tuned one compose it here.
  """
  @spec composite_ground(String.t(), number(), String.t()) :: {float(), float(), float()}
  def composite_ground(fill, alpha, surface) when is_binary(fill) and is_binary(surface) do
    composite(parse_color(fill), alpha * 1.0, parse_color(surface))
  end

  # ── solving ──────────────────────────────────────────────────────────

  # Walks L by `step` until AA is met against EVERY ground in `grounds`, not
  # just the first. `l` is clamped to [0,1]; at either end of that range the
  # contrast against a mid-tint ground is far above 4.5, so the guard is a
  # backstop and not the expected exit.
  #
  # NOTE the quantifier, and note that the target is the MARGIN and not the
  # threshold. This used to take one ground and the caller passed the tuned
  # cell, so the label cleared AA exactly where nobody was measuring it.
  # `floor_contrast/2` is over an EMPTY `grounds` an `Enum.min` on an empty
  # list, which RAISES rather than returning a vacuous pass — deliberately,
  # because a cell_fun returning [] would otherwise exit on the first
  # iteration and hand back the fill lightness at a contrast of 1.0.
  # `ScopeColorTest` pins both cell sets' lengths as well.
  defp walk(l, chroma, hue, grounds, step) do
    cond do
      floor_contrast(oklch_to_srgb(l, chroma, hue), grounds) >= @aa -> l
      step < 0 and l <= 0.0 -> 0.0
      step > 0 and l >= 1.0 -> 1.0
      true -> walk(round_half_percent(l + step), chroma, hue, grounds, step)
    end
  end

  defp round_half_percent(l), do: Float.round(l / @step) * @step

  # ── colour space ─────────────────────────────────────────────────────

  defp oklch_string(l, chroma, hue) do
    "oklch(#{trim(l * 100)}% #{trim(chroma)} #{trim(hue)})"
  end

  defp trim(value) do
    rounded = Float.round(value * 1.0, 4)
    int = trunc(rounded)
    if rounded == int * 1.0, do: Integer.to_string(int), else: Float.to_string(rounded)
  end

  @doc """
  The largest chroma at `lightness` and `hue` that is still inside the sRGB
  gamut, to within 0.0005.

  The hue ring in the admin colour picker needs this: reachable chroma runs
  from about 0.09 near hue 200 to about 0.28 near hue 295, so a ring drawn
  at ONE chroma all the way round asks the browser to clip more than half
  its own band. Two visibly different picks then paint as near-identical
  colours — the exact confusion the ring exists to prevent.

  Binary search on `in_gamut?/3`, which is monotone in chroma at fixed
  lightness and hue: the sRGB cube is convex and the OKLCH ray leaves it
  once.
  """
  @spec max_chroma(number(), number()) :: float()
  def max_chroma(lightness, hue) when is_number(lightness) and is_number(hue) do
    max_chroma(lightness * 1.0, hue * 1.0, 0.0, 0.5, 24)
  end

  defp max_chroma(_l, _h, lo, _hi, 0), do: lo

  defp max_chroma(l, h, lo, hi, fuel) do
    mid = (lo + hi) / 2

    if in_gamut?(l, mid, h),
      do: max_chroma(l, h, mid, hi, fuel - 1),
      else: max_chroma(l, h, lo, mid, fuel - 1)
  end

  @doc """
  True when `oklch(lightness chroma hue)` is inside the sRGB gamut, i.e. no
  LINEAR channel falls outside 0..1.

  This has to read the linear values, not `oklch_to_srgb/3`'s output:
  `encode/1` clips, so by the time a channel is a byte an out-of-gamut
  colour is indistinguishable from one that legitimately sits on the face
  of the cube.
  """
  @spec in_gamut?(number(), number(), number()) :: boolean()
  def in_gamut?(lightness, chroma, hue) do
    {r, g, b} = linear_srgb(lightness * 1.0, chroma * 1.0, hue * 1.0)
    Enum.all?([r, g, b], &(&1 >= -1.0e-9 and &1 <= 1.0 + 1.0e-9))
  end

  @doc """
  Linear-light sRGB for an OKLCH triple, BEFORE clipping and before the
  transfer function. Channels outside 0..1 mean the colour is out of gamut.
  """
  @spec linear_srgb(number(), number(), number()) :: {float(), float(), float()}
  def linear_srgb(l, chroma, hue) do
    h = hue * :math.pi() / 180.0
    a = chroma * :math.cos(h)
    b = chroma * :math.sin(h)

    l_ = cube(l + 0.3963377774 * a + 0.2158037573 * b)
    m_ = cube(l - 0.1055613458 * a - 0.0638541728 * b)
    s_ = cube(l - 0.0894841775 * a - 1.2914855480 * b)

    {
      4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
      -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
      -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
    }
  end

  @doc false
  def oklch_to_srgb(l, chroma, hue) do
    {r, g, b} = linear_srgb(l, chroma, hue)
    {encode(r), encode(g), encode(b)}
  end

  defp cube(x), do: x * x * x

  # CLIP to [0,1], THEN apply the sRGB transfer function. The order is the
  # whole point and it is not a rounding detail.
  #
  # More than half the hue circle is outside sRGB at the chromas this module
  # is used with — 186 of 360 light labels at C=0.15 — so out-of-gamut is
  # the common case here, not a corner. Chrome 152 resolves an out-of-gamut
  # `oklch()` by clipping each linear channel into range: `oklch(51% 0.15
  # 162)` has linear red -0.041996 and Chrome paints `rgb(0,127,74)`,
  # measured both as a canvas `fillStyle` and as a painted DOM background
  # read back out of a screenshot. Clipping first reproduces that
  # byte-for-byte on all four probes in `ScopeColorTest`.
  #
  # This function used to feed `abs(x)` to the transfer function instead, so
  # a negative channel came back POSITIVE (red 58 rather than 0) and the
  # downstream `max(0.0)` could never fire. That made every contrast figure
  # for an out-of-gamut colour a figure no browser paints — sxi read 4.37
  # where Chrome paints 4.56 — and the admin colour picker prints these
  # figures to an operator as the answer to "is this legible?". A preview
  # that lies is worse than no preview, so the sign fold is gone.
  defp encode(x) do
    x = x |> max(0.0) |> min(1.0)

    if x > 0.0031308 do
      1.055 * :math.pow(x, 1 / 2.4) - 0.055
    else
      12.92 * x
    end
  end

  defp composite({r, g, b}, alpha, {br, bg_, bb}) do
    {r * alpha + br * (1 - alpha), g * alpha + bg_ * (1 - alpha), b * alpha + bb * (1 - alpha)}
  end

  defp luminance({r, g, b}),
    do: 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)

  defp linearize(c) when c <= 0.04045, do: c / 12.92
  defp linearize(c), do: :math.pow((c + 0.055) / 1.055, 2.4)

  defp contrast_rgb(a, b) do
    la = luminance(a)
    lb = luminance(b)
    {hi, lo} = if la >= lb, do: {la, lb}, else: {lb, la}
    (hi + 0.05) / (lo + 0.05)
  end

  # ── parsing ──────────────────────────────────────────────────────────

  defp parse_color("#" <> hex) do
    hex = if String.length(hex) == 3, do: String.duplicate(hex, 2), else: hex
    <<r::binary-2, g::binary-2, b::binary-2>> = String.downcase(hex)
    {hex_byte(r), hex_byte(g), hex_byte(b)}
  end

  defp parse_color("oklch(" <> rest) do
    [l, c, h] =
      rest
      |> String.trim_trailing(")")
      |> String.replace("/", " ")
      |> String.split(~r/[\s,]+/, trim: true)
      |> Enum.take(3)
      |> Enum.map(&parse_component/1)

    oklch_to_srgb(l / 100.0, c, h)
  end

  defp parse_component(token) do
    {value, _unit} = Float.parse(token)
    value
  end

  defp hex_byte(pair), do: String.to_integer(pair, 16) / 255
end

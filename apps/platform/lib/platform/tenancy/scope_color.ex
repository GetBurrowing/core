defmodule Platform.Tenancy.ScopeColor do
  @moduledoc """
  Solves an org's scope colour ramp from a hue and a chroma. Pure — no Repo,
  no config, no I/O.

  ## Why this exists

  Task 01a09287. An org's colour used to be six hand-authored blocks in
  `app.css`, so standing up a tenant needed a deploy. The values in those
  blocks are not arbitrary: they are the solution to a contrast problem,
  which means they are computable, which means they never needed to be code.

  ## Why the answer is a PAIR per surface, not a value

  The two theme grounds are 17.21:1 apart: light `--color-base-100` is
  `oklch(100% 0 0)`, dark is `#171b25`. WCAG AA as text needs 4.5:1, and a
  single colour that cleared 4.5 against both would need the grounds to be
  at least 4.5² = 20.25 apart. 17.21 < 20.25, so **no single colour clears
  AA as text on both themes**. Every label therefore comes in a light and a
  dark value, and `fill` (the full-saturation dot and active pill value) is
  never used as text on a light ground.

  ## The solve: one ground per label (task 01a09333-d374)

  A chip sits on one of two surfaces, `base-100` (the chat pane and the page
  ground) or `base-200` (the scope rail), and `cells/1` enumerates them. For
  each theme and each surface `derive/3` computes:

    * the chip's OPAQUE tint: the fill at 12% composited over that surface
      and quantised to 8 bits by `composite_painted/3`, emitted as `#rrggbb`
      so the browser paints exactly these bytes and composites nothing;
    * that surface's label, solved against exactly ONE ground, its own
      opaque tint. Light walks L DOWN from the fill and dark walks L UP, in
      0.5% steps, until `floor_contrast/2` (the painted label under a +/-1
      move on its green channel) is at or above 4.5. That is the MARGIN
      target, not the threshold.

  Four tints and four labels, returned as named fields
  (`tint_light_100` ... `label_dark_200`). Only L moves, and only on the
  label: hue and chroma are the fill's, which is the "same hue + chroma,
  lower L" decision recorded in `app.css`'s scope-pill label block. A solver
  with a free label chroma clears every hue by going achromatic, and then
  the chip is no longer the org's colour.

  ### Why not the worst of four

  Until this change each label was solved against the worst of FOUR cells,
  two tint alphas (rest 12%, hover 22%) x two surfaces, because one label
  served every place a chip appears. The two themes fail in opposite places
  under that scheme: light in the rail and on hover, dark only on hover over
  base-100. And hover cannot be tuned back in: the largest tint alpha that
  keeps all twelve shipped cells at or above 4.5 is 0.130 in both themes,
  against a hover of 0.22, and 1.3 points of alpha is not a perceptible
  state change. So hover leaves the fill (it moves to the chip's edge), the
  surface is declared at the call site, and each label has exactly one
  ground. A test over slug x surface x theme is then COMPLETE rather than a
  sample of an open set, and the guard cannot inherit a compositing error
  because the browser composites nothing.

  Both sides of every figure here are PAINTED bytes: the tint as emitted,
  and the label as the browser quantises its `oklch()` string (reproduced
  exactly for all six shipped labels in `ScopeColorPaintedTest`).

  ## The edge: 3:1 against the page ground (task 01a09333-d374 stage 4)

  The chip's FILL is 1.07-1.14:1 against the surface behind it, so the fill
  has never given the chip a shape, and the old 30% alpha border measured
  1.17-1.41:1. WCAG 1.4.11 asks 3:1 for the visual boundary of an
  interactive component. The edge cannot be a higher alpha of the fill:
  four of the six shipped colours never reach 3:1 against white at ANY
  alpha (fully opaque, root 2.61, wayne-tech 2.83, sxi 2.51, paragon 1.87).

  So each cell also solves an `edge`: the fill's hue and chroma at a lower
  L, walked from the fill exactly as the label is (light DOWN, dark UP, in
  0.5% steps) until `floor_contrast/2` against the cell's PAGE GROUND (the
  surface itself, not the tint: the edge is the chip's outer boundary) is at
  or above 3.0. Same walk, same one-byte margin, a 3:1 target instead of
  4.5.

  Walking from the fill has the same consequence here as for the dark
  label: where the fill already holds, the edge IS the fill. At the default
  72% fill (`derive/2`) that is every dark cell, since the fill measures
  5.9-10.0:1 against the two dark grounds, and no light cell. At the
  shipped fills (`derive/3`) it is also both light cells of soylent (65%)
  and cyberdyne (66%).

  `edge_hover` is the hover edge, solved here as its own value so the
  browser paints exactly what was measured: `@hover_step` of L darker than
  `edge`, same hue and chroma. Hover changes the edge colour only, never the
  fill and never a width. `edge_rest_to_hover` records the contrast between
  the two, because a state carried by colour owes that figure as well as
  each state against its ground.

  `contrast_light` / `contrast_dark` report the WORST of the theme's cells
  and `worst_light` / `worst_dark` name it. `PlatformWeb.AdminOrgsLive`
  prints those fields and nothing else, so the number an operator approves
  is the number the solver met. Before task 01a09287 stage 5 the panel kept
  its own copy of the cell table and printed 3.74-3.81 flat at every hue in
  light; a shortfall that does not move with hue is a constant offset
  between two definitions rather than a property of any colour.

  Steps are half-percent, not whole. `app.css` records cyberdyne needing
  `55.5%` at hue 340 precisely because whole-percent steps overshoot the
  4.56-4.66 band there. Walking from the fill (rather than taking the
  minimal qualifying L) is what reproduces the shipped ramp: the root org's dark
  label is `72%`, its fill, even though a lower L already clears AA.

  ## Known divergence from the shipped CSS

  The six shipped `fill` lightnesses (72/80/70/68/65/66 percent) are NOT a
  function of hue and chroma — they were picked by hand and no rule
  reproduces all six. `derive/2` therefore uses a fixed 72% fill, the value
  the design canvas works through, and `derive/3` takes an explicit fill
  lightness for callers reproducing a shipped org. Since task 01a09333-d374
  stage 5 that lightness is DATA: the six rows carry it as
  `orgs.color_lightness`, and `ScopeColorStyles` solves an org with
  `derive/3` whenever its row has one.

  The six shipped labels were solved against the resting chip on base-100
  alone, which is now exactly the `base-100` cell. `derive/3` at each
  shipped fill reproduces 9 of the 12 shipped `-100` values exactly and the
  other three to within one 0.5% step, all in light: sxi moves one step
  DARKER (51% to 50.5%) because its shipped label has no margin (4.4974
  under +1 green), and soylent (55% to 55.5%) and wayne-tech (52% to 52.5%)
  move one step LIGHTER because the lighter value already holds with margin
  against the bytes this module emits. Those three moves are what the six
  paint on base-100 since stage 5 moved them onto this path; their rail
  labels are the `base-200` cells. In light those are darker than the one
  label each org used to wear on both surfaces, which failed AA in the
  rail; in dark four are unchanged and soylent and cyberdyne walk back to
  their fill. The byte-level gate
  on what the six emit is `ScopeColorStylesShippedSixTest`. Nothing in this
  module writes `app.css`.

  ## The one-byte rule

  Task 01a09333-d374. One byte is this pipeline's demonstrated uncertainty
  for any value that was not painted. Computed tints were compared against
  DOM swatches painted and read back pixel-wise, repeatedly, over two
  grounds and three alphas (12%, 22%, 30%): the two disagree by one unit,
  never more, in both directions, and no proposed mechanism for the
  disagreement survived an out-of-sample test. It is not symmetric. At
  alpha 0.30 the disagreements were consistently one unit LOW; on the twelve
  12% cells pinned in `Platform.Tenancy.ScopeColorPaintedTest` every miss is
  one unit HIGH.

  So a byte derived here is a claim to within one unit, and a contrast
  figure computed from derived bytes counts as passing only if it holds
  under a one-unit move. The margin each shipped org has, label against
  its painted 12% tint over base-100:

      org          painted   worst single +-1     worst all-channel +-1
      root          4.6121      4.5804                  4.5124   holds
      soylent      4.6375      4.6042                  4.5340   holds
      wayne-tech      4.6738      4.6224                  4.5706   holds
      sxi           4.5539      4.4974                  4.4535   CROSSES
      paragon      4.6724      4.6265                  4.5668   holds
      cyberdyne    4.6142      4.5854                  4.5161   holds

  `sxi` (Stark Industries, a live client) is the thin one. The single
  most sensitive move is one unit UP on the label's green, and on `sxi`
  that move alone gives 4.4974, under AA.

  `floor_contrast/2` is that green-channel move, in both directions, and it
  is what the solver walks against. It reproduces the "worst single" column
  for five of the six. cyberdyne's worst single move is on a channel other
  than green, so `floor_contrast/2` reports 4.5920 there where the column
  says 4.5854: the green-only floor overstates cyberdyne's margin by
  0.0066.

  Once a tint is emitted as opaque hex the one-byte uncertainty leaves the
  tint (the browser paints the bytes it is given) and stays only on the
  label, whose `oklch()` string the browser converts. The margin is kept
  anyway: it is the same number the rest of this module is calibrated to.
  """

  @default_fill_lightness 0.72
  @step 0.005
  @aa 4.5
  @tint 0.12
  @default_chroma 0.15

  # WCAG 1.4.11: the visual boundary of an interactive component.
  @edge_target 3.0
  # How much darker the hover edge is than the rest edge, in L. One solver
  # step, per the stage 4 decision; `edge_rest_to_hover` reports what it buys.
  @hover_step @step

  @light_ground {1.0, 1.0, 1.0}
  @dark_ground {0x17 / 255, 0x1B / 255, 0x25 / 255}

  # ── The surfaces a scope chip actually sits on ───────────────────────
  #
  # THE single source of truth for "where does this chip appear". It used
  # to be duplicated: this module solved against one cell while
  # `PlatformWeb.AdminOrgsLive` enumerated its own and printed the worst,
  # and the two disagreed by a constant at every hue. So the list lives
  # HERE, the solver walks it, and the panel prints what the solver
  # returns, which is what makes the two incapable of disagreeing again.
  #
  # `base-100` is the chat pane and the page ground; `base-200` is the scope
  # rail. The chip's tint is always 12% (`@tint`): hover no longer changes
  # the fill, so it is not a cell.
  #
  # Surface values are read from the `:root` / `[data-theme=dark]` blocks in
  # app.css, NOT from the hex comments beside them — those comments are
  # known to drift, and app.css says so itself. Light base-200 is the worked
  # example: `oklch(96% 0 0)` paints `#F2F2F2`, and the note beside it read
  # `#F5F5F5`, wrong by three per channel, until task 01a09333-d374 stage 6
  # corrected it. Reading the declaration is what made this module immune to
  # that while the comment was wrong. Keep reading the declaration.
  #
  # NOT YET BURROW (task 01a120c5 stage 1, deliberately deferred). app.css now
  # declares the Burrow grounds (light #fbfaf9 / #f6f4f1, dark #191b20 /
  # #111214, 16.53:1 apart, so the "no single colour" argument above still
  # holds). These four are the PRE-Burrow grounds, kept because the solved
  # ramps are pinned against browser-painted bytes in scope_color_test.exs,
  # scope_color_styles_shipped_six_test.exs and the scope pill tests, and
  # re-solving them needs a fresh painted gate, not a constant swap. The
  # nearest delta is small (white vs #fbfaf9; #171b25 vs #191b20), but it is
  # a delta: re-solve against the Burrow grounds as a follow-up.
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

  @type cell :: %{surface: String.t(), color: String.t(), alpha: float()}

  @typedoc """
  A cell with its solve: the opaque `tint` (`#rrggbb`), the `label`
  (`oklch(...)`), the label's painted contrast against the tint, its
  `floor` under `floor_contrast/2`, and a human `cell` name.

  The edge fields are measured against the cell's page ground (`color`),
  not its tint: `edge` / `edge_hover` (`oklch(...)`), their painted
  contrast and floor, `edge_on_tint` (the rest edge against the chip's own
  tint, for reference; nothing is solved to it) and `edge_rest_to_hover`
  (the contrast between the two edge states).
  """
  @type solved_cell :: %{
          surface: String.t(),
          color: String.t(),
          alpha: float(),
          tint: String.t(),
          label: String.t(),
          contrast: float(),
          floor: float(),
          edge: String.t(),
          edge_contrast: float(),
          edge_floor: float(),
          edge_hover: String.t(),
          edge_hover_contrast: float(),
          edge_hover_floor: float(),
          edge_on_tint: float(),
          edge_rest_to_hover: float(),
          cell: String.t()
        }

  @type ramp :: %{
          fill: String.t(),
          tint_light_100: String.t(),
          tint_light_200: String.t(),
          tint_dark_100: String.t(),
          tint_dark_200: String.t(),
          label_light_100: String.t(),
          label_light_200: String.t(),
          label_dark_100: String.t(),
          label_dark_200: String.t(),
          edge_light_100: String.t(),
          edge_light_200: String.t(),
          edge_dark_100: String.t(),
          edge_dark_200: String.t(),
          edge_hover_light_100: String.t(),
          edge_hover_light_200: String.t(),
          edge_hover_dark_100: String.t(),
          edge_hover_dark_200: String.t(),
          cells: %{light: [solved_cell()], dark: [solved_cell()]},
          contrast_light: float(),
          contrast_dark: float(),
          floor_light: float(),
          floor_dark: float(),
          worst_light: solved_cell(),
          worst_dark: solved_cell()
        }

  @doc """
  Every surface a scope chip sits on for `theme`, as data: one cell per
  surface, each carrying the tint alpha its opaque tint is composited at.

  `derive/3` solves one tint and one label per cell, and
  `PlatformWeb.AdminOrgsLive` prints the worst of what it solved, so the
  number an operator approves is the number the solver met.
  """
  @spec cells(:light | :dark) :: [cell()]
  def cells(theme) when theme in [:light, :dark] do
    for {surface_name, surface} <- Map.fetch!(@surfaces, theme) do
      %{surface: surface_name, color: surface, alpha: @tint}
    end
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
  The fill lightness an org is solved at when its row carries none.

  `derive/2` uses it. An org whose `color_lightness` is set (the six shipped
  orgs, task 01a09333-d374 stage 5) is solved with `derive/3` at its own.
  """
  @spec default_fill_lightness() :: float()
  def default_fill_lightness, do: @default_fill_lightness

  @doc """
  Solves the ramp for `hue` (0..359 degrees) and `chroma`, using the default
  fill lightness of 72%.
  """
  @spec derive(number(), number()) :: ramp()
  def derive(hue, chroma), do: derive(hue, chroma, @default_fill_lightness)

  @doc """
  Solves the ramp with an explicit fill lightness (0.0..1.0): per theme and
  per surface, an opaque tint and a label solved against that tint alone.

  Pass the shipped value when reproducing an existing org's ramp; see the
  "Known divergence" note in the moduledoc for why that is a parameter.
  """
  @spec derive(number(), number(), number()) :: ramp()
  def derive(hue, chroma, fill_lightness)
      when is_number(hue) and is_number(chroma) and is_number(fill_lightness) do
    hue = hue * 1.0
    chroma = chroma * 1.0
    fill = oklch_string(fill_lightness, chroma, hue)

    light = solve_theme(:light, fill, fill_lightness, chroma, hue)
    dark = solve_theme(:dark, fill, fill_lightness, chroma, hue)
    light_at = Map.new(light, &{&1.surface, &1})
    dark_at = Map.new(dark, &{&1.surface, &1})

    %{
      fill: fill,
      tint_light_100: Map.fetch!(light_at, "base-100").tint,
      tint_light_200: Map.fetch!(light_at, "base-200").tint,
      tint_dark_100: Map.fetch!(dark_at, "base-100").tint,
      tint_dark_200: Map.fetch!(dark_at, "base-200").tint,
      label_light_100: Map.fetch!(light_at, "base-100").label,
      label_light_200: Map.fetch!(light_at, "base-200").label,
      label_dark_100: Map.fetch!(dark_at, "base-100").label,
      label_dark_200: Map.fetch!(dark_at, "base-200").label,
      edge_light_100: Map.fetch!(light_at, "base-100").edge,
      edge_light_200: Map.fetch!(light_at, "base-200").edge,
      edge_dark_100: Map.fetch!(dark_at, "base-100").edge,
      edge_dark_200: Map.fetch!(dark_at, "base-200").edge,
      edge_hover_light_100: Map.fetch!(light_at, "base-100").edge_hover,
      edge_hover_light_200: Map.fetch!(light_at, "base-200").edge_hover,
      edge_hover_dark_100: Map.fetch!(dark_at, "base-100").edge_hover,
      edge_hover_dark_200: Map.fetch!(dark_at, "base-200").edge_hover,
      cells: %{light: light, dark: dark},
      contrast_light: worst(light).contrast,
      contrast_dark: worst(dark).contrast,
      floor_light: light |> Enum.map(& &1.floor) |> Enum.min(),
      floor_dark: dark |> Enum.map(& &1.floor) |> Enum.min(),
      worst_light: worst(light),
      worst_dark: worst(dark)
    }
  end

  # A light label is darker than its tint, so it walks DOWN; a dark label
  # is lighter than its tint, so it walks UP.
  defp solve_theme(theme, fill, fill_lightness, chroma, hue) do
    step = if theme == :light, do: -@step, else: @step
    Enum.map(cells(theme), &solve_cell(&1, fill, fill_lightness, chroma, hue, step))
  end

  # ONE ground per label: this cell's own opaque tint, as the bytes that
  # will be emitted. Nothing is composited against the label afterwards.
  defp solve_cell(cell, fill, fill_lightness, chroma, hue, step) do
    %{rgb: tint_bytes, hex: tint_hex} = composite_painted(fill, cell.alpha, cell.color)
    grounds = [%{ground: unit(tint_bytes)}]
    label = oklch_string(walk(fill_lightness, chroma, hue, grounds, step, @aa), chroma, hue)
    label_rgb = painted(label)

    cell
    |> Map.merge(%{
      tint: tint_hex,
      label: label,
      contrast: contrast_rgb(label_rgb, unit(tint_bytes)),
      floor: floor_contrast(label_rgb, grounds),
      cell: "chip on #{cell.surface}"
    })
    |> Map.merge(solve_edge(cell, fill_lightness, chroma, hue, step, unit(tint_bytes)))
  end

  # The chip's boundary, against the PAGE GROUND the chip sits on (the
  # surface), since the edge's outer neighbour is the page and not the tint.
  # Same walk as the label, 3:1 target. The hover edge is `@hover_step`
  # darker in L, in both themes.
  defp solve_edge(cell, fill_lightness, chroma, hue, step, tint) do
    page = painted(cell.color)
    grounds = [%{ground: page}]
    edge_l = walk(fill_lightness, chroma, hue, grounds, step, @edge_target)
    edge = oklch_string(edge_l, chroma, hue)
    hover = oklch_string(max(round_half_percent(edge_l - @hover_step), 0.0), chroma, hue)
    edge_rgb = painted(edge)
    hover_rgb = painted(hover)

    %{
      edge: edge,
      edge_contrast: contrast_rgb(edge_rgb, page),
      edge_floor: floor_contrast(edge_rgb, grounds),
      edge_hover: hover,
      edge_hover_contrast: contrast_rgb(hover_rgb, page),
      edge_hover_floor: floor_contrast(hover_rgb, grounds),
      edge_on_tint: contrast_rgb(edge_rgb, tint),
      edge_rest_to_hover: contrast_rgb(edge_rgb, hover_rgb)
    }
  end

  defp worst(solved), do: Enum.min_by(solved, & &1.contrast)

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

  RAISES on an empty `grounds` (`Enum.min/1` of an empty list) rather than
  returning a vacuous pass: a walk handed no ground would otherwise stop on
  its first step and hand back the fill lightness at a contrast of 1.0.
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

  `tint_ground/2` answers for 12% over `--color-base-100` only. Any other
  alpha or surface is composed here, in float. For a value that is emitted
  as CSS or compared against a painted swatch use `composite_painted/3`,
  which quantises this result once.
  """
  @spec composite_ground(String.t(), number(), String.t()) :: {float(), float(), float()}
  def composite_ground(fill, alpha, surface) when is_binary(fill) and is_binary(surface) do
    composite(parse_color(fill), alpha * 1.0, parse_color(surface))
  end

  @doc """
  The PAINTED colour `fill` at `alpha` composites to over `surface`: the
  8-bit sRGB bytes a browser puts on screen, as
  `%{rgb: {r, g, b}, hex: "#rrggbb"}` with each channel an integer 0..255.

  `composite_ground/3` answers the same question in float; this is its
  quantised sibling, and the one to use for any value that is emitted as CSS
  or compared against a painted swatch. At `alpha` 1.0 the result is `fill`
  alone, so this is also how an opaque label's painted bytes are read.

  ## Conventions

  Three conventions are binding here, and none of them announces itself in
  the output: every one of them returns three plausible bytes.

    1. **Compositing space: gamma-encoded sRGB**, as CSS does for a
       translucent background. Each encoded channel is
       `fill * alpha + surface * (1 - alpha)`. Compositing in linear light
       instead moves the six shipped orgs' light-theme label contrast by
       up to 0.36 (cyberdyne, 22% over base-100), and always UPWARD,
       toward a pass the browser does not paint.
    2. **Quantisation: 8-bit, applied ONCE, at the end.** The composite is
       carried in float and rounded to a byte one time. No intermediate is
       rounded: quantising the fill to bytes first and then compositing
       moves wayne-tech's 12% tint over base-100 by one byte (`#e4f4fd`,
       where the browser paints `#e3f4fd`) and leaves the other five
       shipped orgs unchanged, so the wrong order would ship unnoticed on
       five of six.
    3. **Gamut: clip each LINEAR channel to [0, 1], THEN apply the sRGB
       transfer function** (`encode/1`). Chrome does the same:
       `oklch(51% 0.15 162)` has linear red -0.041996 and Chrome paints
       `rgb(0, 127, 74)`.

  ## What this does not reproduce

  Against the twelve measured 12% tints (six orgs over base-100 and
  base-200, DOM swatches painted and read back pixel-wise), this matches
  seven exactly. The other five are one byte HIGH on one or two channels:
  soylent over base-100, and root, soylent, wayne-tech and paragon over
  base-200. `Platform.Design.WcagContrast`'s independent float path gives
  the same twelve values. No mechanism for that byte survived testing; see
  "The one-byte rule" in the moduledoc for what it means for a value
  nobody painted.
  """
  @spec composite_painted(String.t(), number(), String.t()) :: %{
          rgb: {0..255, 0..255, 0..255},
          hex: String.t()
        }
  def composite_painted(fill, alpha, surface)
      when is_binary(fill) and is_number(alpha) and alpha >= 0 and alpha <= 1 and
             is_binary(surface) do
    {r, g, b} = fill |> composite_ground(alpha, surface) |> quantise()
    %{rgb: {r, g, b}, hex: "#" <> hex_pair(r) <> hex_pair(g) <> hex_pair(b)}
  end

  # The one place a float channel becomes a byte. Called on a finished
  # composite only; see convention 2 in `composite_painted/3`.
  defp quantise({r, g, b}), do: {to_byte(r), to_byte(g), to_byte(b)}

  defp to_byte(x), do: round(clamp(x) * 255)

  # A colour as the browser paints it: converted, quantised once, back to
  # 0..1 for `contrast_rgb/2`.
  defp painted(color), do: color |> parse_color() |> quantise() |> unit()

  defp unit({r, g, b}), do: {r / 255, g / 255, b / 255}

  defp hex_pair(byte) do
    byte |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()
  end

  # ── solving ──────────────────────────────────────────────────────────

  # Walks L by `step` until the MARGIN is met against every ground in
  # `grounds`: `floor_contrast/2` at or above `target`, never the bare ratio.
  # `derive/3` walks twice per cell, each time against exactly one ground:
  # the label to 4.5 against the cell's own opaque tint, and the edge to 3.0
  # against the cell's page surface. `l` is clamped to [0,1]; at either end
  # of that range the contrast against any of these grounds is far above
  # the target, so the guard is a backstop and not the expected exit.
  #
  # The label is evaluated as the browser paints it: the `oklch()` string
  # that will be emitted, converted and quantised to bytes. So the figure is
  # about the exact emitted value, including its 4-decimal chroma and hue.
  #
  # An EMPTY `grounds` makes `floor_contrast/2` raise rather than pass
  # vacuously, which would otherwise exit here on the first iteration with
  # the fill lightness at a contrast of 1.0. `ScopeColorTest` pins that.
  defp walk(l, chroma, hue, grounds, step, target) do
    cond do
      floor_contrast(painted(oklch_string(l, chroma, hue)), grounds) >= target -> l
      step < 0 and l <= 0.0 -> 0.0
      step > 0 and l >= 1.0 -> 1.0
      true -> walk(round_half_percent(l + step), chroma, hue, grounds, step, target)
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

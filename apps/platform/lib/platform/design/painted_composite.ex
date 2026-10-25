defmodule Platform.Design.PaintedComposite do
  @moduledoc """
  The painted pixel of an ink at reduced strength (`p`%) over an opaque ground,
  as browsers actually rasterise it (task 01a1557a stage 5; generalised over
  the strength, and re-measured, in stage 5 round 2).

  Shared by the design guards and `Platform.Theming`'s contrast ledger (moved
  out of test support by task 01a1557a-fe9b stage 1).
  `Platform.Design.WcagContrast.composite/3` blends in float
  and is a fine model of the DECLARATION. It is not a model of the PIXEL. Two
  Chrome builds were measured, and Chrome 151 alone rasterises the same
  declaration through two different paths depending on the size of the box
  (exact on 8x8 boxes, 8-bit premultiplied on 10x20 boxes and on text). So no
  single formula is "what Chrome paints".

  Every formula takes the strength `p` as an integer percent; `A = round(p *
  255 / 100)` is the alpha byte (140 at 55%, 145 at 57%, 153 at 60%):

    * `:chrome_147_opacity`: `round(f*A/255) + (b*(256-A) >>> 8)`. Chrome 147's
      `opacity` path, exact on every pixel of its corpus at all three strengths.
    * `:chrome_151_half_up` / `:chrome_151_half_down`: the exact blend
      `(f*p + b*(100-p)) / 100` rounded to nearest, a .5 tie broken either way.
      Chrome 151 on small boxes.
    * `:chrome_151_premultiplied`: `round(f*p/100) + round(b*(255-A)/255)`.
      Chrome 151 on larger boxes and on text (the stage-5 "151 fit", now
      generalised over `p`).

  MEASURED (round 2, 180,090 channels: Chrome 151.0.7922.109 headless-shell on
  one test box and HeadlessChrome 147.0.7727.15 on another; 2001 ink/ground pairs at 55%,
  57% and 60%; the `color-mix(in oklab, ink p%, transparent)` path with a
  literal ink and with a `var()` ink, and the `opacity` path; 8x8 and 10x20
  boxes): every painted channel equals one of these four formulas. No subset
  of three does. `painted_composite_test.exs` asserts the same over the
  checked-in subset in `test/support/fixtures/painted_composite/`.

  NOT MODELLED: Chrome 147's TEXT path. A full-block glyph coloured
  `#000000` at 55% paints up to four levels lighter than every box path
  (#fbfaf9 ground: 117, not 113), while `#000006` paints exactly like a box.
  That is glyph rasterisation of pure black on one older build, recorded in
  the fixtures' `block_text_var` column and in the stage-5 r2 evidence, not a
  property of the colour.

  A pixel can take different formulas in different channels, so the guard does
  not take the minimum over whole-pixel formulas. `envelope/3` builds the worst
  pixel the four formulas allow: of every combination of per-channel formula
  values, the one with the least contrast against the ground.
  `contrast_min/3` measures that pixel. It also raises for a strength no
  browser has been painted at: these formulas are measurements, and an
  unmeasured alpha is an extrapolation.

  Painted by `paint_corpus_pct_01a1557a.mjs`
  (8x8) and `paint_paths_01a1557a.mjs` (10x20 and text); fitted by
  `an_subset_01a1557a.py` beside them. Inputs are `WcagContrast` colours
  (linear-light tuples), quantised to 8-bit sRGB first, because a ground on the
  page is already bytes.
  """

  alias Platform.Design.WcagContrast, as: W

  @type rgb8 :: {0..255, 0..255, 0..255}

  # TODO(new browser build): when a build paints a channel none of these
  # produce, paint the fixture cases against it at every measured strength,
  # add its CSV, and add the formula that explains it.
  @formulas [
    :chrome_147_opacity,
    :chrome_151_half_up,
    :chrome_151_half_down,
    :chrome_151_premultiplied
  ]

  # --subtle paints at 55% (57% in Burrow sand light); daisyUI's .label paints
  # base-content at 60%.
  @measured_strengths [55, 57, 60]

  @doc "The formulas whose union explains every painted channel measured."
  @spec formulas() :: [atom()]
  def formulas, do: @formulas

  @doc "The strengths (integer percent) every formula has been measured at."
  @spec measured_strengths() :: [pos_integer()]
  def measured_strengths, do: @measured_strengths

  @doc "The alpha byte a strength of `p` percent is stored as."
  @spec alpha_byte(0..100) :: 0..255
  def alpha_byte(p) when is_integer(p) and p in 0..100, do: round_div(p * 255, 100)

  @doc "The 8-bit painted pixel of `ink` at `p`% over `ground` under `formula`."
  @spec paint(atom(), rgb8(), rgb8(), pos_integer()) :: rgb8()
  def paint(formula, {fr, fg, fb}, {br, bg, bb}, p) do
    {channel(formula, fr, br, p), channel(formula, fg, bg, p), channel(formula, fb, bb, p)}
  end

  @doc """
  The worst pixel the formulas allow for `ink` at `p`% over `ground`: of every
  pixel whose channels each come from some formula (a browser was measured
  mixing them), the one with the least contrast against the ground.
  """
  @spec envelope(rgb8(), rgb8(), pos_integer()) :: rgb8()
  def envelope({fr, fg, fb}, {br, bg, bb} = ground, p) do
    options = fn f, b -> @formulas |> Enum.map(&channel(&1, f, b, p)) |> Enum.uniq() end
    g = from_bytes(ground)

    for(r <- options.(fr, br), gg <- options.(fg, bg), b <- options.(fb, bb), do: {r, gg, b})
    |> Enum.min_by(&W.contrast(from_bytes(&1), g))
  end

  @doc "Contrast of one formula's painted pixel against its ground."
  @spec contrast(atom(), W.color(), W.color(), pos_integer()) :: float()
  def contrast(formula, ink, ground, p) do
    g = bytes(ground)
    W.contrast(from_bytes(paint(formula, bytes(ink), g, p)), from_bytes(g))
  end

  @doc """
  The contrast of the worst painted pixel (`envelope/3`) at strength `p`, and
  the formulas that paint exactly that pixel (empty when no single formula
  does). Raises for an unmeasured strength.
  """
  @spec contrast_min(W.color(), W.color(), pos_integer()) :: {float(), [atom()]}
  def contrast_min(ink, ground, p) do
    unless p in @measured_strengths do
      raise ArgumentError,
            "no browser has been measured painting ink at #{p}% " <>
              "(measured: #{inspect(@measured_strengths)}); paint a corpus first"
    end

    {i, g} = {bytes(ink), bytes(ground)}
    worst = envelope(i, g, p)

    {W.contrast(from_bytes(worst), from_bytes(g)),
     for(f <- @formulas, paint(f, i, g, p) == worst, do: f)}
  end

  @doc "A `WcagContrast` colour as the 8-bit sRGB bytes it paints as."
  @spec bytes(W.color()) :: rgb8()
  def bytes(color) do
    "#" <> hex = W.to_hex(color)
    <<r::binary-2, g::binary-2, b::binary-2>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  @doc "8-bit bytes back to a `WcagContrast` colour."
  @spec from_bytes(rgb8()) :: W.color()
  def from_bytes({r, g, b}) do
    W.hex(Enum.map_join([r, g, b], &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0"))))
  end

  # Integer arithmetic throughout, so no float tie lands on the wrong byte.
  defp channel(:chrome_147_opacity, f, b, p) do
    a = alpha_byte(p)
    round_div(f * a, 255) + Bitwise.bsr(b * (256 - a), 8)
  end

  defp channel(:chrome_151_half_up, f, b, p), do: round_div(f * p + b * (100 - p), 100)
  defp channel(:chrome_151_half_down, f, b, p), do: round_div_down(f * p + b * (100 - p), 100)

  defp channel(:chrome_151_premultiplied, f, b, p),
    do: round_div(f * p, 100) + round_div(b * (255 - alpha_byte(p)), 255)

  # n / d rounded half up, and half down, for non-negative integers.
  defp round_div(n, d), do: div(2 * n + d, 2 * d)
  defp round_div_down(n, d), do: div(2 * n + d - 1, 2 * d)
end

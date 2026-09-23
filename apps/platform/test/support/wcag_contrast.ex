defmodule Platform.Design.WcagContrast do
  @moduledoc """
  WCAG 2.x contrast arithmetic over the colour forms `apps/platform/assets/css/app.css`
  actually declares: hex literals, `oklch()`, `color-mix(in oklab, ...)` and alpha
  compositing.

  Test-support only. Nothing in `lib/` uses it; it exists so a contrast assertion can
  be *computed from the stylesheet* rather than copied from a spreadsheet into an
  `assert ratio == 4.5`.

  ## Representation

  Every colour is carried as a `{r, g, b}` tuple of **linear-light** floats in 0..1
  (unclamped, because an out-of-gamut oklch intermediate is legal in the middle of a
  mix and only has to be clamped when it is measured or printed). Gamma-encoded sRGB
  appears only at the two boundaries: `hex/1` on the way in, `to_hex/1` on the way out.

  ## The quantization convention, and why it is float-through

  A mix or an oklch conversion lands between two 8-bit steps. You can either round it
  to the nearest `#rrggbb` before measuring, or carry the float straight into the
  luminance sum. The two answers differ in the third decimal of a contrast ratio.

  `contrast/2` carries the float. That is not a taste call: it is the convention the
  figures this module names were computed under, and the match is exact rather than
  close. The `.chip-soft` alpha-ceiling table — figures `app.css` derives from its
  declarations, not from a render — reads

      neutral 4.87868930, success 3.23613436, warning 2.21457697, error 3.89478250

  and this module reproduces all four to the last digit from the `oklch()` text of the
  tone tokens. Quantizing the tint first gives 4.88756921 / 3.23171346 / 2.21779607 /
  3.90669772 — wrong in the third decimal, four times over. The chip fill table's
  light `primary` cell (1.0666) reproduces the same way and not the other.

  The claim does NOT generalise past those declaration-derived figures. `app.css`
  records some figures as PAINTED-pixel measurements, and those were computed under
  the OTHER convention. Two candidate-rail blocks say so in their own words:

  * "The closed row that leads somewhere" (`app.css` ~line 6630): "MEASURED on the
    real rendered row in a browser (painted pixels, not palette arithmetic)".
  * "The closed row" (`app.css` ~line 7051): "MEASURED on the rendered rail in
    Chrome 152 (painted pixels sampled from a screenshot...)" — which adds "the
    corrected values reproduce from the tokens alone under the painted convention —
    quantize to 8 bits at each composite".

  The four anchors recorded there are 6.87 (neutral, light), 1.99 (neutral, dark),
  5.39 (spent foreground, light) and 3.78 (title-dead, light). Reproduced in this
  module's own math against the `--cc-bg-closed` grounds `#F4F5F7` / `#12151C`:

  | anchor | float-through | quantized to 8 bits | `app.css` records |
  |---|---|---|---|
  | neutral light: `oklch(45% 0.01 0)` on `#F4F5F7` | 6.8579 | 6.8674 | 6.87 |
  | neutral dark: `oklch(40% 0.01 0)` on `#12151C` | 1.9724 | 1.9853 | 1.99 |
  | spent fg light: `color-mix(in oklch, neutral 90%, white)` on `#F4F5F7` | 5.4101 | 5.3932 | 5.39 |
  | title-dead light: `#767D8D` on `#F4F5F7` | 3.7833 | 3.7833 | 3.78 |

  The dark anchor is the DARK theme's neutral — `oklch(40% 0.01 0)`, `app.css`
  ~line 238 — not the light 45% one; pairing against 45% "disproves" the table.
  Float-through misses every conversion-involved row by MORE than 0.005;
  quantize-to-8-bit reproduces every row within 0.005.

  A painted-pixel reading is ALWAYS hex-to-hex: the compositor quantizes the ground to
  8 bits before anything can sample it, so a screenshot read cannot see the float
  between steps. That quantity has its own name here — `contrast_painted/2`.

  ## How to tell a convention gap from a converter fault

  Two anchors settle which side is broken:

  * an exact converter clause: 21.0 white over black, 1.0 self-contrast,
    `oklch(100% 0 0)` → `#FFFFFF`;
  * a pure-hex anchor that must reproduce EXACTLY: `#767D8D` on `#F4F5F7` is
    bit-identical under both conventions, because with both endpoints already 8-bit
    sRGB there is nothing to convert or round.

  An exact clause plus a pure-hex anchor reproducing exactly, while conversion-
  involved anchors miss by a few ten-thousandths, is conclusive that the converter is
  sound and the gap is the convention: measure the painted quantity with
  `contrast_painted/2`. If the pure-hex anchor misses too, that is a real fault.
  `candidate_closed_row_contrast_test.exs` splits its anchors into exactly these two
  groups, and each failure message names which response it wants — the worked pattern.

  Where both endpoints of a pair are hex literals — which is most of the primary
  sweep — the convention makes no difference at all, because there is nothing to
  round.

  ## Sources

  * Relative luminance and the `(L1 + 0.05) / (L2 + 0.05)` ratio: WCAG 2.2, §
    "relative luminance" and "contrast ratio".
  * Oklab/Oklch matrices: Björn Ottosson's published sRGB constants, the same ones
    CSS Color 4 § 8.3 carries.
  * `color-mix(in oklab, A p%, B)`: CSS Color 5 § 3 — convert both to Oklab,
    interpolate each coordinate at `p`, convert back.
  """

  @typedoc "Linear-light sRGB, 0..1 per channel, deliberately unclamped."
  @type color :: {float(), float(), float()}

  # Oklab <-> linear sRGB (Ottosson). Rows of m1_inv sum to 1, which is why an
  # achromatic oklch(L% 0 0) is exactly L**3 in linear light.
  @lin_to_lms {
    {0.4122214708, 0.5363325363, 0.0514459929},
    {0.2119034982, 0.6806995451, 0.1073969566},
    {0.0883024619, 0.2817188376, 0.6299787005}
  }
  @lms_to_lab {
    {0.2104542553, 0.7936177850, -0.0040720468},
    {1.9779984951, -2.4285922050, 0.4505937099},
    {0.0259040371, 0.7827717662, -0.8086757660}
  }
  @lab_to_lms {
    {1.0, 0.3963377774, 0.2158037573},
    {1.0, -0.1055613458, -0.0638541728},
    {1.0, -0.0894841775, -1.2914855480}
  }
  @lms_to_lin {
    {4.0767416621, -3.3077115913, 0.2309699292},
    {-1.2684380046, 2.6097574011, -0.3413193965},
    {-0.0041960863, -0.7034186147, 1.7076147010}
  }

  @doc "Parses `#rgb` or `#rrggbb` into linear-light sRGB."
  @spec hex(binary()) :: color()
  def hex("#" <> digits), do: hex(digits)

  def hex(digits) when byte_size(digits) == 3 do
    <<r::binary-1, g::binary-1, b::binary-1>> = digits
    hex(r <> r <> g <> g <> b <> b)
  end

  def hex(digits) when byte_size(digits) == 6 do
    <<r::binary-2, g::binary-2, b::binary-2>> = digits

    {to_linear(byte(r)), to_linear(byte(g)), to_linear(byte(b))}
  end

  @doc """
  Converts `oklch(L C H)` to linear-light sRGB. `l` is 0..1 (not a percentage),
  `h` is degrees.
  """
  @spec oklch(number(), number(), number()) :: color()
  def oklch(l, c, h) do
    rad = h * :math.pi() / 180.0
    oklab({l, c * :math.cos(rad), c * :math.sin(rad)})
  end

  @doc "Converts an Oklab `{L, a, b}` triple to linear-light sRGB."
  @spec oklab({number(), number(), number()}) :: color()
  def oklab({l, a, b}) do
    {l_, m_, s_} = mul(@lab_to_lms, {l, a, b})
    mul(@lms_to_lin, {l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_})
  end

  @doc "Converts linear-light sRGB to an Oklab `{L, a, b}` triple."
  @spec to_oklab(color()) :: {float(), float(), float()}
  def to_oklab(color) do
    {l, m, s} = mul(@lin_to_lms, color)
    mul(@lms_to_lab, {cbrt(l), cbrt(m), cbrt(s)})
  end

  @doc """
  Parses the subset of CSS colour syntax that `app.css` declares tokens in:
  a hex literal or `oklch(L% C H)`. Anything else raises, deliberately — a
  silent fallback here would let a sweep measure a colour nobody declared.
  """
  @spec parse!(binary()) :: color()
  def parse!(value) do
    value = value |> String.trim() |> String.trim(";")

    cond do
      String.starts_with?(value, "#") ->
        hex(value)

      match = Regex.run(~r/^oklch\(\s*([\d.]+)%\s+([\d.]+)\s+([\d.]+)\s*\)$/, value) ->
        [_, l, c, h] = match
        oklch(to_float(l) / 100.0, to_float(c), to_float(h))

      true ->
        raise ArgumentError,
              "Platform.Design.WcagContrast.parse!/1 does not understand #{inspect(value)}. " <>
                "It handles hex literals and `oklch(L% C H)` only. If a token has been " <>
                "re-declared in another colour space, teach this function that space " <>
                "rather than hardcoding the resolved value at the call site."
    end
  end

  @doc """
  `color-mix(in oklab, a pct%, b)`. `pct` is the weight of `a`, 0..100.

  Both colours are opaque here, so there is no alpha premultiplication step; the
  stylesheet has no `color-mix` between translucent colours.
  """
  @spec mix_oklab(color(), number(), color()) :: color()
  def mix_oklab(a, pct, b) do
    p = pct / 100.0
    {al, aa, ab} = to_oklab(clamp(a))
    {bl, ba, bb} = to_oklab(clamp(b))

    oklab({
      al * p + bl * (1 - p),
      aa * p + ba * (1 - p),
      ab * p + bb * (1 - p)
    })
  end

  @doc """
  Composites `fg` at `alpha` over `bg`. Browsers blend in the gamma-encoded space
  for a plain `rgb(... / a)` background, so this encodes, mixes, and decodes rather
  than averaging linear light.
  """
  @spec composite(color(), number(), color()) :: color()
  def composite(fg, alpha, bg) do
    {fr, fg_, fb} = clamp(fg)
    {br, bg_, bb} = clamp(bg)

    blend = fn f, b -> to_linear_unit(from_linear(f) * alpha + from_linear(b) * (1 - alpha)) end

    {blend.(fr, br), blend.(fg_, bg_), blend.(fb, bb)}
  end

  @doc "WCAG 2.x relative luminance: 0.2126 R + 0.7152 G + 0.0722 B on linear light."
  @spec luminance(color()) :: float()
  def luminance(color) do
    {r, g, b} = clamp(color)
    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  @doc "WCAG 2.x contrast ratio, `(L_lighter + 0.05) / (L_darker + 0.05)`. Order-free."
  @spec contrast(color(), color()) :: float()
  def contrast(a, b) do
    la = luminance(a)
    lb = luminance(b)
    (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  end

  @doc """
  The WCAG contrast ratio of the PAINTED quantity: both endpoints are quantized to
  8-bit sRGB — `to_hex/1` then `hex/1` — before the ratio is computed, so the value
  is hex-to-hex. That is what a painted-pixel read measures: the compositor writes
  an 8-bit buffer before anything can sample it, so a figure `app.css` records from
  a screenshot cannot carry the float between steps.

  Reach for it when reproducing a figure `app.css` labels painted ("MEASURED ... in
  a browser", "painted pixels"), such as the candidate-rail anchors 6.87 / 1.99 /
  5.39 / 3.78. `contrast/2` keeps float-through semantics; the two agree exactly
  when both endpoints are already 8-bit sRGB.
  """
  @spec contrast_painted(color(), color()) :: float()
  def contrast_painted(a, b), do: contrast(hex(to_hex(a)), hex(to_hex(b)))

  @doc """
  The band of WCAG relative luminances a colour must sit in to clear `floor`:1
  against BOTH `ground_a` and `ground_b`.

  Each ground pins one edge of the band. The darker ground needs less absolute
  contrast to be cleared by a lighter colour, so it sets the low edge; the
  lighter ground sets the high edge the same way. Returns `{floor_l, ceiling_l}`
  — luminance low then high, never reordered and never clamped — so a caller
  can print both bounds in a failure message instead of losing them behind a
  single boolean:

      floor_l   = floor * (min(la, lb) + 0.05) - 0.05
      ceiling_l = (max(la, lb) + 0.05) / floor - 0.05

  A colour in the band exists iff `floor_l <= ceiling_l`. Substituting the two
  lines above and simplifying, that condition is exactly
  `(L_lighter + 0.05) / (L_darker + 0.05) >= floor * floor` — a colour clearing
  `floor`:1 against both grounds exists iff the two grounds' OWN contrast ratio
  is at least `floor` squared. Two grounds FAR APART leave MORE room, not less:
  the separation between the grounds is the budget the band is cut from. When
  the grounds themselves fail to clear `floor * floor`, no third colour can
  clear `floor` against both, and this function reports that by returning the
  tuple INVERTED (`floor_l > ceiling_l`) rather than a boolean — a bare `false`
  would say a colour does not exist without saying by how much, at the exact
  moment the two numbers are most worth printing.

  Pass the grounds as the artefact actually resolves them, never as a hex
  approximation typed in by eye: a surface declared with an alpha channel is a
  recipe, not a value, and `oklch(98% 0 0 / 0.96)` composited over `base_100`
  is not `#F9F9F9`.

  ## Examples

      iex> Platform.Design.WcagContrast.two_ground_window(3.0, Platform.Design.WcagContrast.hex("#FFFFFF"), Platform.Design.WcagContrast.hex("#000000"))
      {0.10000000000000002, 0.30000000000000004}

      iex> Platform.Design.WcagContrast.two_ground_window(3.0, Platform.Design.WcagContrast.hex("#FFFFFF"), Platform.Design.WcagContrast.hex("#767676"))
      {0.6434927327495805, 0.30000000000000004}
  """
  @spec two_ground_window(number(), color(), color()) :: {float(), float()}
  def two_ground_window(floor, ground_a, ground_b) do
    la = luminance(ground_a)
    lb = luminance(ground_b)

    {floor * (min(la, lb) + 0.05) - 0.05, (max(la, lb) + 0.05) / floor - 0.05}
  end

  @doc "Renders a colour as `#RRGGBB` for failure messages. Clamps and rounds."
  @spec to_hex(color()) :: binary()
  def to_hex(color) do
    {r, g, b} = clamp(color)

    [r, g, b]
    |> Enum.map(&(&1 |> from_linear() |> Kernel.*(255) |> round() |> Integer.to_string(16)))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join()
    |> then(&("#" <> String.upcase(&1)))
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp byte(pair), do: String.to_integer(pair, 16)

  defp to_linear(byte_value), do: to_linear_unit(byte_value / 255.0)

  defp to_linear_unit(c) when c <= 0.04045, do: c / 12.92
  defp to_linear_unit(c), do: :math.pow((c + 0.055) / 1.055, 2.4)

  defp from_linear(c) when c <= 0.0031308, do: c * 12.92
  defp from_linear(c), do: 1.055 * :math.pow(c, 1 / 2.4) - 0.055

  defp clamp({r, g, b}), do: {clamp1(r), clamp1(g), clamp1(b)}
  defp clamp1(v), do: v |> max(0.0) |> min(1.0)

  defp cbrt(v) when v < 0, do: -:math.pow(-v, 1 / 3)
  defp cbrt(v), do: :math.pow(v, 1 / 3)

  defp mul({{a, b, c}, {d, e, f}, {g, h, i}}, {x, y, z}) do
    {a * x + b * y + c * z, d * x + e * y + f * z, g * x + h * y + i * z}
  end

  defp to_float(text) do
    case Float.parse(text) do
      {value, ""} -> value
      _ -> raise ArgumentError, "not a number: #{inspect(text)}"
    end
  end
end

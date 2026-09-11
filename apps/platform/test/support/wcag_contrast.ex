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

  This module carries the float. That is not a taste call: it is the convention the
  figures already recorded in `app.css` were computed under, and the match is exact
  rather than close. The `.chip-soft` alpha-ceiling table reads

      neutral 4.87868930, success 3.23613436, warning 2.21457697, error 3.89478250

  and this module reproduces all four to the last digit from the `oklch()` text of the
  tone tokens. Quantizing the tint first gives 4.88756921 / 3.23171346 / 2.21779607 /
  3.90669772 — wrong in the third decimal, four times over. The chip fill table's
  light `primary` cell (1.0666) reproduces the same way and not the other.

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

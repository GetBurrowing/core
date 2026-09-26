defmodule Platform.Branding.Contrast do
  @moduledoc """
  Runtime colour arithmetic for admin-chosen in-app theme colours
  (task 01a0dbee-f598-7001-b450-7890103f44c4 stage 1).

  Two jobs, both over `#rrggbb` strings:

    * WCAG 2.x relative luminance and contrast ratio, so the server can refuse a
      palette whose text would be unreadable even if the admin UI is bypassed.
    * sRGB <-> OKLCH, so `Platform.Branding.Palette` can step a colour's
      lightness without moving its hue, and can tell when an action colour reads
      as one of the status hues.

  ## Why this is not `Platform.Design.WcagContrast`

  That module is test support (`test/support/wcag_contrast.ex`) and says so in
  its moduledoc: nothing in `lib/` may use it, because it is compiled only under
  `MIX_ENV=test`. It also parses the stylesheet's own colour syntax, which this
  module has no need for. Its figures are the reference this module is held to:
  `contrast_test.exs` asserts both agree on a fixed set of hexes, including the
  1.7875 / 4.7007 / 9.6304 figures `app.css` records.

  Convention is float-through, like the reference: an OKLCH value is converted
  to a hex (8-bit) at the boundary, and every ratio this module reports is
  hex-to-hex, which is what a browser paints.
  """

  @typedoc "Linear-light sRGB, 0..1 per channel."
  @type linear :: {float(), float(), float()}

  @typedoc "OKLCH: lightness 0..1, chroma >= 0, hue in degrees 0..360."
  @type oklch :: {float(), float(), float()}

  # Oklab <-> linear sRGB (Ottosson), the same constants CSS Color 4 carries.
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

  @doc """
  Normalises an admin-typed hex to lowercase `#rrggbb`.

  Accepts `#RGB`, `#RRGGBB`, with or without the `#`, surrounding whitespace
  ignored. Anything else is `:error`.

      iex> Platform.Branding.Contrast.normalize_hex("#ABC")
      {:ok, "#aabbcc"}

      iex> Platform.Branding.Contrast.normalize_hex("06D5ED")
      {:ok, "#06d5ed"}

      iex> Platform.Branding.Contrast.normalize_hex("#12345")
      :error
  """
  @spec normalize_hex(term()) :: {:ok, String.t()} | :error
  def normalize_hex(value) when is_binary(value) do
    digits = value |> String.trim() |> String.trim_leading("#")

    cond do
      Regex.match?(~r/^[0-9a-fA-F]{6}$/, digits) ->
        {:ok, "#" <> String.downcase(digits)}

      Regex.match?(~r/^[0-9a-fA-F]{3}$/, digits) ->
        <<r::binary-1, g::binary-1, b::binary-1>> = digits
        {:ok, "#" <> String.downcase(r <> r <> g <> g <> b <> b)}

      true ->
        :error
    end
  end

  def normalize_hex(_), do: :error

  @doc "Parses `#rrggbb` into linear-light sRGB."
  @spec to_linear(String.t()) :: linear()
  def to_linear("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
    {decode(byte(r)), decode(byte(g)), decode(byte(b))}
  end

  @doc "WCAG 2.x relative luminance of `#rrggbb`."
  @spec luminance(String.t()) :: float()
  def luminance(hex) do
    {r, g, b} = to_linear(hex)
    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  @doc "WCAG 2.x contrast ratio between two `#rrggbb` colours. Order-free."
  @spec ratio(String.t(), String.t()) :: float()
  def ratio(a, b) do
    la = luminance(a)
    lb = luminance(b)
    (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  end

  @doc "`#rrggbb` to OKLCH `{l, c, h}`. Hue is 0.0 for an achromatic colour."
  @spec to_oklch(String.t()) :: oklch()
  def to_oklch(hex) do
    {l_, m_, s_} = mul(@lin_to_lms, to_linear(hex))
    {l, a, b} = mul(@lms_to_lab, {cbrt(l_), cbrt(m_), cbrt(s_)})
    c = :math.sqrt(a * a + b * b)
    h = if c < 1.0e-6, do: 0.0, else: normalize_hue(:math.atan2(b, a) * 180.0 / :math.pi())
    {l, c, h}
  end

  @doc """
  OKLCH to `#rrggbb`. An out-of-gamut request keeps its lightness and hue and
  gives up chroma until it fits (binary search), which is how CSS Color 4
  recommends mapping rather than clipping each channel and shifting the hue.
  """
  @spec from_oklch(oklch()) :: String.t()
  def from_oklch({l, c, h}) do
    l = l |> max(0.0) |> min(1.0)
    c = max(c, 0.0)

    rgb =
      if in_gamut?(oklch_to_linear({l, c, h})) do
        oklch_to_linear({l, c, h})
      else
        oklch_to_linear({l, fit_chroma(l, h, 0.0, c, 24), h})
      end

    to_hex(rgb)
  end

  @doc "Smallest angle between two hues, in degrees (0..180)."
  @spec hue_distance(number(), number()) :: float()
  def hue_distance(a, b) do
    d = abs(normalize_hue(a * 1.0) - normalize_hue(b * 1.0))
    min(d, 360.0 - d)
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp fit_chroma(_l, _h, lo, _hi, 0), do: lo

  defp fit_chroma(l, h, lo, hi, n) do
    mid = (lo + hi) / 2

    if in_gamut?(oklch_to_linear({l, mid, h})),
      do: fit_chroma(l, h, mid, hi, n - 1),
      else: fit_chroma(l, h, lo, mid, n - 1)
  end

  defp in_gamut?({r, g, b}), do: Enum.all?([r, g, b], &(&1 >= -1.0e-7 and &1 <= 1.0 + 1.0e-7))

  defp oklch_to_linear({l, c, h}) do
    rad = h * :math.pi() / 180.0
    {l_, m_, s_} = mul(@lab_to_lms, {l, c * :math.cos(rad), c * :math.sin(rad)})
    mul(@lms_to_lin, {l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_})
  end

  defp to_hex({r, g, b}) do
    "#" <>
      Enum.map_join([r, g, b], fn v ->
        v
        |> max(0.0)
        |> min(1.0)
        |> encode()
        |> Kernel.*(255)
        |> round()
        |> Integer.to_string(16)
        |> String.pad_leading(2, "0")
        |> String.downcase()
      end)
  end

  defp normalize_hue(h) do
    r = :math.fmod(h, 360.0)
    if r < 0, do: r + 360.0, else: r
  end

  defp byte(pair), do: String.to_integer(pair, 16)

  defp decode(byte_value) do
    c = byte_value / 255.0
    if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
  end

  defp encode(c) when c <= 0.0031308, do: c * 12.92
  defp encode(c), do: 1.055 * :math.pow(c, 1 / 2.4) - 0.055

  defp cbrt(v) when v < 0, do: -:math.pow(-v, 1 / 3)
  defp cbrt(v), do: :math.pow(v, 1 / 3)

  defp mul({{a, b, c}, {d, e, f}, {g, h, i}}, {x, y, z}) do
    {a * x + b * y + c * z, d * x + e * y + f * z, g * x + h * y + i * z}
  end
end

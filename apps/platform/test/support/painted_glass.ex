defmodule Platform.Design.PaintedGlass do
  @moduledoc """
  The painted pixels of the mobile glass tab bar (task
  01a1557a-7a71-7000-8580-75565039bffe, Burrow redesign 4, stage 1).

  Test-support only, and a lookup, never a model. `PaintedComposite` knows
  ink at 55/57/60% over an OPAQUE ground; the glass bar is a different paint
  path (a translucent base-200 over whatever scrolls under it, then ink over
  that), so nothing here is derived from those formulas. Every value was read
  back from a screenshot:

    * `chrome151.csv`: Chrome 151 headless-shell on one box;
    * `chrome147.csv`: HeadlessChrome 147 on another.

  Each painted the COMPILED app.css's `.bottom-nav` over a full-width `#000`
  panel and a full-width `#fff` panel, in all ten variants, with
  `--glass-alpha` overridden from 0.50 to 1.00 in 0.01 steps. The layers are
  flat patches (`background: currentColor` under the tab classes), so no
  glyph rasterisation sits between the claim and the pixel. Each file's
  header names its build and the CSS declarations it was painted from
  (`paint_inputs/1`).

  `pixel/5` RAISES for any key the fixtures do not hold, an unswept alpha
  above all: the sweep is a measurement, and an alpha between two steps is an
  extrapolation.

  ## The under-glass table (task 01a15f2e stage 4)

  A second, separate table (`under_pixel/5`, `under_contrast/6`, ...) reads
  `underlay_chrome151.csv` / `underlay_chrome147.csv`: the bar, the phone
  composer pill and the glass typing band painted over flat underlays (#000,
  #fff, base-content, base-100, primary and the ten agent accents) at
  --glass-alpha 0.80..1.00. The functions above and their fixtures are
  unchanged.
  """

  alias Platform.Design.WcagContrast, as: W

  @dir Path.expand("fixtures/painted_glass", __DIR__)
  @builds %{chrome151: "chrome151.csv", chrome147: "chrome147.csv"}
  @layers ~w(glass inactive_icon inactive_label active_icon active_label dot subtle ctl_white ctl_black)a
  @backdrops [:black, :white]

  @type build :: :chrome151 | :chrome147
  @type backdrop :: :black | :white

  @doc "The builds painted."
  @spec builds() :: [build()]
  def builds, do: @builds |> Map.keys() |> Enum.sort()

  @doc "The two backdrops every variant was painted over."
  @spec backdrops() :: [backdrop()]
  def backdrops, do: @backdrops

  @doc "The layers each row holds."
  @spec layers() :: [atom()]
  def layers, do: @layers

  @doc "The fixture file for a build."
  @spec path(build()) :: Path.t()
  def path(build), do: Path.join(@dir, Map.fetch!(@builds, build))

  @doc """
  The painted pixel, as an `#rrggbb` string, for
  `{build, variant, backdrop, alpha, layer}`. `variant` is `"<preset> <mode>"`
  (`"burrow light"`, `"high-contrast dark"`). `alpha` is a number or a
  string; it must be one of the swept steps exactly, or this raises.
  """
  @spec pixel(build(), String.t(), backdrop(), number() | String.t(), atom()) :: String.t()
  def pixel(build, variant, backdrop, alpha, layer) do
    key = {variant, backdrop, alpha_key!(alpha)}

    row =
      Map.get(table(build), key) ||
        raise ArgumentError,
              "no painted glass row for #{inspect(build)} #{inspect(key)} in #{path(build)}. " <>
                "The sweep holds 0.50..1.00 in 0.01 steps for ten variants; a missing row " <>
                "is a deleted measurement or an unswept alpha, and neither is interpolated."

    Map.get(row, layer) ||
      raise ArgumentError, "no layer #{inspect(layer)}; layers are #{inspect(@layers)}"
  end

  @doc "WCAG contrast of `layer` against the glass, from the painted bytes."
  @spec contrast(build(), String.t(), backdrop(), number() | String.t(), atom()) :: float()
  def contrast(build, variant, backdrop, alpha, layer) do
    W.contrast(
      W.hex(pixel(build, variant, backdrop, alpha, layer)),
      W.hex(pixel(build, variant, backdrop, alpha, :glass))
    )
  end

  @doc "The swept alphas, as two-decimal strings."
  @spec alphas() :: [String.t()]
  def alphas, do: Enum.map(50..100, &format_alpha(&1 / 100))

  @doc "Every `{variant, backdrop, alpha}` key a build holds."
  @spec keys(build()) :: [{String.t(), backdrop(), String.t()}]
  def keys(build), do: build |> table() |> Map.keys()

  @doc "The build named on the file's `# build:` header line."
  @spec build_label(build()) :: String.t()
  def build_label(build) do
    build
    |> header()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^# build: (.+)$/, line) do
        [_, label] -> label
        nil -> nil
      end
    end) || raise ArgumentError, "#{path(build)} names no build"
  end

  @doc """
  The CSS declarations the sweep painted from, as `{selector, property, value}`,
  read from the `# paint-input:` header lines.
  """
  @spec paint_inputs(build()) :: [{String.t(), String.t(), String.t()}]
  def paint_inputs(build) do
    for line <- header(build),
        [_, sel, prop, value] <-
          [Regex.run(~r/^# paint-input: (.+?) \| (.+?) \| (.+)$/, line)] do
      {sel, prop, value}
    end
  end

  @doc """
  An alpha as the sweep keys it: a two-decimal string. Raises for anything
  that is not exactly a swept step (0.875, 0.4, 1.01, "abc").
  """
  @spec alpha_key!(number() | String.t()) :: String.t()
  def alpha_key!(alpha) when is_binary(alpha) do
    case Float.parse(String.trim(alpha)) do
      {f, ""} -> checked_key!(f, alpha)
      _ -> raise ArgumentError, "alpha #{inspect(alpha)} is not a number"
    end
  end

  def alpha_key!(alpha) when is_number(alpha), do: checked_key!(alpha / 1, alpha)

  defp checked_key!(f, original) do
    key = format_alpha(f)

    if abs(f - String.to_float(key)) < 1.0e-9 and key in alphas() do
      key
    else
      raise ArgumentError,
            "alpha #{inspect(original)} was not swept (0.50..1.00 in 0.01 steps); " <>
              "paint it before measuring it"
    end
  end

  @doc """
  The painted focus ring (stage 5): one map per row of `focus_ring.csv`,
  `%{build, variant, backdrop, alpha, glass, ring, ctl_white, ctl_black}`,
  painted at each variant's DECLARED alpha (no override).
  """
  @spec ring_rows() :: [map()]
  def ring_rows do
    for line <- ring_lines() do
      [build, v, bd, a, glass, ring, w, k] = String.split(line, ",")

      %{
        build: String.to_existing_atom(build),
        variant: v,
        backdrop: backdrop_atom!(bd),
        alpha: a,
        glass: glass,
        ring: ring,
        ctl_white: w,
        ctl_black: k
      }
    end
  end

  @doc "The CSS the ring sweep painted from, as `{selector, property, value}`."
  def ring_paint_inputs do
    for line <- ring_header(),
        [_, sel, prop, value] <-
          [Regex.run(~r/^# paint-input: (.+?) \| (.+?) \| (.+)$/, line)],
        do: {sel, prop, value}
  end

  @doc "WCAG contrast between two `#rrggbb` pixels."
  def ratio(a, b), do: W.contrast(W.hex(a), W.hex(b))

  defp ring_path, do: Path.join(@dir, "focus_ring.csv")

  defp ring_header,
    do:
      ring_path()
      |> File.read!()
      |> String.split("\n")
      |> Enum.take_while(&String.starts_with?(&1, "#"))

  defp ring_lines do
    [header | rows] =
      ring_path()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))

    header == "build,variant,backdrop,alpha,glass,ring,ctl_white,ctl_black" ||
      raise ArgumentError, "#{ring_path()} has unexpected columns: #{header}"

    rows
  end

  # ── The under-glass table (task 01a15f2e stage 4) ─────────────────────────
  #
  # A SECOND table, keyed {variant, underlay, alpha}, with its own layer list.
  # The bar sweep above (`pixel/5`, `contrast/5`, `keys/1`, ...) is untouched:
  # its callers read chrome151.csv / chrome147.csv exactly as before.
  #
  # underlay_chrome151.csv / underlay_chrome147.csv paint the COMPILED app.css's
  # `.bottom-nav`, the phone `.compose-pill-bar` and the glass typing band over
  # full-width FLAT underlay panels: #000, #fff, the variant's base-content,
  # base-100, primary and its ten agent accents (--ag-teal .. --ag-lime), at
  # --glass-alpha 0.80..1.00 in 0.01 steps. Every value is a painted byte; a
  # sub-100% ink over glass (--color-subtle) is read, never derived.

  @under_builds %{chrome151: "underlay_chrome151.csv", chrome147: "underlay_chrome147.csv"}
  @underlays ~w(black white base_content base_100 primary ag_teal ag_blue ag_purple ag_rose ag_amber ag_green ag_orange ag_indigo ag_brick ag_lime)
  @under_layers ~w(bar_glass inactive_icon inactive_label active_icon active_label dot pill_glass placeholder typed attach send band_glass typing ctl_white ctl_black)a

  @doc "The builds the under-glass sweep was painted on."
  @spec under_builds() :: [build()]
  def under_builds, do: @under_builds |> Map.keys() |> Enum.sort()

  @doc "Every underlay the under-glass sweep painted, by name."
  @spec underlays() :: [String.t()]
  def underlays, do: @underlays

  @doc "The layers each under-glass row holds."
  @spec under_layers() :: [atom()]
  def under_layers, do: @under_layers

  @doc "The under-glass sweep's alphas, as two-decimal strings (0.80..1.00)."
  @spec under_alphas() :: [String.t()]
  def under_alphas, do: Enum.map(80..100, &format_alpha(&1 / 100))

  @doc "The under-glass fixture file for a build."
  @spec under_path(build()) :: Path.t()
  def under_path(build), do: Path.join(@dir, Map.fetch!(@under_builds, build))

  @doc """
  The painted pixel, `#rrggbb`, for `{build, variant, underlay, alpha, layer}`
  in the under-glass sweep. Raises for an unswept alpha (anything but
  0.80..1.00 in 0.01 steps), an unknown underlay or an unknown layer.
  """
  @spec under_pixel(build(), String.t(), String.t(), number() | String.t(), atom()) :: String.t()
  def under_pixel(build, variant, underlay, alpha, layer) do
    a = alpha_key!(alpha)

    a in under_alphas() ||
      raise ArgumentError,
            "alpha #{a} was not swept under glass (0.80..1.00 in 0.01 steps); paint it first"

    underlay in @underlays ||
      raise ArgumentError, "unknown underlay #{inspect(underlay)}; #{inspect(@underlays)}"

    row =
      Map.get(under_table(build), {variant, underlay, a}) ||
        raise ArgumentError,
              "no under-glass row for #{inspect(build)} #{inspect({variant, underlay, a})} " <>
                "in #{under_path(build)}"

    Map.get(row, layer) ||
      raise ArgumentError, "no under-glass layer #{inspect(layer)}; #{inspect(@under_layers)}"
  end

  @doc "WCAG contrast of `ink` against `ground`, both painted under-glass layers."
  @spec under_contrast(build(), String.t(), String.t(), number() | String.t(), atom(), atom()) ::
          float()
  def under_contrast(build, variant, underlay, alpha, ink, ground) do
    W.contrast(
      W.hex(under_pixel(build, variant, underlay, alpha, ink)),
      W.hex(under_pixel(build, variant, underlay, alpha, ground))
    )
  end

  @doc "Every `{variant, underlay, alpha}` key an under-glass build holds."
  @spec under_keys(build()) :: [{String.t(), String.t(), String.t()}]
  def under_keys(build), do: build |> under_table() |> Map.keys()

  @doc "The under-glass file's `# build:` label."
  @spec under_build_label(build()) :: String.t()
  def under_build_label(build) do
    build
    |> under_path()
    |> header_of()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^# build: (.+)$/, line) do
        [_, label] -> label
        nil -> nil
      end
    end) || raise ArgumentError, "#{under_path(build)} names no build"
  end

  @doc "The CSS the under-glass sweep painted from, as `{selector, property, value}`."
  @spec under_paint_inputs(build()) :: [{String.t(), String.t(), String.t()}]
  def under_paint_inputs(build) do
    for line <- build |> under_path() |> header_of(),
        [_, sel, prop, value] <-
          [Regex.run(~r/^# paint-input: (.+?) \| (.+?) \| (.+)$/, line)] do
      {sel, prop, value}
    end
  end

  defp header_of(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.take_while(&String.starts_with?(&1, "#"))
  end

  defp under_table(build) do
    key = {__MODULE__, :under_table, build}

    case :persistent_term.get(key, nil) do
      nil ->
        t = load_under!(build)
        :persistent_term.put(key, t)
        t

      t ->
        t
    end
  end

  defp load_under!(build) do
    [columns | rows] =
      build
      |> under_path()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))

    expected = ["variant", "underlay", "alpha" | Enum.map(@under_layers, &Atom.to_string/1)]
    names = String.split(columns, ",")

    names == expected ||
      raise ArgumentError,
            "#{under_path(build)} columns #{inspect(names)}, expected #{inspect(expected)}"

    Map.new(rows, fn line ->
      [variant, underlay, alpha | values] = String.split(line, ",")
      {{variant, underlay, alpha}, Map.new(Enum.zip(@under_layers, values))}
    end)
  end

  defp format_alpha(f), do: :erlang.float_to_binary(f / 1, decimals: 2)

  defp header(build) do
    build
    |> path()
    |> File.read!()
    |> String.split("\n")
    |> Enum.take_while(&String.starts_with?(&1, "#"))
  end

  defp table(build) do
    key = {__MODULE__, :table, build}

    case :persistent_term.get(key, nil) do
      nil ->
        t = load!(build)
        :persistent_term.put(key, t)
        t

      t ->
        t
    end
  end

  defp load!(build) do
    [columns | rows] =
      build
      |> path()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))

    expected = ["variant", "backdrop", "alpha" | Enum.map(@layers, &Atom.to_string/1)]
    names = String.split(columns, ",")

    names == expected ||
      raise ArgumentError,
            "#{path(build)} columns #{inspect(names)}, expected #{inspect(expected)}"

    Map.new(rows, fn line ->
      [variant, backdrop, alpha | values] = String.split(line, ",")
      backdrop = backdrop_atom!(backdrop)
      {{variant, backdrop, alpha}, Map.new(Enum.zip(@layers, values))}
    end)
  end

  defp backdrop_atom!("black"), do: :black
  defp backdrop_atom!("white"), do: :white
  defp backdrop_atom!(other), do: raise(ArgumentError, "unknown backdrop #{inspect(other)}")
end

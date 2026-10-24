defmodule Platform.Design.PaintedMix do
  @moduledoc """
  The painted pixel of an OPAQUE `color-mix(in srgb, ink p%, ground)`, the
  agent slot tint (task 01a1557a rung 3 stage 1).

  Test-support only, and deliberately separate from
  `Platform.Design.PaintedComposite`. That module models ink at reduced
  ALPHA composited over a ground (55/57/60%); an opaque srgb mix is resolved
  as a colour before anything is painted, a different browser path, at
  strengths no one had painted. Neither model is reused for the other.

  MEASURED (36,000 channels: Chrome 151.0.7922.109 headless-shell and
  HeadlessChrome 147.0.7727.15; every slot of every theme block, at every
  strength 0..14%, through the served app.css's own tokens, on 8x8 and 10x20
  boxes, with the theme on the page root and on a nested element): every
  painted channel is the exact mix `(ink*p + ground*(100-p)) / 100` rounded to
  nearest, with a .5 tie broken EITHER way. Half-up alone misses 24 channels
  per build, half-down alone 276; both builds paint identical bytes.
  `candidates/3` is that union, so it is a set of pixels, not one.

  `candidates/3` raises for a strength no browser was painted at.
  `painted!/3` raises unless the fixtures hold a row for exactly that ink,
  ground and strength under every recorded build: the guard measures only
  combinations that were painted, never an extrapolation.

  Fixtures: `test/support/fixtures/painted_mix/chrome<build>_mix.csv` (every
  ink x ground x strength) and `chrome<build>_tokens.csv` (the shipped
  `--ag-<id>-tint` tokens at each block's declared strength). The 1..14%
  rows stay as measurements; the shipped tint is 8% (0% in high contrast).
  Painted by `/home/dev/sources/tmp/01a1557a-760e-1372732/paint_mix_01a1557a.mjs`.
  """

  alias Platform.Design.WcagContrast, as: W

  @type rgb8 :: {0..255, 0..255, 0..255}

  @fixture_dir Path.expand("fixtures/painted_mix", __DIR__)
  @builds ["chrome147", "chrome151"]
  @strengths Enum.to_list(0..14)

  @doc "The browser builds with recorded fixtures."
  def builds, do: @builds

  @doc "The strengths (integer percent) painted under every build."
  def strengths, do: @strengths

  @doc """
  Every 8-bit pixel a measured build paints for `ink` mixed at `p`% into
  `ground`. Raises for an unpainted strength.
  """
  @spec candidates(rgb8(), rgb8(), integer()) :: [rgb8()]
  def candidates({ir, ig, ib}, {gr, gg, gb}, p) do
    unless p in @strengths do
      raise ArgumentError,
            "no browser has been painted mixing a slot at #{inspect(p)}% " <>
              "(painted: #{inspect(@strengths)}); paint the fixtures first"
    end

    for r <- channel(ir, gr, p), g <- channel(ig, gg, p), b <- channel(ib, gb, p), do: {r, g, b}
  end

  @doc """
  The candidate pixels for a combination the fixtures actually hold under
  every build. Raises for a strength, ink or ground that was not painted.
  """
  @spec painted!(rgb8(), rgb8(), integer()) :: [rgb8()]
  def painted!(ink, ground, p) do
    # The strength check first, so an unpainted strength names itself.
    candidates = candidates(ink, ground, p)
    rows = index()

    for build <- @builds, not Map.has_key?(rows, {build, ink, ground, p}) do
      raise ArgumentError,
            "#{build} has no painted row for #{hex(ink)} at #{inspect(p)}% into #{hex(ground)}; " <>
              "paint it before measuring it"
    end

    candidates
  end

  @doc "The worst contrast of `text` against any candidate pixel of the painted mix."
  @spec text_min(W.color(), W.color(), W.color(), integer()) :: float()
  def text_min(text, ink, ground, p) do
    t = from_bytes(bytes(text))

    painted!(bytes(ink), bytes(ground), p)
    |> Enum.map(&W.contrast(t, from_bytes(&1)))
    |> Enum.min()
  end

  @doc "Every recorded fixture row: `%{build, file, ink, ground, strength, pixels}`."
  def fixture_rows do
    for build <- @builds, kind <- ["mix", "tokens"], row <- read(build, kind), do: row
  end

  # Read once per VM; the fixtures are static files.
  defp index do
    case :persistent_term.get({__MODULE__, :index}, nil) do
      nil ->
        index =
          for row <- fixture_rows(),
              into: %{},
              do: {{row.build, row.ink, row.ground, row.strength}, true}

        :persistent_term.put({__MODULE__, :index}, index)
        index

      index ->
        index
    end
  end

  defp read(build, kind) do
    path = Path.join(@fixture_dir, "#{build}_#{kind}.csv")

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      case {kind, String.split(line, ",")} do
        {"mix", [ink, ground, p | pixels]} ->
          row(build, path, ink, ground, p, pixels)

        {"tokens", [_preset, _mode, _slot, _token, ink, ground, p, _path, pixel]} ->
          row(build, path, ink, ground, p, [pixel])
      end
    end)
  end

  defp row(build, path, ink, ground, p, pixels) do
    %{
      build: build,
      file: Path.basename(path),
      ink: rgb(ink),
      ground: rgb(ground),
      strength: String.to_integer(p),
      pixels: Enum.map(pixels, &rgb/1)
    }
  end

  @doc "A `WcagContrast` colour as 8-bit bytes."
  def bytes(color) do
    "#" <> hex = W.to_hex(color)
    rgb(hex)
  end

  @doc "8-bit bytes as a `WcagContrast` colour."
  def from_bytes(rgb), do: W.hex(hex(rgb))

  @doc "6-hex-digit string of 8-bit bytes."
  def hex({r, g, b}),
    do: Enum.map_join([r, g, b], &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))

  defp rgb(<<r::binary-2, g::binary-2, b::binary-2>>),
    do: {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}

  # Exact mix, rounded to nearest; a .5 tie lands on either side.
  defp channel(i, g, p) do
    n = i * p + g * (100 - p)
    Enum.uniq([div(2 * n + 100, 200), div(2 * n + 99, 200)])
  end
end

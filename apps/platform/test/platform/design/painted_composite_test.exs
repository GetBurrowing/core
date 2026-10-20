defmodule Platform.Design.PaintedCompositeTest do
  @moduledoc """
  Pins each formula in `Platform.Design.PaintedComposite` to pixels a browser
  actually painted (task 01a1557a stage 5, re-measured at 55%, 57% and 60% in
  round 2). The corpora are `test/support/fixtures/painted_composite/*.csv`:
  per build and strength, 326 ink/ground pairs (every theme pair, a grey sweep
  under black, near-black and white ink, and 100 random pairs), each painted
  through five box paths and one text path. The fit counts are asserted, not
  hidden, so a formula that drifts from its evidence turns this file red.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedComposite, as: P
  alias Platform.Design.WcagContrast, as: W

  @dir Path.expand("../../support/fixtures/painted_composite", __DIR__)
  @box_paths [:small_mix, :small_opacity, :block_mix, :block_opacity, :block_mix_var]
  @columns @box_paths ++ [:block_text_var]

  defp rgb(hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = String.trim_leading(hex, "#")
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  # [%{ink, ground, small_mix: rgb, ...}] for one build at one strength.
  defp corpus(build, p) do
    Path.join(@dir, "chrome#{build}_p#{p}.csv")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      [ink, ground | pixels] = String.split(line, ",")

      Map.merge(
        %{ink: rgb(ink), ground: rgb(ground)},
        Map.new(Enum.zip(@columns, Enum.map(pixels, &rgb/1)))
      )
    end)
  end

  defp channels(rows, path, p) do
    for r <- rows,
        {f, b, x} <-
          Enum.zip([
            Tuple.to_list(r.ink),
            Tuple.to_list(r.ground),
            Tuple.to_list(Map.fetch!(r, path))
          ]),
        do: {f, b, p, x}
  end

  defp explained?(formulas, {f, b, p, x}),
    do: Enum.any?(formulas, &(P.paint(&1, {f, f, f}, {b, b, b}, p) == {x, x, x}))

  defp unexplained(formulas, channels), do: Enum.reject(channels, &explained?(formulas, &1))

  test "the formulas and strengths are exactly these" do
    assert P.formulas() == [
             :chrome_147_opacity,
             :chrome_151_half_up,
             :chrome_151_half_down,
             :chrome_151_premultiplied
           ]

    assert P.measured_strengths() == [55, 57, 60]
    assert Enum.map([55, 57, 60], &P.alpha_byte/1) == [140, 145, 153]
  end

  test "every corpus has 326 pairs and its theme rows are where the guards expect them" do
    for build <- [147, 151], p <- P.measured_strengths() do
      rows = corpus(build, p)
      assert length(rows) == 326
      # Sand light raised, at row 18 of every corpus.
      assert Enum.at(rows, 18) |> Map.take([:ink, :ground]) == %{
               ink: {0, 0, 0},
               ground: rgb("e5d9c6")
             }
    end
  end

  for p <- [55, 57, 60] do
    @p p

    test "Chrome 147's opacity path is exactly :chrome_147_opacity at #{p}%" do
      rows = corpus(147, @p)

      exact =
        Enum.count(
          rows,
          &(P.paint(:chrome_147_opacity, &1.ink, &1.ground, @p) == &1.small_opacity)
        )

      assert exact == 326

      exact =
        Enum.count(
          rows,
          &(P.paint(:chrome_147_opacity, &1.ink, &1.ground, @p) == &1.block_opacity)
        )

      assert exact == 326
    end

    test "every box-path channel at #{p}%, both builds, is one of the four formulas" do
      all =
        for build <- [147, 151], path <- @box_paths, do: channels(corpus(build, @p), path, @p)

      all = List.flatten(all)
      assert length(all) == 2 * 5 * 326 * 3
      assert unexplained(P.formulas(), all) == []
    end

    test "Chrome 151's text path at #{p}% is also one of the four formulas" do
      assert unexplained(P.formulas(), channels(corpus(151, @p), :block_text_var, @p)) == []
    end

    test "the envelope is never lighter-contrast than any pixel painted at #{p}%" do
      offenders =
        for build <- [147, 151],
            r <- corpus(build, @p),
            path <- @box_paths ++ if(build == 151, do: [:block_text_var], else: []),
            {floor, _} = P.contrast_min(P.from_bytes(r.ink), P.from_bytes(r.ground), @p),
            painted = W.contrast(P.from_bytes(Map.fetch!(r, path)), P.from_bytes(r.ground)),
            painted < floor - 1.0e-9,
            do: {build, path, r.ink, r.ground, painted, floor}

      assert offenders == []
    end
  end

  test "no three of the four formulas explain the corpus: each one is needed" do
    all =
      for build <- [147, 151], p <- P.measured_strengths(), path <- @box_paths do
        channels(corpus(build, p), path, p)
      end
      |> List.flatten()

    for dropped <- P.formulas() do
      refute unexplained(P.formulas() -- [dropped], all) == [],
             "#{dropped} explains nothing the other three do not; drop it"
    end
  end

  # Recorded, not modelled: Chrome 147 paints pure-black TEXT at 55% lighter
  # than any box path, while #000006 text paints like a box.
  test "Chrome 147's text path paints #000000 lighter than its box path" do
    rows = corpus(147, 55)
    burrow_light = Enum.find(rows, &(&1.ink == {0, 0, 0} and &1.ground == rgb("fbfaf9")))
    assert burrow_light.block_opacity == {113, 113, 112}
    assert burrow_light.block_text_var == {117, 117, 116}

    midnight_light = Enum.find(rows, &(&1.ink == {0, 0, 6} and &1.ground == rgb("f8fafd")))
    assert midnight_light.block_text_var == midnight_light.block_opacity
  end

  test "sand light raised #e5d9c6 under black: 55% fails, 57% and 60% clear 4.5:1" do
    ink = W.hex("#000000")
    ground = W.hex("#e5d9c6")
    fixed = &:erlang.float_to_binary(&1, decimals: 4)

    {r55, _} = P.contrast_min(ink, ground, 55)
    {r57, _} = P.contrast_min(ink, ground, 57)
    {r60, _} = P.contrast_min(ink, ground, 60)

    assert {fixed.(r55), fixed.(r57), fixed.(r60)} == {"4.3460", "4.6194", "5.1419"}

    # The envelope's 57% pixel is the lightest either build paints: Chrome 147
    # (both box sizes) and Chrome 151 (10x20 boxes) paint exactly it.
    assert P.envelope({0, 0, 0}, rgb("e5d9c6"), 57) == rgb("635e55")
    assert Enum.at(corpus(147, 57), 18).small_opacity == rgb("635e55")
    assert Enum.at(corpus(151, 57), 18).block_mix == rgb("635e55")
  end

  test "midnight light's old raised #e2e8f2 still reads 4.4661:1 at 55%, as stage 5 measured" do
    {r, by} = P.contrast_min(W.hex("#000006"), W.hex("#e2e8f2"), 55)
    assert :erlang.float_to_binary(r, decimals: 4) == "4.4661"
    assert :chrome_147_opacity in by
  end

  test "an unmeasured strength is refused, not extrapolated" do
    assert_raise ArgumentError, ~r/no browser has been measured painting ink at 58%/, fn ->
      P.contrast_min(W.hex("#000000"), W.hex("#ffffff"), 58)
    end
  end
end

defmodule Platform.Design.PaintedMixTest do
  @moduledoc """
  Pins `Platform.Design.PaintedMix` to the pixels two Chrome builds painted
  for the agent slot tints (task 01a1557a rung 3 stage 1):
  `test/support/fixtures/painted_mix/*.csv`. A model that misses a fixture
  pixel is wrong, and a candidate no fixture forces is a guess, so both
  directions are asserted.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.PaintedMix, as: M

  setup_all do
    {:ok, rows: M.fixture_rows()}
  end

  test "both builds' fixtures are present and record the same combinations", %{rows: rows} do
    assert M.builds() == ["chrome147", "chrome151"]

    by_build =
      rows
      |> Enum.group_by(
        & &1.build,
        &{String.replace(&1.file, &1.build, ""), &1.ink, &1.ground, &1.strength}
      )
      |> Map.new(fn {b, keys} -> {b, Enum.sort(keys)} end)

    assert map_size(by_build) == 2
    assert by_build["chrome147"] == by_build["chrome151"]
    # 10 variants x 10 slots x 15 strengths, 4 paths each.
    assert Enum.count(rows, &(&1.build == "chrome151" and &1.file =~ "_mix")) == 1500
  end

  test "every fixture pixel is a candidate of its own ink, ground and strength", %{rows: rows} do
    missed =
      for row <- rows,
          px <- row.pixels,
          px not in M.candidates(row.ink, row.ground, row.strength),
          do: {row.file, M.hex(row.ink), M.hex(row.ground), row.strength, M.hex(px)}

    assert missed == [], "pixels the model does not produce:\n" <> inspect(missed, limit: 20)
  end

  test "each rounding of a tie is forced by some fixture pixel", %{rows: rows} do
    # Under the half-up reading alone and the half-down reading alone, some
    # painted pixel is unexplained: the union is the smallest model that fits.
    up = fn {i, g, p} -> div(2 * (i * p + g * (100 - p)) + 100, 200) end
    down = fn {i, g, p} -> div(2 * (i * p + g * (100 - p)) + 99, 200) end

    channels =
      for row <- rows,
          px <- row.pixels,
          {i, g, x} <-
            Enum.zip([
              Tuple.to_list(row.ink),
              Tuple.to_list(row.ground),
              Tuple.to_list(px)
            ]),
          do: {{i, g, row.strength}, x}

    assert Enum.count(channels, fn {k, x} -> up.(k) != x end) > 0
    assert Enum.count(channels, fn {k, x} -> down.(k) != x end) > 0
  end

  test "an unpainted strength raises in candidates/3 and painted!/3" do
    for p <- [15, 20, 55, -1] do
      assert_raise ArgumentError, ~r/no browser has been painted/, fn ->
        M.candidates({0, 0, 0}, {255, 255, 255}, p)
      end
    end

    # Burrow light's purple rail on base-100 at a strength that was never painted.
    assert_raise ArgumentError, fn -> M.painted!({128, 94, 182}, {251, 250, 249}, 20) end
  end

  test "an unpainted slot value or ground raises in painted!/3, never extrapolates" do
    # Painted: Burrow light purple #805eb6 on #fbfaf9 at 8%.
    assert M.painted!({128, 94, 182}, {251, 250, 249}, 8) != []

    # One byte off the painted ink, and one byte off the painted ground.
    assert_raise ArgumentError, ~r/no painted row/, fn ->
      M.painted!({128, 94, 183}, {251, 250, 249}, 8)
    end

    assert_raise ArgumentError, ~r/no painted row/, fn ->
      M.painted!({128, 94, 182}, {251, 250, 248}, 8)
    end
  end

  test "a 0% mix is the ground exactly" do
    for row <- M.fixture_rows(), row.strength == 0, px <- row.pixels, do: assert(px == row.ground)
  end
end

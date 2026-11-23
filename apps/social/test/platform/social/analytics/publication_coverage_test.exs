defmodule Platform.Social.Analytics.PublicationCoverageTest do
  use ExUnit.Case, async: true
  alias Platform.Social.Analytics.PublicationCoverage, as: Coverage

  defp interval(from, to), do: %{"from" => from, "to" => to}

  test "adding adjacent and overlapping intervals produces one ordered union" do
    ranges = [interval("2026-11-10", "2026-11-12"), interval("2026-11-01", "2026-11-03")]

    assert Coverage.add(ranges, ~D[2026-11-04], ~D[2026-11-10]) ==
             [interval("2026-11-01", "2026-11-12")]

    assert Coverage.normalize([
             interval("2026-11-02", "2026-11-02"),
             interval("2026-11-01", "2026-11-01")
           ]) ==
             [interval("2026-11-01", "2026-11-02")]
  end

  test "disjoint actual dates preserve gaps instead of enclosing them" do
    ranges = [interval("2026-11-01", "2026-11-03")]

    assert Coverage.add(ranges, ~D[2026-11-10], ~D[2026-11-12]) ==
             [interval("2026-11-01", "2026-11-03"), interval("2026-11-10", "2026-11-12")]

    refute Coverage.covers?(ranges, ~D[2026-11-01], ~D[2026-11-12])
  end

  test "subtracting the middle splits an interval with inclusive boundary dates" do
    assert Coverage.subtract(
             [interval("2026-11-01", "2026-11-10")],
             ~D[2026-11-04],
             ~D[2026-11-06]
           ) ==
             [interval("2026-11-01", "2026-11-03"), interval("2026-11-07", "2026-11-10")]
  end

  test "a covering subtraction clears and disjoint subtraction leaves coverage" do
    ranges = [interval("2026-11-03", "2026-11-10")]
    assert Coverage.subtract(ranges, ~D[2026-11-01], ~D[2026-11-12]) == []
    assert Coverage.subtract(ranges, ~D[2026-11-11], ~D[2026-11-12]) == ranges
  end

  test "partial overlaps trim either side without erasing untouched intervals" do
    ranges = [interval("2026-11-03", "2026-11-10"), interval("2026-11-20", "2026-11-22")]

    assert Coverage.subtract(ranges, ~D[2026-11-01], ~D[2026-11-05]) ==
             [interval("2026-11-06", "2026-11-10"), interval("2026-11-20", "2026-11-22")]

    assert Coverage.subtract(ranges, ~D[2026-11-08], ~D[2026-11-21]) ==
             [interval("2026-11-03", "2026-11-07"), interval("2026-11-22", "2026-11-22")]
  end

  test "missing computes only the complement inside the requested date interval" do
    ranges = [
      interval("2026-10-20", "2026-11-03"),
      interval("2026-11-07", "2026-11-08"),
      interval("2026-11-10", "2026-12-01")
    ]

    assert Coverage.missing(ranges, ~D[2026-11-01], ~D[2026-11-12]) ==
             [interval("2026-11-04", "2026-11-06"), interval("2026-11-09", "2026-11-09")]

    assert Coverage.missing([], ~D[2026-11-01], ~D[2026-11-01]) == [
             interval("2026-11-01", "2026-11-01")
           ]

    assert Coverage.covers?(ranges, ~D[2026-11-10], ~D[2026-11-12])
    refute Coverage.covers?(ranges, ~D[2026-11-03], ~D[2026-11-07])
  end

  test "large historical intervals stay normalized without enumerating every day" do
    ranges = [interval("0001-01-01", "4000-12-31"), interval("4001-01-01", "8000-12-31")]

    assert Coverage.add(ranges, ~D[8001-01-01], ~D[9999-12-31]) == [
             interval("0001-01-01", "9999-12-31")
           ]

    assert Coverage.missing(ranges, ~D[0001-01-01], ~D[9999-12-31]) == [
             interval("8001-01-01", "9999-12-31")
           ]
  end

  test "malformed persisted coverage is an error and cannot establish completeness" do
    for ranges <- [
          nil,
          %{},
          [nil],
          [interval("bad", "2026-11-01")],
          [interval("2026-11-02", "2026-11-01")],
          [interval("2026-11-01", "2026-11-01"), %{"from" => "2026-11-02"}]
        ] do
      assert Coverage.normalize(ranges) == {:error, :invalid_ranges}
      assert Coverage.add(ranges, ~D[2026-11-01], ~D[2026-11-02]) == {:error, :invalid_ranges}

      assert Coverage.subtract(ranges, ~D[2026-11-01], ~D[2026-11-02]) ==
               {:error, :invalid_ranges}

      assert Coverage.missing(ranges, ~D[2026-11-01], ~D[2026-11-02]) == {:error, :invalid_ranges}
      refute Coverage.covers?(ranges, ~D[2026-11-01], ~D[2026-11-02])
    end
  end

  test "invalid requested intervals never yield an empty successful complement" do
    for {from, to} <- [
          {~D[2026-11-02], ~D[2026-11-01]},
          {nil, ~D[2026-11-01]},
          {"2026-11-01", ~D[2026-11-01]}
        ] do
      assert Coverage.add([], from, to) == {:error, :invalid_interval}
      assert Coverage.subtract([], from, to) == {:error, :invalid_interval}
      assert Coverage.missing([], from, to) == {:error, :invalid_interval}
      refute Coverage.covers?([], from, to)
    end
  end
end

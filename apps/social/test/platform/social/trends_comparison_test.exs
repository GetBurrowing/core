defmodule Platform.Social.TrendsComparisonTest do
  use ExUnit.Case, async: true

  alias Platform.Social.Trends.Comparison

  test "ranks move only when the same story exists in comparable observations" do
    previous = %{source: "hn_top", limit: 3, items: [%{id: 1, rank: 1}, %{id: 2, rank: 2}]}
    current = %{source: "hn_top", limit: 3, items: [%{id: 2, rank: 1}, %{id: 3, rank: 2}]}

    assert Comparison.movement(previous, current) == %{
             1 => :absent_from_sample,
             2 => {:up, 1},
             3 => :new_in_sample
           }
  end

  test "a first or incompatible observation has no invented movements" do
    current = %{source: "hn_top", limit: 2, items: [%{id: 1, rank: 1}]}
    other = %{source: "hn_best", limit: 2, items: [%{id: 1, rank: 2}]}
    other_limit = %{other | source: "hn_top", limit: 5}

    assert Comparison.movement(nil, current) == %{1 => :unavailable}
    assert Comparison.movement(other, current) == %{1 => :unavailable}
    assert Comparison.movement(other_limit, current) == %{1 => :unavailable}
  end

  test "equal ranks and downward movement are distinguished" do
    previous = %{source: "hn_top", limit: 3, items: [%{id: 1, rank: 1}, %{id: 2, rank: 2}]}
    current = %{source: "hn_top", limit: 3, items: [%{id: 1, rank: 3}, %{id: 2, rank: 2}]}

    assert Comparison.movement(previous, current) == %{1 => {:down, 2}, 2 => :unchanged}
  end

  test "daily datasets separated by a missing day are not treated as consecutive" do
    previous = %{
      source: "wikimedia_pageviews",
      limit: 2,
      reporting_date: ~D[2026-11-11],
      items: [%{id: "x", rank: 5}]
    }

    current = %{
      source: "wikimedia_pageviews",
      limit: 2,
      reporting_date: ~D[2026-11-13],
      items: [%{id: "x", rank: 3}]
    }

    assert Comparison.movement(previous, current) == %{"x" => :unavailable}

    assert Comparison.movement(%{previous | reporting_date: ~D[2026-11-12]}, current) == %{
             "x" => {:up, 2}
           }

    assert Comparison.movement(%{previous | reporting_date: nil}, current) == %{
             "x" => :unavailable
           }
  end
end

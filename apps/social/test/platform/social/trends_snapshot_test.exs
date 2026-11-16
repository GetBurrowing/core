defmodule Platform.Social.TrendsSnapshotTest do
  use Platform.DataCase, async: false

  alias Platform.Social.Trends

  defp batch(rank, observed_at) do
    %{
      source: "hn_top",
      limit: 20,
      complete: true,
      observed_at: observed_at,
      items: [
        %{
          id: "7",
          rank: rank,
          title: "Example",
          url: "https://example.com",
          points: 12,
          comments: 3
        }
      ]
    }
  end

  test "rejects incomplete, malformed, or duplicate item batches without replacing data" do
    valid = batch(1, ~U[2026-11-15 12:00:00Z])
    assert {:ok, _} = Trends.record_snapshot(valid)
    assert {:error, :invalid_snapshot} = Trends.record_snapshot(%{valid | complete: false})
    assert {:error, :invalid_snapshot} = Trends.record_snapshot(%{valid | items: [nil]})

    unsafe = Map.put(hd(valid.items), :url, "javascript:alert(1)")
    assert {:error, :invalid_snapshot} = Trends.record_snapshot(%{valid | items: [unsafe]})

    invalid_title = Map.put(hd(valid.items), :title, <<255>>)
    assert {:error, :invalid_snapshot} = Trends.record_snapshot(%{valid | items: [invalid_title]})

    nul_title = Map.put(hd(valid.items), :title, "bad\0title")
    assert {:error, :invalid_snapshot} = Trends.record_snapshot(%{valid | items: [nul_title]})

    nul_key = Map.put(hd(valid.items), :id, "bad\0key")
    assert {:error, :invalid_snapshot} = Trends.record_snapshot(%{valid | items: [nul_key]})

    assert {:error, :invalid_snapshot} =
             Trends.record_snapshot(%{valid | items: valid.items ++ valid.items})

    assert %{current: %{items: [%{id: "7"}]}, previous: nil} = Trends.latest("hn_top")
  end

  test "does not replace the current observation with an older or duplicate timestamp" do
    newest = batch(1, ~U[2026-11-15 12:00:00Z])
    assert {:ok, _} = Trends.record_snapshot(newest)
    assert {:error, :out_of_order} = Trends.record_snapshot(newest)
    assert {:error, :out_of_order} = Trends.record_snapshot(batch(2, ~U[2026-11-15 11:00:00Z]))
    assert %{current: %{items: [%{rank: 1}]}, previous: nil} = Trends.latest("hn_top")
  end

  test "retains only two batches and stores only declared observation fields" do
    first = batch(3, ~U[2026-11-15 10:00:00Z])
    second = batch(2, ~U[2026-11-15 11:00:00Z])
    third = batch(1, ~U[2026-11-15 12:00:00Z])
    third = %{third | items: [Map.put(hd(third.items), :untrusted_extra, "discard me")]}

    assert {:ok, _} = Trends.record_snapshot(first)
    assert {:ok, _} = Trends.record_snapshot(second)
    assert {:ok, _} = Trends.record_snapshot(third)
    assert Repo.aggregate(Platform.Social.Trends.Snapshot, :count) == 2

    assert %{payload: %{"items" => [item]}} =
             Repo.get_by!(Platform.Social.Trends.Snapshot,
               observed_at: ~U[2026-11-15 12:00:00.000000Z]
             )

    refute Map.has_key?(item, "untrusted_extra")
  end

  test "keeps observations for distinct sources and opaque item keys separate" do
    one = %{
      batch(1, ~U[2026-11-15 10:00:00Z])
      | source: "other_feed",
        items: [
          %{
            id: "item/7",
            rank: 1,
            title: "Other source",
            url: "https://example.com",
            points: 2,
            comments: 1
          }
        ]
    }

    assert {:ok, _} = Trends.record_snapshot(one)
    assert {:ok, _} = Trends.record_snapshot(batch(1, ~U[2026-11-15 11:00:00Z]))
    assert %{current: %{items: [%{id: "item/7"}]}} = Trends.latest("other_feed")
    assert %{current: %{items: [%{id: "7"}]}} = Trends.latest("hn_top")
  end

  test "a daily source stores pageviews, accepts tied ranks, and ignores a repeated reporting date" do
    observed = ~U[2026-11-15 12:00:00Z]

    snapshot = %{
      source: "wikimedia_pageviews",
      limit: 2,
      complete: true,
      reporting_date: ~D[2026-11-13],
      observed_at: observed,
      items: [
        %{id: "A", rank: 3, title: "A", url: "https://example.com/a", pageviews: 100},
        %{id: "B", rank: 3, title: "B", url: "https://example.com/b", pageviews: 100}
      ]
    }

    assert {:ok, _} = Trends.record_snapshot(snapshot)

    assert {:ok, :unchanged} =
             Trends.record_snapshot(%{
               snapshot
               | observed_at: DateTime.add(observed, 60, :second)
             })

    assert {:error, :out_of_order} =
             Trends.record_snapshot(%{
               snapshot
               | reporting_date: ~D[2026-11-12],
                 observed_at: DateTime.add(observed, 120, :second)
             })

    assert %{
             current: %{reporting_date: ~D[2026-11-13], items: [%{pageviews: 100}, %{rank: 3}]},
             previous: nil
           } = Trends.latest("wikimedia_pageviews")
  end

  test "allows a valid Wikipedia item key longer than 200 bytes" do
    key = String.duplicate("a", 240)

    assert {:ok, _} =
             Trends.record_snapshot(%{
               source: "wikimedia_pageviews",
               limit: 1,
               complete: true,
               reporting_date: ~D[2026-11-13],
               observed_at: ~U[2026-11-15 12:00:00Z],
               items: [%{id: key, rank: 1, title: key, url: "https://example.com", pageviews: 1}]
             })
  end

  test "the Wikipedia source refuses missing dates or fabricated non-pageview metrics" do
    legacy = %{batch(1, ~U[2026-11-15 12:00:00Z]) | source: "wikimedia_pageviews"}
    assert {:error, :invalid_snapshot} = Trends.record_snapshot(legacy)

    assert {:error, :invalid_snapshot} =
             Trends.record_snapshot(Map.put(legacy, :reporting_date, ~D[2026-11-13]))
  end

  test "retains comparable observations and rejects an incomplete update" do
    first = batch(2, ~U[2026-11-15 10:00:00Z])
    second = batch(1, ~U[2026-11-15 11:00:00Z])

    assert {:ok, _} = Trends.record_snapshot(first)
    assert {:ok, _} = Trends.record_snapshot(second)
    assert {:error, :invalid_snapshot} = Trends.record_snapshot(%{second | items: []})
    assert %{current: current, previous: previous} = Trends.latest("hn_top")
    assert DateTime.compare(current.observed_at, second.observed_at) == :eq
    assert DateTime.compare(previous.observed_at, first.observed_at) == :eq
    assert Trends.Comparison.movement(previous, current) == %{"7" => {:up, 1}}
  end
end

defmodule PlatformWeb.ChatLive.ChatListDataTest do
  @moduledoc """
  `ChatListData.sort_by_recency/3`, the phone Chat list's order inside a
  section (task 01a166bf stage 1). Pure, so no database.
  """

  use ExUnit.Case, async: true

  alias PlatformWeb.ChatLive.ChatListData

  defp space(id, name), do: %{id: id, name: name}
  defp at(iso), do: elem(DateTime.from_iso8601(iso), 1)

  test "sort_by_recency: newest first, no-excerpt rows last by name" do
    rows = [
      space("id-a", "zulu quiet"),
      space("id-b", "Older"),
      space("id-c", "alpha quiet"),
      space("id-d", "Newest"),
      space("id-e", "Middle"),
      space("id-f", "Bravo quiet"),
      # Same instant as Middle: the name breaks the tie.
      space("id-g", "Kilo tie")
    ]

    excerpts = %{
      # id-d is one microsecond after id-e. As strings, "…09:05:00Z" sorts
      # AFTER "…09:05:00.000001Z" ("Z" > "."), so only DateTime.compare/2
      # puts id-d first.
      "id-b" => %{inserted_at: at("2026-10-23T23:59:00Z")},
      "id-d" => %{inserted_at: at("2026-10-24T09:05:00.000001Z")},
      "id-e" => %{inserted_at: at("2026-10-24T09:05:00Z")},
      "id-g" => %{inserted_at: at("2026-10-24T09:05:00Z")}
    }

    sorted = ChatListData.sort_by_recency(rows, excerpts, & &1.name)

    # id-g and id-e share an instant: "kilo tie" < "middle". The quiet rows
    # follow by downcased name, so "Bravo" sits between "alpha" and "zulu".
    assert Enum.map(sorted, & &1.id) ==
             ["id-d", "id-g", "id-e", "id-b", "id-c", "id-f", "id-a"]

    # Pinned entries carry the space under `:space`; the same order applies.
    entries = Enum.map(rows, &%{kind: :channel, space: &1})
    sorted_entries = ChatListData.sort_by_recency(entries, excerpts, & &1.space.name)
    assert Enum.map(sorted_entries, & &1.space.id) == Enum.map(sorted, & &1.id)

    # Equal time and equal name: the id decides, so the order is total.
    twins = [space("id-2", "Same"), space("id-1", "same")]
    same = %{inserted_at: at("2026-10-24T09:00:00Z")}

    assert ChatListData.sort_by_recency(twins, %{"id-1" => same, "id-2" => same}, & &1.name)
           |> Enum.map(& &1.id) == ["id-1", "id-2"]

    # No excerpts at all: plain name order.
    assert ChatListData.sort_by_recency(rows, %{}, & &1.name) |> Enum.map(& &1.name) ==
             ["alpha quiet", "Bravo quiet", "Kilo tie", "Middle", "Newest", "Older", "zulu quiet"]
  end

  test "order_rows: no hold is recency; a hold keeps the snapshot and appends unknown ids by recency" do
    rows = [space("a", "A"), space("b", "B"), space("c", "C"), space("d", "D"), space("e", "E")]

    excerpts = %{
      "a" => %{inserted_at: at("2026-10-24T09:00:00Z")},
      "b" => %{inserted_at: at("2026-10-24T10:00:00Z")},
      "d" => %{inserted_at: at("2026-10-24T12:00:00Z")},
      "e" => %{inserted_at: at("2026-10-24T11:00:00Z")}
    }

    ids = &Enum.map(&1, fn row -> row.id end)

    assert ids.(ChatListData.order_rows(rows, excerpts, nil, & &1.name)) ==
             ids.(ChatListData.sort_by_recency(rows, excerpts, & &1.name))

    # The snapshot names c, a, b (and a gone id); d and e are new, d newer.
    assert ids.(ChatListData.order_rows(rows, excerpts, ["c", "gone", "a", "b"], & &1.name)) ==
             ["c", "a", "b", "d", "e"]

    # Pinned entries carry the space under :space.
    entries = Enum.map(rows, &%{kind: :channel, space: &1})

    assert entries
           |> ChatListData.order_rows(excerpts, ["e", "a"], & &1.space.name)
           |> Enum.map(& &1.space.id) == ["e", "a", "d", "b", "c"]
  end
end

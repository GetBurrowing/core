defmodule PlatformWeb.Tasks.BoardDataSortTest do
  @moduledoc """
  `BoardData.sort_items/3` and `Task.priority_rank/1` (task 01a0cef1 stage 1).

  The board's rendered order is set by in-memory re-sorts, not by the
  queries, so the order is pinned here on the pure function and on the two
  `BoardData` bucketers that call it. The LiveView half (both rendered
  surfaces) is `PlatformWeb.TasksLivePrioritySortTest`.

  Fixture shape, load-bearing:

    * one task per priority plus `nil` and the unknown `"urgent"`, listed
      OUT of rank order;
    * `inserted_at` values that cross a month boundary (Jan -> Feb), each
      written out, not derived with `DateTime.add/3` from one shared now;
    * `updated_at` in the OPPOSITE order to `inserted_at`, so within a
      priority `:priority` (newest inserted first) and `:updated` (newest
      updated first) disagree;
    * ids whose descending order is NOT the expected order, so an
      id-only sort cannot pass the full-list assertions.

  Pure structs, no DB.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks.{Stack, Task}
  alias PlatformWeb.Tasks.BoardData

  defp dt(iso) do
    {:ok, value, 0} = DateTime.from_iso8601(iso)
    value
  end

  defp task(id, priority, inserted, updated, attrs \\ %{}) do
    struct!(
      Task,
      Map.merge(
        %{
          id: id,
          title: "task #{id}",
          priority: priority,
          status: "backlog",
          stack_id: nil,
          inserted_at: dt(inserted),
          updated_at: dt(updated)
        },
        attrs
      )
    )
  end

  # Names: letter = priority, digit = insertion order within it.
  #   inserted: L1 < C1 < M1 < H1 < L2 < C2 < N1 < U1   (Jan 10 .. Feb 15)
  #   updated:  exactly reversed (L1 newest-updated, U1 oldest-updated)
  defp l1,
    do:
      task(
        "0a000000-0000-7000-8000-000000000007",
        "low",
        "2026-01-10T09:00:00.000000Z",
        "2026-03-08T00:00:00.000000Z"
      )

  defp c1,
    do:
      task(
        "0a000000-0000-7000-8000-000000000003",
        "critical",
        "2026-01-20T09:00:00.000000Z",
        "2026-03-07T00:00:00.000000Z"
      )

  defp m1,
    do:
      task(
        "0a000000-0000-7000-8000-000000000008",
        "medium",
        "2026-01-31T23:00:00.000000Z",
        "2026-03-06T00:00:00.000000Z"
      )

  defp h1,
    do:
      task(
        "0a000000-0000-7000-8000-000000000001",
        "high",
        "2026-02-01T01:00:00.000000Z",
        "2026-03-05T00:00:00.000000Z"
      )

  defp l2,
    do:
      task(
        "0a000000-0000-7000-8000-000000000005",
        "low",
        "2026-02-05T09:00:00.000000Z",
        "2026-03-04T00:00:00.000000Z"
      )

  defp c2,
    do:
      task(
        "0a000000-0000-7000-8000-000000000002",
        "critical",
        "2026-02-10T09:00:00.000000Z",
        "2026-03-03T00:00:00.000000Z"
      )

  defp n1,
    do:
      task(
        "0a000000-0000-7000-8000-000000000006",
        nil,
        "2026-02-12T09:00:00.000000Z",
        "2026-03-02T00:00:00.000000Z"
      )

  defp u1,
    do:
      task(
        "0a000000-0000-7000-8000-000000000004",
        "urgent",
        "2026-02-15T09:00:00.000000Z",
        "2026-03-01T00:00:00.000000Z"
      )

  # Deliberately scrambled input.
  defp seeded, do: [m1(), u1(), l1(), c1(), n1(), h1(), l2(), c2()]

  defp ids(items), do: Enum.map(items, & &1.id)

  defp stack(id, inserted) do
    %Stack{
      id: id,
      name: "stack #{id}",
      status: "backlog",
      inserted_at: dt(inserted),
      updated_at: dt(inserted)
    }
  end

  describe "Task.priority_rank/1" do
    test "ranks by meaning, and nil / unknown strings after low" do
      assert Task.priority_rank("critical") == 0
      assert Task.priority_rank("high") == 1
      assert Task.priority_rank("medium") == 2
      assert Task.priority_rank("low") == 3
      assert Task.priority_rank(nil) == 4
      assert Task.priority_rank("urgent") == 4
      assert Task.priority_rank("") == 4
    end

    test "covers every declared priority with a rank below the unknown bucket" do
      for p <- Task.priorities(), do: assert(Task.priority_rank(p) < 4)
    end
  end

  describe "sort_items/3 :priority" do
    test "full list: critical, high, medium, low, then nil/unknown; newest-inserted first within one" do
      # Premise of the fixture: alphabetical order on the strings would put
      # low before medium, which is the failure this ranking exists to stop.
      assert Enum.sort(["low", "medium"]) == ["low", "medium"]

      expected = ids([c2(), c1(), h1(), m1(), l2(), l1(), u1(), n1()])

      assert ids(BoardData.sort_items(seeded(), :priority)) == expected
    end

    test "nil and \"urgent\" both sort after every low task" do
      sorted = ids(BoardData.sort_items(seeded(), :priority))

      last_low =
        Enum.max(Enum.map([l1().id, l2().id], &Enum.find_index(sorted, fn id -> id == &1 end)))

      assert Enum.find_index(sorted, &(&1 == n1().id)) > last_low
      assert Enum.find_index(sorted, &(&1 == u1().id)) > last_low
    end

    test "tiebreak: equal priority and inserted_at give the same output for both input orders (id desc)" do
      a =
        task(
          "0a000000-0000-7000-8000-00000000000a",
          "critical",
          "2026-02-10T09:00:00.000000Z",
          "2026-03-01T00:00:00.000000Z"
        )

      b =
        task(
          "0a000000-0000-7000-8000-00000000000b",
          "critical",
          "2026-02-10T09:00:00.000000Z",
          "2026-03-01T00:00:00.000000Z"
        )

      assert ids(BoardData.sort_items([a, b], :priority)) == [b.id, a.id]
      assert ids(BoardData.sort_items([b, a], :priority)) == [b.id, a.id]
    end

    test "permutation sanity: nothing dropped or duplicated" do
      input = seeded()
      assert Enum.sort(ids(BoardData.sort_items(input, :priority))) == Enum.sort(ids(input))
      assert Enum.sort(ids(BoardData.sort_items(input, :updated))) == Enum.sort(ids(input))
    end
  end

  describe "sort_items/3 :updated" do
    test "exact updated_at-desc list" do
      expected = ids([l1(), c1(), m1(), h1(), l2(), c2(), n1(), u1()])
      assert ids(BoardData.sort_items(seeded(), :updated)) == expected
    end

    test "ties on updated_at resolve by id desc for both input orders" do
      a =
        task(
          "0a000000-0000-7000-8000-00000000000a",
          "low",
          "2026-01-01T00:00:00.000000Z",
          "2026-03-01T00:00:00.000000Z"
        )

      b =
        task(
          "0a000000-0000-7000-8000-00000000000b",
          "high",
          "2026-02-01T00:00:00.000000Z",
          "2026-03-01T00:00:00.000000Z"
        )

      assert ids(BoardData.sort_items([a, b], :updated)) == [b.id, a.id]
      assert ids(BoardData.sort_items([b, a], :updated)) == [b.id, a.id]
    end
  end

  describe "sort_items/3 stacks" do
    test "a stack ranks as its best member: critical member beats a standalone high task" do
      s = stack("0b000000-0000-7000-8000-000000000001", "2026-01-01T00:00:00.000000Z")

      member_low =
        task(
          "0c000000-0000-7000-8000-000000000001",
          "low",
          "2026-01-01T00:00:00.000000Z",
          "2026-01-01T00:00:00.000000Z",
          %{stack_id: s.id}
        )

      member_crit =
        task(
          "0c000000-0000-7000-8000-000000000002",
          "critical",
          "2026-01-01T00:00:00.000000Z",
          "2026-01-01T00:00:00.000000Z",
          %{stack_id: s.id}
        )

      data = %{s.id => %{members: [member_low, member_crit]}}

      # The stack is OLDER than h1, so recency alone would put it after.
      assert ids(BoardData.sort_items([h1(), s], :priority, data)) == [s.id, h1().id]
    end

    test "an empty stack, or one with no board data, ranks 4 (after low)" do
      empty = stack("0b000000-0000-7000-8000-000000000002", "2026-03-01T00:00:00.000000Z")
      unknown = stack("0b000000-0000-7000-8000-000000000003", "2026-02-28T00:00:00.000000Z")
      data = %{empty.id => %{members: []}}

      sorted = ids(BoardData.sort_items([empty, unknown, l1(), n1()], :priority, data))
      # rank 4 among themselves by newest inserted: empty (Mar 1), unknown (Feb 28), n1 (Feb 12)
      assert sorted == [l1().id, empty.id, unknown.id, n1().id]
    end
  end

  describe "bucketers route through sort_items/3" do
    test "group_board_items/3 (mobile) orders a column with stacks interleaved" do
      s = stack_struct()

      member =
        task(
          "0c000000-0000-7000-8000-000000000009",
          "critical",
          "2026-01-01T00:00:00.000000Z",
          "2026-01-01T00:00:00.000000Z",
          %{stack_id: s.id, status: "stack_pending"}
        )

      entries = [{s, %{members: [member]}}]

      backlog = BoardData.group_board_items(seeded() ++ [member], entries, :priority)["backlog"]

      assert ids(backlog) == ids([c2(), s, c1(), h1(), m1(), l2(), l1(), u1(), n1()])

      updated = BoardData.group_board_items(seeded(), [], :updated)["backlog"]
      assert ids(updated) == ids([l1(), c1(), m1(), h1(), l2(), c2(), n1(), u1()])
    end

    test "bucket_tasks_by_desktop_column/2 (search-narrowed desktop) orders each bucket" do
      # The bucketer keys with `String.to_existing_atom/1`. In an isolated,
      # async unit run the column atoms need not exist yet (measured: a run
      # raised `not an already existing atom` for "deploying"), so this
      # module names all seven as literals, which also pins the key set.
      column_keys = [:backlog, :planning, :in_progress, :blocked, :in_review, :deploying, :done]

      assert Enum.sort(Map.keys(BoardData.bucket_tasks_by_desktop_column([], :priority))) ==
               Enum.sort(column_keys)

      assert ids(BoardData.bucket_tasks_by_desktop_column(seeded(), :priority).backlog) ==
               ids([c2(), c1(), h1(), m1(), l2(), l1(), u1(), n1()])

      assert ids(BoardData.bucket_tasks_by_desktop_column(seeded(), :updated).backlog) ==
               ids([l1(), c1(), m1(), h1(), l2(), c2(), n1(), u1()])
    end
  end

  # Task 01a161fd stage 1. M1 (Jan 31 23:00) and H1 (Feb 1 01:00) straddle a
  # month boundary, where term order on `%DateTime{}` (day 31 > day 1) is
  # wrong; the exact lists below only hold when timestamps compare as
  # integers.
  describe "sort_items/3 :newest and :oldest" do
    test "exact inserted_at-desc list for :newest" do
      expected = ids([u1(), n1(), c2(), l2(), h1(), m1(), c1(), l1()])
      assert ids(BoardData.sort_items(seeded(), :newest)) == expected
    end

    test "exact inserted_at-asc list for :oldest" do
      expected = ids([l1(), c1(), m1(), h1(), l2(), c2(), n1(), u1()])
      assert ids(BoardData.sort_items(seeded(), :oldest)) == expected
    end

    test "ties on inserted_at resolve by id desc for both input orders (a total order)" do
      a =
        task(
          "0a000000-0000-7000-8000-00000000000a",
          "low",
          "2026-01-01T00:00:00.000000Z",
          "2026-03-01T00:00:00.000000Z"
        )

      b =
        task(
          "0a000000-0000-7000-8000-00000000000b",
          "high",
          "2026-01-01T00:00:00.000000Z",
          "2026-03-02T00:00:00.000000Z"
        )

      for mode <- [:newest, :oldest] do
        assert ids(BoardData.sort_items([a, b], mode)) == [b.id, a.id]
        assert ids(BoardData.sort_items([b, a], mode)) == [b.id, a.id]
      end
    end
  end

  describe "default_sort/0 (task 01a197a0)" do
    test "the board default is :updated (Recently updated)" do
      assert BoardData.default_sort() == :updated
    end
  end

  describe "decode_sort/1" do
    test "\"newest\" and \"oldest\" select their modes, case-sensitively" do
      assert BoardData.decode_sort("newest") == :newest
      assert BoardData.decode_sort("oldest") == :oldest
      assert BoardData.decode_sort("Newest") == :updated
    end

    test "only \"priority\" selects :priority; nil, \"updated\" and bogus are the default :updated" do
      assert BoardData.decode_sort("priority") == :priority
      assert BoardData.decode_sort("Priority") == :updated
      assert BoardData.decode_sort("updated") == :updated
      assert BoardData.decode_sort(nil) == :updated
      assert BoardData.decode_sort("bogus") == :updated
    end
  end

  # Stage 2: the one builder every patch back to the board goes through.
  doctest BoardData, only: [tasks_path: 2]

  describe "tasks_path/2" do
    test "emits no param for either default, and a fixed sponsor-then-sort key order" do
      assert BoardData.tasks_path(:all, :updated) == "/tasks"
      assert BoardData.tasks_path(:mine, :updated) == "/tasks?sponsor=mine"
      assert BoardData.tasks_path(:all, :priority) == "/tasks?sort=priority"
      assert BoardData.tasks_path(:mine, :priority) == "/tasks?sponsor=mine&sort=priority"
    end

    test "every non-default mode is emitted, so a chosen sort survives a reload" do
      for mode <- BoardData.sort_modes() -- [BoardData.default_sort()] do
        assert BoardData.tasks_path(:all, mode) == "/tasks?sort=#{mode}"
      end
    end

    test "an unset assign reads as the default, never as a param" do
      assert BoardData.tasks_path(nil, nil) == "/tasks"
      assert BoardData.tasks_path(:mine, nil) == "/tasks?sponsor=mine"
    end

    test "tasks_path/1 reads the same two assigns" do
      assert BoardData.tasks_path(%{sponsor_filter: :mine, board_sort: :priority}) ==
               "/tasks?sponsor=mine&sort=priority"

      assert BoardData.tasks_path(%{sponsor_filter: :mine, board_sort: :updated}) ==
               "/tasks?sponsor=mine"

      assert BoardData.tasks_path(%{}) == "/tasks"
    end

    test "round-trips through decode_sort/1" do
      for mode <- BoardData.sort_modes(), sponsor <- [:all, :mine] do
        %URI{query: query} = URI.parse(BoardData.tasks_path(sponsor, mode))
        params = URI.decode_query(query || "")
        assert BoardData.decode_sort(params["sort"]) == mode
        assert Map.get(params, "sponsor") == if(sponsor == :mine, do: "mine")
      end
    end
  end

  # Inserted between c2 (Feb 10) and c1 (Jan 20), so a critical-member stack
  # lands between them on the newest-inserted key.
  defp stack_struct do
    %Stack{
      id: "0b000000-0000-7000-8000-000000000009",
      name: "interleave stack",
      status: "backlog",
      inserted_at: dt("2026-01-25T00:00:00.000000Z"),
      updated_at: dt("2026-01-25T00:00:00.000000Z")
    }
  end
end

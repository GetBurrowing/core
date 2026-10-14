defmodule Platform.Types.UUIDv7MonotonicTest do
  @moduledoc """
  UUIDv7 must sort in creation order for ids minted inside the SAME
  millisecond (RFC 9562 §6.2 method 2).

  This is not decorative. Five separate sites relied on it and every one
  failed the moment CI moved to a host fast enough to put several writes
  in one millisecond — task `01a0506e`. The moduledoc promised
  "lexicographic sort = chronological order" while `rand_a` was random,
  so the promise held only when the clock happened to separate writes.

  The fixture generates in a tight loop so collisions actually occur. A
  test that generated ids slowly would pass against the broken
  implementation, which is exactly how this survived.
  """
  use ExUnit.Case, async: true

  alias Platform.Types.UUIDv7

  @count 3000

  defp ms_prefix(id), do: String.slice(id, 0, 13)

  test "ids minted in the same millisecond sort in creation order" do
    ids = for _ <- 1..@count, do: UUIDv7.generate()
    groups = Enum.chunk_by(ids, &ms_prefix/1)

    # Guard the guard: if every id landed in its own millisecond this test
    # asserts nothing, so fail loudly rather than passing vacuously.
    largest = groups |> Enum.map(&length/1) |> Enum.max()

    assert largest > 1,
           "No two ids shared a millisecond, so this test exercised nothing."

    out_of_order = Enum.filter(groups, fn g -> g != Enum.sort(g) end)

    assert out_of_order == [],
           "#{length(out_of_order)} of #{length(groups)} millisecond-groups sorted " <>
             "differently from generation order. Within one millisecond the " <>
             "timestamp cannot separate ids, so rand_a must be a monotonic counter."
  end

  @tasks 16

  # The single-process case above cannot see a race between minters; this
  # one makes 16 of them collide on the shared counter at once. Each task's
  # own ids must still sort in the order that task generated them (task
  # 01a13aac: a two-write millisecond reset let a minter draw from the old
  # millisecond's sequence and then from the new one, so its own ids within
  # one millisecond came back reversed).
  test "ids minted concurrently sort in each minter's own generation order" do
    tasks =
      for _ <- 1..@tasks do
        Task.async(fn ->
          receive do
            :go -> for _ <- 1..@count, do: UUIDv7.generate()
          end
        end)
      end

    # Release them only once all exist, so they contend for the counter
    # rather than each finishing before the next is spawned.
    Enum.each(tasks, &send(&1.pid, :go))
    per_task = Task.await_many(tasks, 60_000)

    groups = Enum.flat_map(per_task, &Enum.chunk_by(&1, fn id -> ms_prefix(id) end))

    # Guard the guard: with no shared millisecond inside any one task there
    # is nothing to order, and this test would pass against any counter.
    largest = groups |> Enum.map(&length/1) |> Enum.max()

    assert largest > 1,
           "No task minted two ids in one millisecond, so this test exercised nothing."

    out_of_order = Enum.filter(groups, fn g -> g != Enum.sort(g) end)

    assert out_of_order == [],
           "#{length(out_of_order)} of #{length(groups)} per-task millisecond-groups " <>
             "sorted differently from that task's generation order across " <>
             "#{@tasks} concurrent minters. The millisecond and its counter must " <>
             "advance as one atomic step."

    assert length(Enum.uniq(List.flatten(per_task))) == @tasks * @count
  end

  test "the counter does not cost uniqueness" do
    ids = for _ <- 1..@count, do: UUIDv7.generate()
    assert length(Enum.uniq(ids)) == @count
  end

  test "ordering across milliseconds does not depend on the counter" do
    a = UUIDv7.generate()
    Process.sleep(2)
    b = UUIDv7.generate()

    assert a < b
    assert ms_prefix(a) != ms_prefix(b)
  end
end

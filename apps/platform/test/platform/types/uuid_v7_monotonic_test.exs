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

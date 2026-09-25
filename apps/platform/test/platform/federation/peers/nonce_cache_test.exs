defmodule Platform.Federation.Peers.NonceCacheTest do
  @moduledoc "Task 01a0d90f stage 3: the replay cache's expiry and sweep (ADR 0054 section 2)."

  # async: false — the table is a named, node-wide ETS table.
  use ExUnit.Case, async: false

  alias Platform.Federation.Peers.NonceCache

  setup do
    NonceCache.reset()
    on_exit(&NonceCache.reset/0)
    :ok
  end

  @now 1_800_000_000_000

  test "a nonce is fresh once per peer and window" do
    assert NonceCache.check_and_record("peer-a", "n1", @now, @now) == :ok

    assert NonceCache.check_and_record("peer-a", "n1", @now, @now + 1) ==
             {:error, :replayed_nonce}

    # keyed per peer: the same nonce from another peer is its own entry
    assert NonceCache.check_and_record("peer-b", "n1", @now, @now) == :ok
  end

  test "expiry follows the envelope ts, so a future-dated nonce is held past arrival + window" do
    ts = @now + 299_000
    assert NonceCache.check_and_record("peer-a", "n2", ts, @now) == :ok

    # arrival + window has passed, but ts + window has not
    assert NonceCache.check_and_record("peer-a", "n2", ts, @now + NonceCache.window_ms() + 1) ==
             {:error, :replayed_nonce}

    # after ts + window the old entry no longer blocks (the ts check refuses it anyway)
    assert NonceCache.check_and_record("peer-a", "n2", ts, ts + NonceCache.window_ms()) == :ok
  end

  test "sweep deletes only expired rows" do
    :ok = NonceCache.check_and_record("peer-a", "old", @now, @now)
    :ok = NonceCache.check_and_record("peer-a", "new", @now + 60_000, @now + 60_000)

    assert NonceCache.sweep(@now + NonceCache.window_ms()) == 1
    assert NonceCache.size() == 1

    assert NonceCache.check_and_record("peer-a", "new", @now, @now + 60_001) ==
             {:error, :replayed_nonce}
  end

  test "the propose-fetch counter counts per hour and survives the nonce sweep" do
    assert NonceCache.count_propose_fetch(@now) == 1
    assert NonceCache.count_propose_fetch(@now + 1) == 2

    assert NonceCache.sweep(@now + NonceCache.window_ms()) == 0
    assert NonceCache.count_propose_fetch(@now + 2) == 3

    # the next hour starts again; the old hour's row is swept once it ends
    next_hour = (div(@now, 3_600_000) + 1) * 3_600_000
    assert NonceCache.count_propose_fetch(next_hour) == 1
    assert NonceCache.sweep(next_hour) == 1
  end
end

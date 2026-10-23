defmodule Platform.Social.RateLimitTest do
  @moduledoc """
  Per-account fixed window, read from config on every call. A refused call
  counts nothing; accounts are independent. Global table, so `async: false`.
  """
  use ExUnit.Case, async: false

  alias Platform.Social.RateLimit

  setup do
    previous = Application.get_env(:social, :rate_limit)
    RateLimit.reset()
    on_exit(fn -> Application.put_env(:social, :rate_limit, previous) end)
    :ok
  end

  defp limit(n, w), do: Application.put_env(:social, :rate_limit, per_window: n, window_ms: w)

  test "N calls pass, the N+1th is refused, and account B still passes" do
    limit(3, 60_000)
    now = 1_000_000_000

    for _ <- 1..3, do: assert(:ok = RateLimit.check("acct-a", now))
    assert {:error, :rate_limited} = RateLimit.check("acct-a", now)
    assert {:error, :rate_limited} = RateLimit.check("acct-a", now + 1)
    assert :ok = RateLimit.check("acct-b", now)
  end

  test "a refusal counts nothing, and the next window starts fresh" do
    limit(1, 60_000)
    now = 2_000_000_000 - rem(2_000_000_000, 60_000)

    assert :ok = RateLimit.check("acct-c", now)
    for _ <- 1..5, do: assert({:error, :rate_limited} = RateLimit.check("acct-c", now))
    assert [{_, 1}] = :ets.lookup(:social_publish_rate, {"acct-c", div(now, 60_000)})

    assert :ok = RateLimit.check("acct-c", now + 60_000)
  end

  test "the default is 25 per hour (the vendor's velocity cap)" do
    Application.delete_env(:social, :rate_limit)
    now = 3_600_000 * 1000

    for _ <- 1..25, do: assert(:ok = RateLimit.check("acct-d", now))
    assert {:error, :rate_limited} = RateLimit.check("acct-d", now + 3_599_999)
    assert :ok = RateLimit.check("acct-d", now + 3_600_000)
  end

  test "window_ends_at is the start of the next window, from the same settings" do
    limit(3, 60_000)
    start = 1_000_020_000 - rem(1_000_020_000, 60_000)

    assert RateLimit.window_ends_at(start) == start + 60_000
    assert RateLimit.window_ends_at(start + 59_999) == start + 60_000
    assert RateLimit.window_ends_at(start + 60_000) == start + 120_000

    # The window check/2 refuses in ends exactly there: the next call passes.
    for _ <- 1..3, do: assert(:ok = RateLimit.check("acct-e", start + 10))
    assert {:error, :rate_limited} = RateLimit.check("acct-e", start + 59_999)
    assert :ok = RateLimit.check("acct-e", RateLimit.window_ends_at(start + 10))

    Application.delete_env(:social, :rate_limit)
    assert RateLimit.window_ends_at(3_600_000 * 7 + 5) == 3_600_000 * 8
  end
end

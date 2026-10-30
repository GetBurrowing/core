defmodule Platform.Push.RelayRateLimitTest do
  # Push relay fixtures reset the shared ETS table, so these cases must not
  # overlap them. Unique installs keep our counters independent without resets.
  use ExUnit.Case, async: false

  alias Platform.Push.RelayRateLimit

  setup do
    # Keep both synthetic minutes ahead of the real clock so the periodic
    # sweep cannot remove the prior window while this test exercises it.
    boundary = (div(System.system_time(:millisecond), 60_000) + 10) * 60_000
    {:ok, install_id: Ecto.UUID.generate(), boundary: boundary}
  end

  test "refused batches refund every item before the minute boundary", %{
    install_id: install_id,
    boundary: boundary
  } do
    now = boundary - 1

    assert :ok = RelayRateLimit.check(install_id, 2, 3, now)
    assert {:error, :rate_limited} = RelayRateLimit.check(install_id, 2, 3, now)
    assert {:error, :rate_limited} = RelayRateLimit.check(install_id, 2, 3, now)
    assert :ok = RelayRateLimit.check(install_id, 1, 3, now)
    assert {:error, :rate_limited} = RelayRateLimit.check(install_id, 1, 3, now)
  end

  test "one fixed minute spans its first and last millisecond and resets at the boundary", %{
    install_id: install_id,
    boundary: boundary
  } do
    assert :ok = RelayRateLimit.check(install_id, 2, 3, boundary - 60_000)
    assert :ok = RelayRateLimit.check(install_id, 1, 3, boundary - 1)
    assert {:error, :rate_limited} = RelayRateLimit.check(install_id, 1, 3, boundary - 1)

    assert :ok = RelayRateLimit.check(install_id, 3, 3, boundary)
    assert {:error, :rate_limited} = RelayRateLimit.check(install_id, 1, 3, boundary)
    assert :ok = RelayRateLimit.check(Ecto.UUID.generate(), 3, 3, boundary)
  end
end

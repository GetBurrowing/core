defmodule Platform.Meetings.VoiceSeatCacheTest do
  @moduledoc """
  `Platform.Meetings.VoiceSeatCache` (task 01a06e07 stage 2) — the bound
  in front of `Meetings.resolve_voice_target/1` that `AgentDelayReason`'s
  "no voice worker in this room" cause depends on.

  Fixture shape borrowed from `transcript_delivery_test.exs`: real rows
  through `Federation.register_voice_runtime/3` and a real
  `PlatformWeb.RuntimeSocket` join declaring `meeting_voice`, because an
  offline voice row is invisible to `resolve_voice_target/1` (it falls
  back to the brain) and a fixture that cannot tell the two apart would
  not be testing presence at all.

  Two tests prove the cache actually caches, rather than merely
  returning the right answer once: one shows a STALE entry gets
  recomputed, the other shows a FRESH entry short-circuits the real
  resolve — the second is the one doing the anti-vacuity work, because
  a `seated?/1` that ignored the cache entirely would still pass every
  other test in this file.

  `async: false` — `RuntimePresence` is one named process and
  `VoiceSeatCache` owns one named ETS table shared by every test.
  """
  use PlatformWeb.ChannelCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Meetings.VoiceSeatCache
  alias Platform.Repo

  @table :meeting_voice_seat_cache

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice-seat-cache-#{n}@example.com",
      name: "Voice Seat Cache #{n}",
      oidc_sub: "oidc-voice-seat-cache-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "voice-seat-cache-agent-#{n}",
      name: "Voice Seat Cache Agent #{n}",
      status: "active"
    })
  end

  defp join_voice_client!(runtime, raw_token) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, joined} =
      join(socket, "runtime:#{runtime.runtime_id}", %{
        "client_info" => %{
          "product" => "openclaw",
          "version" => "0.1.0",
          "features" => ["meeting_voice"]
        }
      })

    joined
  end

  test "ttl_ms/0 is 3 seconds" do
    assert VoiceSeatCache.ttl_ms() == 3_000
  end

  test "an agent with no runtime at all is not seated" do
    agent = agent!()
    assert is_nil(agent.runtime_id)

    refute VoiceSeatCache.seated?(agent)
  end

  test "an agent with an ONLINE voice-capable runtime is seated" do
    owner = user!()
    agent = agent!()
    {:ok, runtime, raw_token} = Federation.register_voice_runtime(owner.id, agent)
    _client = join_voice_client!(runtime, raw_token)

    assert VoiceSeatCache.seated?(agent)
  end

  test "an agent whose voice-capable runtime is registered but OFFLINE is not seated" do
    owner = user!()
    agent = agent!()
    {:ok, _runtime, _raw_token} = Federation.register_voice_runtime(owner.id, agent)

    # No `join_voice_client!/2` — the row exists but nothing is
    # connected, which is exactly `resolve_voice_target/1`'s
    # `:voice_runtime_offline` branch.
    refute VoiceSeatCache.seated?(agent)
  end

  # The cache actually SHORT-CIRCUITS: a fresh entry recording `true` is
  # returned even for an agent that would, right now, really resolve to
  # `false`. If `seated?/1` ignored the cache and always re-resolved,
  # this would read `false` and the test would fail — so a false pass
  # here is not available by accident.
  test "a fresh cache entry is trusted without re-resolving" do
    agent = agent!()
    assert is_nil(agent.runtime_id)

    now = System.monotonic_time(:millisecond)
    true = :ets.insert(@table, {agent.id, true, now})

    assert VoiceSeatCache.seated?(agent)
  end

  # The mirror image: an entry older than `ttl_ms/0` is NOT trusted, and
  # the real answer is recomputed (and re-cached).
  test "a stale cache entry is recomputed, not trusted" do
    owner = user!()
    agent = agent!()
    {:ok, runtime, raw_token} = Federation.register_voice_runtime(owner.id, agent)
    _client = join_voice_client!(runtime, raw_token)

    stale_at = System.monotonic_time(:millisecond) - VoiceSeatCache.ttl_ms() - 1
    true = :ets.insert(@table, {agent.id, false, stale_at})

    assert VoiceSeatCache.seated?(agent)

    # And the recomputed answer is itself now cached fresh.
    assert [{_agent_id, true, cached_at}] = :ets.lookup(@table, agent.id)
    assert System.monotonic_time(:millisecond) - cached_at < VoiceSeatCache.ttl_ms()
  end
end

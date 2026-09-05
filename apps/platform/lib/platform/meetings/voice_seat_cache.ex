defmodule Platform.Meetings.VoiceSeatCache do
  @moduledoc """
  A short-TTL cache in front of `Platform.Meetings.resolve_voice_target/1`
  (task 01a06e07 stage 2).

  ## Why this exists

  The delay reason "no voice worker in this room"
  (`Platform.Meetings.AgentDelayReason`) is the one cause of the five that
  is NOT cheap. The other causes read `Platform.Meetings.SayRegistry`'s ETS
  ledger or `Platform.Federation.RuntimePresence`'s in-memory map — both
  synchronous, in-process, no DB. Whether an agent has a seated voice
  worker is decided by `resolve_voice_target/1`, which is a DB read
  (`Federation.runtimes_for_agent/1`) PLUS a presence read, and the
  planner's own correction for this stage is explicit that a per-agent,
  per-second render tick (stage 3's territory) calling that directly is
  unbounded work driven by a clock.

  This module is the bound. It sits between the two: whichever gatherer
  stage 3 builds calls `seated?/1` instead of `Meetings.resolve_voice_target/1`
  directly, and the DB read underneath happens at most once per agent per
  `ttl_ms/0`, no matter how many times `seated?/1` is called in that window
  — one tick, ten agents' renders, or ten browser tabs on the same room
  all watching the same agent.

  ## Storage

  ETS, one row per agent id, owned by this GenServer purely for the
  table's lifecycle — reads and writes are direct from the caller's
  process, the same shape as `Platform.Meetings.PressWindow` and
  `Platform.Meetings.SayRegistry`. Unlike those two, there is no sweep:
  the table is bounded by the number of distinct agents ever asked
  about, not by utterances or ticks, so it cannot grow per-second the
  way an unswept ledger would. A stale row is corrected on its own next
  read once its TTL has passed; nothing needs to proactively delete it.

  ## What "seated" means here

  `true` when `Meetings.resolve_voice_target/1` currently resolves to
  `{:ok, _}` for the agent — a connected runtime that can actually speak
  for it in a room, whether that is a dedicated voice-capable row or (via
  that function's own legacy fallback) the brain. `false` for either of
  its error branches. This cache does not distinguish
  `:voice_runtime_offline` from `:no_runtime`; if a caller ever needs
  that distinction, `Meetings.resolve_voice_target/1` remains available
  uncached.
  """

  use GenServer

  alias Platform.Agents.Agent
  alias Platform.Meetings

  @table :meeting_voice_seat_cache

  # Long enough to absorb a per-second render tick across every viewer of
  # a room; short enough that a voice worker connecting or dropping is
  # reflected within a couple of ticks. Chosen, not measured — if stage 3
  # finds this stale or thrashing, it is the dial.
  @ttl_ms 3_000

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        # A supervisor restart that raced the old owner's exit.
        :ok
    end

    {:ok, %{}}
  end

  # ── Tunables ───────────────────────────────────────────────────────────────

  @doc "Milliseconds a cached answer is trusted before `seated?/1` re-resolves it."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  # ── Read ───────────────────────────────────────────────────────────────────

  @doc """
  Whether `agent` currently has a voice worker that can speak for it,
  per `Meetings.resolve_voice_target/1` — cached for `ttl_ms/0`.

  Bypasses the cache (and writes a fresh entry) whenever the stored
  answer is missing or older than `ttl_ms/0`. The underlying resolve is
  otherwise never called more than once per agent per TTL window.
  """
  @spec seated?(Agent.t()) :: boolean()
  def seated?(%Agent{id: agent_id} = agent) when is_binary(agent_id) do
    now = System.monotonic_time(:millisecond)

    case cached(agent_id, now) do
      {:ok, seated?} -> seated?
      :stale -> resolve_and_cache(agent, now)
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  defp cached(agent_id, now) do
    if table?() do
      case :ets.lookup(@table, agent_id) do
        [{^agent_id, seated?, cached_at_ms}] when now - cached_at_ms < @ttl_ms ->
          {:ok, seated?}

        _ ->
          :stale
      end
    else
      :stale
    end
  end

  defp resolve_and_cache(%Agent{} = agent, now) do
    seated? =
      case Meetings.resolve_voice_target(agent) do
        {:ok, _target} -> true
        {:error, _reason} -> false
      end

    if table?(), do: :ets.insert(@table, {agent.id, seated?, now})

    seated?
  end

  # Wrapped so a call during early boot (before `init/1` installed the
  # table) degrades to "always resolve" rather than crashing the caller —
  # the same guard `Platform.Meetings.PressWindow` uses.
  defp table?, do: :ets.info(@table) != :undefined
end

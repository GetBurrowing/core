defmodule Platform.Responsibilities.CutoverMonitor do
  @moduledoc """
  Per-day counter of router vs legacy responsibility firings for the M8
  cutover signal (ADR-0041 M8 stage 6).

  Subscribes to two telemetry events:

    * `[:platform, :responsibility, :fired]` — emitted by the M6
      `Platform.Responsibilities.Router` whenever a router-path dispatch
      succeeds. Counts toward `router` for the firing's `key`.
    * `[:platform, :responsibilities, :dual_write]` — emitted by the
      legacy `Platform.Agents.SystemEventScheduler` whenever its
      dual-write shim runs (one event per key per scheduler fire).
      Counts toward `legacy` AND `router` separately, and increments
      `divergence_count` whenever the legacy and router booleans differ.

  ## Why two event sources

  The router-fired telemetry is the canonical "router did the work"
  signal — it sees fires from EVERY trigger kind (cron, event_topic,
  chat_pattern, webhook) so the monitor's totals are correct even after
  the dual-write shim is removed. The dual-write event is the
  per-event-pair divergence signal: the only place where we have the
  legacy outcome AND the router outcome side-by-side for the same
  scheduler fire. Counting both gives the operator the report they
  need to flip the cutover flag confidently.

  ## Report shape

      iex> Platform.Responsibilities.CutoverMonitor.report()
      %{
        as_of: ~U[2026-06-24 00:00:00Z],
        keys: %{
          "memory.daily_summary" => %{router: 1, legacy: 1, divergence_count: 0},
          "memory.dreaming" => %{router: 0, legacy: 1, divergence_count: 1}
        }
      }

  The `as_of` field is the UTC date the report covers (today by
  default). Counters reset at midnight UTC — the next fire after a
  date change wipes the prior day's totals. Operators looking for a
  7-day window run `mix responsibilities.cutover_report` once a day and
  diff the printouts; the monitor itself is intentionally a single-day
  rolling window so a long-lived process doesn't accumulate unbounded
  state.

  ## Test seam

  In tests the GenServer can be started with `:name` overrides; the
  default registered name is `__MODULE__` so the production singleton
  is reachable via `CutoverMonitor.report/0`.

  ## Configuration

      config :platform, :start_cutover_monitor, true

  Disabled in `config/test.exs` so each test spins up its own instance
  for isolation.
  """

  use GenServer

  require Logger

  @router_fired_event [:platform, :responsibility, :fired]
  @dual_write_event [:platform, :responsibilities, :dual_write]

  @tracked_keys [
    "memory.daily_summary",
    "memory.dreaming"
  ]

  # ── public API ────────────────────────────────────────────────────────────

  @doc """
  Start the monitor. Registers as `__MODULE__` unless `:name` is
  passed; tests pass per-case names to keep isolation.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return the per-key counter report for today.

  The map is keyed by the same canonical responsibility key strings
  the Router uses. Unknown keys (i.e. anyone outside `@tracked_keys`)
  are ignored so the report stays focused on the M8 cutover surface.
  """
  @spec report(GenServer.server()) :: %{
          as_of: Date.t(),
          keys: %{
            String.t() => %{
              router: non_neg_integer(),
              legacy: non_neg_integer(),
              divergence_count: non_neg_integer()
            }
          }
        }
  def report(server \\ __MODULE__), do: GenServer.call(server, :report)

  @doc "Return the list of responsibility keys this monitor tracks."
  @spec tracked_keys() :: [String.t()]
  def tracked_keys, do: @tracked_keys

  @doc false
  # Test helper — drop all counters back to zero.
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    router_handler_id = "platform-cutover-monitor-router-#{System.unique_integer([:positive])}"
    dual_handler_id = "platform-cutover-monitor-dual-#{System.unique_integer([:positive])}"

    attach_telemetry(router_handler_id, @router_fired_event, self())
    attach_telemetry(dual_handler_id, @dual_write_event, self())

    state = %{
      router_handler_id: router_handler_id,
      dual_handler_id: dual_handler_id,
      as_of: Date.utc_today(),
      counters: initial_counters()
    }

    Logger.info(
      "[CutoverMonitor] started tracking keys=#{inspect(@tracked_keys)} as_of=#{state.as_of}"
    )

    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    detach_telemetry(state.router_handler_id)
    detach_telemetry(state.dual_handler_id)
    :ok
  end

  @impl GenServer
  def handle_call(:report, _from, state) do
    state = roll_over_if_new_day(state)
    {:reply, %{as_of: state.as_of, keys: state.counters}, state}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | counters: initial_counters(), as_of: Date.utc_today()}}
  end

  @impl GenServer
  def handle_info({:telemetry_router_fired, metadata}, state) do
    key = key_from_metadata(metadata)

    if key in @tracked_keys do
      state = roll_over_if_new_day(state)
      counters = bump(state.counters, key, :router)
      {:noreply, %{state | counters: counters}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:telemetry_dual_write, metadata}, state) do
    key = key_from_metadata(metadata)

    if key in @tracked_keys do
      state = roll_over_if_new_day(state)

      legacy_ok? = Map.get(metadata, :legacy_ok?) || Map.get(metadata, "legacy_ok?") || false
      router_ok? = Map.get(metadata, :router_ok?) || Map.get(metadata, "router_ok?") || false

      counters =
        state.counters
        |> maybe_bump(key, :legacy, legacy_ok?)
        # Don't double-count the router on dual_write — the router fire
        # already emitted its own :fired event if it succeeded. The
        # dual_write event is for divergence tracking only.
        |> maybe_bump_divergence(key, legacy_ok?, router_ok?)

      {:noreply, %{state | counters: counters}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(_other, state), do: {:noreply, state}

  # ── telemetry attach/detach ───────────────────────────────────────────────

  defp attach_telemetry(handler_id, @router_fired_event, monitor_pid) do
    :telemetry.attach(
      handler_id,
      @router_fired_event,
      &__MODULE__.handle_router_fired_telemetry/4,
      %{monitor_pid: monitor_pid}
    )
  end

  defp attach_telemetry(handler_id, @dual_write_event, monitor_pid) do
    :telemetry.attach(
      handler_id,
      @dual_write_event,
      &__MODULE__.handle_dual_write_telemetry/4,
      %{monitor_pid: monitor_pid}
    )
  end

  defp detach_telemetry(handler_id) when is_binary(handler_id) do
    :telemetry.detach(handler_id)
  rescue
    _ -> :ok
  end

  @doc false
  # Telemetry callback for router-fired events. Forwards to the monitor
  # GenServer so all counter work runs on a single process.
  def handle_router_fired_telemetry(
        @router_fired_event,
        _measurements,
        metadata,
        %{monitor_pid: pid}
      )
      when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, {:telemetry_router_fired, metadata})
    end

    :ok
  rescue
    _ -> :ok
  end

  def handle_router_fired_telemetry(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  # Telemetry callback for dual-write events. Same forwarder pattern.
  def handle_dual_write_telemetry(
        @dual_write_event,
        _measurements,
        metadata,
        %{monitor_pid: pid}
      )
      when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, {:telemetry_dual_write, metadata})
    end

    :ok
  rescue
    _ -> :ok
  end

  def handle_dual_write_telemetry(_event, _measurements, _metadata, _config), do: :ok

  # ── internals ─────────────────────────────────────────────────────────────

  defp initial_counters do
    Map.new(@tracked_keys, fn key ->
      {key, %{router: 0, legacy: 0, divergence_count: 0}}
    end)
  end

  defp roll_over_if_new_day(%{as_of: %Date{} = as_of} = state) do
    today = Date.utc_today()

    if Date.compare(today, as_of) == :eq do
      state
    else
      Logger.info("[CutoverMonitor] rolling over counters as_of=#{as_of} → #{today}")
      %{state | as_of: today, counters: initial_counters()}
    end
  end

  defp bump(counters, key, field) do
    Map.update!(counters, key, fn entry ->
      Map.update!(entry, field, &(&1 + 1))
    end)
  end

  defp maybe_bump(counters, _key, _field, false), do: counters
  defp maybe_bump(counters, key, field, true), do: bump(counters, key, field)

  # Divergence: increment when EXACTLY ONE of legacy/router succeeded.
  # Both-success and both-failure are NOT divergence (they agreed).
  defp maybe_bump_divergence(counters, key, legacy_ok?, router_ok?)
       when legacy_ok? != router_ok? do
    bump(counters, key, :divergence_count)
  end

  defp maybe_bump_divergence(counters, _key, _legacy_ok?, _router_ok?), do: counters

  defp key_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, :key) || Map.get(metadata, "key")
  end

  defp key_from_metadata(_), do: nil
end

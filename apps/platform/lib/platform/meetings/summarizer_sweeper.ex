defmodule Platform.Meetings.SummarizerSweeper do
  @moduledoc """
  Periodic sweep for stalled meeting-summary router dispatches.

  When `Summarizer.run_summary/1` decides the router should own the
  summarize path (a Meeting Scribe holds `meetings.summarize`), the
  transcript row gets stamped with `router_dispatched_at` and the
  external-dispatch handler chain takes over. If the downstream agent
  never posts an output — dead runtime, crashed handler, network
  partition — the transcript is stuck in status `"processing"` forever
  and nobody notices.

  This sweeper closes that hole. Every `check_interval_ms` it walks
  `Meetings.list_stalled_router_dispatches(stall_window_ms)` and for
  each returned transcript:

    1. Logs a warning that the fallback is firing (with transcript id
       and how long it stalled for so operators can grep).
    2. Spawns a supervised task on `Platform.TaskSupervisor` (via
       `Task.Supervisor.async_nolink/2`, so the GenServer stays alive
       if the legacy body crashes) that drives
       `Summarizer.run_summary_legacy/3` directly — bypassing the
       router this time so the fallback never re-nominates a dead
       agent for the same job.
    3. Emits `[:platform, :meetings, :summarize_fallback_fired]`
       telemetry with `%{transcript_id, stalled_for_ms,
       previously_assigned_agent_slug}` so downstream dashboards and
       the M8 CutoverMonitor can distinguish fallback firings from
       first-time router firings.
    4. Once the async task completes, posts a system message into
       the meeting's chat space naming the previously-assigned agent
       and linking to Control Center → Roles (stage 5). If the
       legacy body itself crashed / raised / returned `{:error, _}`,
       the notice reads "Summary fallback also failed" instead.

  Task 019f2566 stages 2 (sweep body), 3 (assigned-agent metadata),
  5 (post-fallback notice into the meeting space), 6 (StallRegistry
  seam so follow-up runtimes can plug their own sweep callback into
  the same tick).

  ## Multi-runtime sweep (stage 6)

  Since stage 6 the `:tick` handler is a thin dispatcher: it walks
  `Platform.Responsibilities.StallRegistry.all/0` and invokes each
  registered `{module, function/0}` callback under
  `Platform.TaskSupervisor`. This module's own sweep is one of those
  callbacks — `sweep_meetings_summarize/0` is registered at boot from
  `Platform.Application`. Follow-up runtimes (e.g. the IntentClassify
  dispatcher, task `019f2452`) register their own `{mod, fun}` pair
  the same way, so this file doesn't grow a new branch every time a
  new stall-guard lands.

  ## Configuration

  Defaults are conservative — two-minute cadence, ten-minute stall
  window — so a healthy production system will basically never fire.

      config :platform, #{__MODULE__},
        check_interval_ms: :timer.minutes(2),
        stall_window_ms: :timer.minutes(10)

  Boot gated on `:start_summarizer_sweeper` (defaults to `true`; set
  to `false` in `config/test.exs` so DataCase-scoped tests start their
  own per-case instance).

  ## Test seam

  All `start_link/1` options are forwarded to `init/1`, so tests can
  pass `check_interval_ms: 100, stall_window_ms: 200` to make a real
  sweep exercisable in a couple of hundred milliseconds. `:name` is
  extracted from the opts and used as the registered name so tests
  can start multiple sweepers side-by-side without stepping on
  `__MODULE__`.
  """

  use GenServer

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.Summarizer
  alias Platform.Responsibilities.Handlers.MeetingSummarize
  alias Platform.Responsibilities.StallRegistry
  alias Platform.Roles

  @default_check_interval_ms :timer.minutes(2)
  @default_stall_window_ms :timer.minutes(10)

  @telemetry_event [:platform, :meetings, :summarize_fallback_fired]

  # ── public API ────────────────────────────────────────────────────────────

  @doc """
  Start the sweeper. Registers as `__MODULE__` unless `:name` is
  passed; tests pass per-case names to keep isolation.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Force a sweep to run now. Returns the list of pids spawned under
  `Platform.TaskSupervisor` for the stalled dispatches so callers
  (tests) can `Process.monitor/1` + `assert_receive {:DOWN, _, ...}`
  before letting the sandbox connection go.

  Since stage 5 the spawned tasks are `Task.async_nolink/2` handles —
  the sweeper GenServer monitors them itself and posts a follow-up
  system message into the meeting space when they complete. Tests
  that only want to know "did the sweep happen" should still monitor
  the pids; tests that want to see the follow-up notice should also
  wait a beat for `Meetings.post_fallback_notice/3` to land in Chat.
  """
  @spec sweep_now(GenServer.server()) :: {:ok, [pid()]}
  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep_now)

  @doc "Telemetry event emitted each time the fallback fires."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Zero-arity sweep entry point registered with
  `Platform.Responsibilities.StallRegistry` at boot (task 019f2566
  stage 6).

  Delegates to `sweep_now/1` on the default-name sweeper so inflight
  bookkeeping (needed by stage 5's post-fallback notice path) stays
  inside the GenServer. Safe to call from any process; returns `:ok`
  regardless of how many stalled dispatches were found.

  If the sweeper isn't running (test env with
  `:start_summarizer_sweeper false` and no per-case instance registered
  under `__MODULE__`), this is a silent no-op — tests spin up their own
  named instance and drive it directly via `sweep_now/1`.
  """
  @spec sweep_meetings_summarize() :: :ok
  def sweep_meetings_summarize do
    case GenServer.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        _ = sweep_now(__MODULE__)
        :ok
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    config = Application.get_env(:platform, __MODULE__, [])

    check_interval_ms =
      Keyword.get(opts, :check_interval_ms) ||
        Keyword.get(config, :check_interval_ms, @default_check_interval_ms)

    stall_window_ms =
      Keyword.get(opts, :stall_window_ms) ||
        Keyword.get(config, :stall_window_ms, @default_stall_window_ms)

    # Task 019f2566 stage 6 — tests pass their own per-case
    # StallRegistry name so the sweeper's `:tick` handler walks the
    # test's isolated callback set instead of the default singleton
    # (which is disabled in test env). Prod uses the default.
    stall_registry =
      Keyword.get(opts, :stall_registry) ||
        Keyword.get(config, :stall_registry, StallRegistry)

    state = %{
      check_interval_ms: check_interval_ms,
      stall_window_ms: stall_window_ms,
      stall_registry: stall_registry,
      # Track in-flight fallback tasks so `handle_info({ref, result}, ...)`
      # and `handle_info({:DOWN, ref, ...}, ...)` can look up the transcript
      # + assigned-agent context they need to compose the post-fallback
      # notice. Keyed by `Task.async_nolink/2`'s monitor ref.
      inflight: %{}
    }

    Logger.info(
      "[SummarizerSweeper] started check_interval_ms=#{check_interval_ms} stall_window_ms=#{stall_window_ms}"
    )

    schedule_tick(check_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:sweep_now, _from, state) do
    {new_state, pids} = sweep(state)
    {:reply, {:ok, pids}, new_state}
  end

  # Task 019f2566 stage 6 — tick body now walks StallRegistry so
  # follow-up runtimes (e.g. the IntentClassify dispatcher, task
  # 019f2452) can plug their own sweep callback into the same tick
  # cadence without editing this module. Each callback runs inside a
  # supervised task so one raising callback doesn't take the sweep or
  # its siblings down, and so any callback that itself calls back into
  # this GenServer (e.g. `sweep_meetings_summarize/0` → `sweep_now/1`)
  # doesn't deadlock on `handle_info(:tick, ...)`.
  @impl GenServer
  def handle_info(:tick, state) do
    case safe_registry_lookup(state.stall_registry) do
      {:ok, callbacks} -> Enum.each(callbacks, &spawn_sweep_callback/1)
      :error -> :ok
    end

    schedule_tick(state.check_interval_ms)
    {:noreply, state}
  end

  # Task 019f2566 stage 5 — legacy fallback completed (or crashed inside
  # `run_summary_legacy/3` so the return value is an exception tuple).
  # Either way, post the "summary fallback" notice into the meeting space
  # so the operator sees why the summary looks different than usual.
  @impl GenServer
  def handle_info({ref, result}, %{inflight: inflight} = state) when is_reference(ref) do
    case Map.pop(inflight, ref) do
      {nil, _} ->
        {:noreply, state}

      {ctx, remaining} ->
        # The Task's monitor is still up — demonitor + flush to prevent
        # a followup {:DOWN, ...} landing in the mailbox.
        Process.demonitor(ref, [:flush])
        post_completion_notice(ctx, result)
        {:noreply, %{state | inflight: remaining}}
    end
  end

  # If the async task crashed (raised, exited, killed by timeout) we still
  # want the meeting space to hear about it — post the "also failed"
  # notice so silence isn't the failure mode.
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{inflight: inflight} = state)
      when is_reference(ref) do
    case Map.pop(inflight, ref) do
      {nil, _} ->
        {:noreply, state}

      {ctx, remaining} ->
        Logger.error(
          "[SummarizerSweeper] fallback task crashed transcript_id=#{ctx.transcript_id} " <>
            "reason=#{inspect(reason)}"
        )

        post_completion_notice(ctx, {:error, {:task_crashed, reason}})
        {:noreply, %{state | inflight: remaining}}
    end
  end

  @impl GenServer
  def handle_info(_other, state), do: {:noreply, state}

  # ── internals ─────────────────────────────────────────────────────────────

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  # Look up the callback list from StallRegistry. Boot ordering,
  # test-env skip, and the odd hot-reload window can all leave the
  # registry name unregistered — treat those as "no callbacks this
  # tick" rather than blowing up the sweeper GenServer.
  defp safe_registry_lookup(server) do
    case GenServer.whereis(server) do
      nil -> :error
      _pid -> {:ok, StallRegistry.all(server)}
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # Task 019f2566 stage 6 — invoke a registered sweep callback in a
  # detached process so:
  #
  #   1. A raising callback logs + dies without killing the sweeper.
  #   2. A callback that calls back into the sweeper GenServer (e.g.
  #      `SummarizerSweeper.sweep_meetings_summarize/0` → `sweep_now/1`)
  #      doesn't deadlock the tick handler on a self-call.
  #
  # We use `Task.Supervisor.start_child` so the child is supervised —
  # crashed tasks are logged by the supervisor and won't leak.
  defp spawn_sweep_callback({mod, fun}) when is_atom(mod) and is_atom(fun) do
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      try do
        apply(mod, fun, [])
      rescue
        error ->
          Logger.error(
            "[SummarizerSweeper] sweep callback #{inspect(mod)}.#{fun}/0 raised: " <>
              Exception.message(error)
          )

          # Reraise so the supervised task exits abnormally — the
          # supervisor's own logging picks it up too, and it doesn't
          # take the sweeper GenServer with it.
          reraise error, __STACKTRACE__
      end
    end)

    :ok
  end

  defp sweep(%{stall_window_ms: stall_window_ms, inflight: inflight} = state) do
    {new_inflight, pids} =
      Meetings.list_stalled_router_dispatches(stall_window_ms)
      |> Enum.reduce({inflight, []}, fn transcript, {acc_inflight, acc_pids} ->
        case fire_fallback(transcript) do
          {:ok, ref, pid, ctx} -> {Map.put(acc_inflight, ref, ctx), [pid | acc_pids]}
          :error -> {acc_inflight, acc_pids}
        end
      end)

    {%{state | inflight: new_inflight}, Enum.reverse(pids)}
  rescue
    error ->
      # A misbehaving DB shouldn't take the sweeper out — log and
      # continue so the next tick gets another try.
      Logger.error(
        "[SummarizerSweeper] sweep raised — skipping this tick: " <> Exception.message(error)
      )

      {state, []}
  end

  defp fire_fallback(%{id: transcript_id, space_id: space_id, segments: segments} = transcript) do
    stalled_for_ms = stalled_for_ms(transcript)
    agent_slug = previously_assigned_agent_slug(transcript)

    Logger.warning(
      "[SummarizerSweeper] fallback firing transcript_id=#{transcript_id} " <>
        "agent=#{inspect(agent_slug)} " <>
        "stalled_for=#{div(stalled_for_ms, 1000)}s"
    )

    :telemetry.execute(
      @telemetry_event,
      %{stalled_for_ms: stalled_for_ms},
      %{
        transcript_id: transcript_id,
        stalled_for_ms: stalled_for_ms,
        previously_assigned_agent_slug: agent_slug
      }
    )

    # `async_nolink/2` is the shape we want: the GenServer gets both a
    # `{ref, result}` on happy completion and a `{:DOWN, ref, ...}` on
    # crash, but the task doesn't take the sweeper down with it. See
    # `handle_info/2` above for the two receive branches.
    try do
      task =
        Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
          Summarizer.run_summary_legacy(transcript_id, space_id, segments)
        end)

      ctx = %{
        transcript_id: transcript_id,
        space_id: space_id,
        previously_assigned_agent: agent_slug,
        stalled_for_ms: stalled_for_ms
      }

      {:ok, task.ref, task.pid, ctx}
    rescue
      error ->
        Logger.error(
          "[SummarizerSweeper] failed to start fallback task transcript_id=#{transcript_id}: " <>
            Exception.message(error)
        )

        :error
    end
  end

  # Compose + post the "summary fallback" or "summary fallback also
  # failed" system message into the meeting's chat space. Both branches
  # are best-effort — if the space is gone or `post_message` errors we
  # log and move on; the sweeper's telemetry is still the canonical
  # signal for dashboards.
  defp post_completion_notice(ctx, result) do
    if is_binary(ctx.space_id) and ctx.space_id != "" do
      mode =
        case result do
          :ok -> :completed
          {:ok, _} -> :completed
          _ -> :also_failed
        end

      opts = %{
        previously_assigned_agent: ctx.previously_assigned_agent,
        stalled_for_ms: ctx.stalled_for_ms,
        mode: mode
      }

      case Meetings.post_fallback_notice(ctx.space_id, ctx.transcript_id, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[SummarizerSweeper] post_fallback_notice failed transcript_id=#{ctx.transcript_id}: " <>
              inspect(reason)
          )

          :ok
      end
    else
      Logger.info(
        "[SummarizerSweeper] no space_id for transcript #{ctx.transcript_id}, skipping fallback notice"
      )

      :ok
    end
  rescue
    error ->
      Logger.error(
        "[SummarizerSweeper] post_completion_notice raised transcript_id=#{ctx.transcript_id}: " <>
          Exception.message(error)
      )

      :ok
  end

  defp stalled_for_ms(%{router_dispatched_at: %DateTime{} = dispatched_at}) do
    DateTime.diff(DateTime.utc_now(), dispatched_at, :millisecond)
  end

  defp stalled_for_ms(_), do: 0

  # Task 019f2566 stage 3 — on-demand slug lookup.
  #
  # We deliberately do NOT persist the assigned-agent slug on
  # `meeting_transcripts` (no schema column, no migration). Instead
  # we resolve the CURRENTLY-assigned agent for `meetings.summarize`
  # at sweep time. This is the right call because the fallback notice
  # targets the agent the operator reassigned to (if any) — that's who the
  # dashboard operator needs to poke, not the historical slug at the
  # time of the original dispatch.
  #
  # Errors and misconfiguration return `nil` so the telemetry
  # consumer just renders "unknown" — the sweeper's happy path is
  # still that the transcript is picked up by the legacy fallback.
  defp previously_assigned_agent_slug(_transcript) do
    case Roles.assignee_for(MeetingSummarize.key()) do
      %Agent{slug: slug} when is_binary(slug) -> slug
      _ -> nil
    end
  rescue
    _ -> nil
  end
end

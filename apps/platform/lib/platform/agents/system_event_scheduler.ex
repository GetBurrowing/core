defmodule Platform.Agents.SystemEventScheduler do
  @moduledoc """
  Periodic scheduler that fires the `historian` system event to a designated
  agent on an every-6h staggered cadence.

  V2 (ADR-0041 / T6) collapses the legacy `daily_summary` (23:00 UTC) and
  `dreaming` (03:00 UTC) events into a single `historian` event that fires
  at four anchor hours `[0, 6, 12, 18]` UTC. Per-workspace stagger is applied
  via `offset_minutes = :erlang.phash2(workspace_id, 360)` so an org with N
  workspaces gets a uniform distribution across each 6h window.

  Workspace fan-out is sourced from `Platform.Tasks.Projects.list_active_workspaces/0`
  which returns `[nil]` for V1 (org-scope only). Each `(workspace_id, anchor_hour)`
  pair is debounced independently, so a workspace fires 4× per day, once per
  anchor.

  Each system event can only be claimed by a single agent (one-agent-per-event).
  The scheduler posts a synthetic instruction message into a per-agent system
  space and dispatches via `AgentResponder`.

  ## Configuration

      config :platform, Platform.Agents.SystemEventScheduler,
        check_interval_ms: 60_000
  """

  use GenServer

  require Logger

  alias Platform.Agents.{Historian, HistorianDispatcher}
  alias Platform.Org.TenantsSummary
  alias Platform.Tasks.Projects

  # ── Defaults ─────────────────────────────────────────────────────────────────

  @default_check_interval_ms :timer.seconds(60)

  # Every-6h staggered cadence — UTC anchor hours. Per-workspace minute offset
  # is `:erlang.phash2(workspace_id, 360)`.
  @anchors [0, 6, 12, 18]

  # Stagger modulus — 360 minutes covers the 6h window between anchors.
  @stagger_modulus 360

  # Single canonical system event. The legacy `daily_summary` + `dreaming`
  # split is gone; the Historian role now bundles both behaviours under one
  # event name.
  @historian_event "historian"

  # 100k-token auto-trigger defaults (overridable via app env).
  #
  # `:historian_threshold_tokens` — when `Historian.pending_tokens(workspace_id)`
  # crosses this, the scheduler dispatches the historian out-of-anchor.
  # `:historian_debounce_ms` — minimum elapsed time since the workspace's last
  # historian run before a threshold-triggered dispatch is eligible again.
  @default_threshold_tokens 100_000
  @default_debounce_ms 60 * 60 * 1_000

  # Weekly TENANTS_SUMMARY.md heartbeat (ADR 0042 Stage 3).
  #
  # Fires every Sunday at `@tenants_summary_anchor_hour`:00 UTC and is
  # debounced by `@tenants_summary_debounce_ms` so re-fires within the same
  # week are no-ops even across scheduler restarts in dev.
  @tenants_summary_weekday 7
  @tenants_summary_anchor_hour 4
  @tenants_summary_debounce_ms 6 * 24 * 60 * 60 * 1_000

  # ── Public API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force-fire the historian event now (for testing/admin).

  Deliberately NOT the anchor path: this renders the un-windowed trailing-24h
  digest via `HistorianDispatcher.dispatch/3` and leaves the cursor and
  `last_run_at` untouched, so an ad-hoc fire always produces a message and
  never consumes backlog or shifts the debounce out from under the scheduled
  cadence. Use `run_anchor_check_now/1` to exercise the real anchor path.
  """
  @spec fire_now(String.t()) :: :ok | {:error, term()}
  def fire_now(event_type \\ @historian_event) do
    GenServer.call(__MODULE__, {:fire_now, event_type}, :timer.minutes(2))
  end

  @doc """
  Synchronously run the every-6h anchor check as of `now`.

  Fires every `(workspace_id, anchor_hour)` pair that is due at `now` and
  not already fired in its window — exactly what the periodic `:check`
  tick does for the anchor cadence, without the threshold sweep or the
  weekly TENANTS_SUMMARY heartbeat that ride on the same tick. Returns the
  `{workspace_id, anchor_hour}` pairs that fired on this call.

  `now` only decides which anchors are due; the dispatch itself slices
  windows up to the real `DateTime.utc_now/0`. Intended for tests and
  operator-triggered checks.
  """
  @spec run_anchor_check_now(DateTime.t()) :: [{binary() | nil, non_neg_integer()}]
  def run_anchor_check_now(%DateTime{} = now \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:run_anchor_check_now, now}, :timer.minutes(2))
  end

  @doc """
  Synchronously run the 100k-token threshold sweep for all active workspaces.

  Useful for tests and for an operator-triggered manual sweep. Returns a list
  of `{workspace_id, action}` tuples where `action` is `:fired`, `:debounced`,
  or `:under_threshold`.
  """
  @spec run_threshold_check_now() :: [{binary() | nil, :fired | :debounced | :under_threshold}]
  def run_threshold_check_now do
    GenServer.call(__MODULE__, :run_threshold_check_now, :timer.minutes(2))
  end

  @doc """
  Force a `TenantsSummary.recompute/1` run now. Bypasses the weekly anchor
  and debounce — intended for operator-triggered refreshes and tests.

  `opts` are passed straight through to `TenantsSummary.recompute/1`, so
  callers can pass a stubbed `:llm_fun` from a test context.
  """
  @spec recompute_tenants_summary_now(keyword()) ::
          {:ok, term()} | {:ok, :no_root} | {:error, term()}
  def recompute_tenants_summary_now(opts \\ []) do
    GenServer.call(__MODULE__, {:recompute_tenants_summary_now, opts}, :timer.minutes(2))
  end

  @doc """
  Pure predicate: should the weekly TENANTS_SUMMARY heartbeat fire right
  now? Returns `true` iff `now` is at or past the next-due anchor AND the
  debounce window since `last_run_at` has elapsed (or no prior run).

  Extracted so the cadence policy is unit-testable without a GenServer.
  """
  @spec should_fire_tenants_summary?(DateTime.t(), DateTime.t() | nil) :: boolean()
  @spec should_fire_tenants_summary?(
          DateTime.t(),
          DateTime.t() | nil,
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: boolean()
  def should_fire_tenants_summary?(
        now,
        last_run_at,
        weekday \\ @tenants_summary_weekday,
        anchor_hour \\ @tenants_summary_anchor_hour,
        debounce_ms \\ @tenants_summary_debounce_ms
      )

  def should_fire_tenants_summary?(%DateTime{} = now, nil, weekday, anchor_hour, _debounce_ms) do
    anchor_due?(now, weekday, anchor_hour)
  end

  def should_fire_tenants_summary?(
        %DateTime{} = now,
        %DateTime{} = last_run_at,
        weekday,
        anchor_hour,
        debounce_ms
      ) do
    elapsed_ms = DateTime.diff(now, last_run_at, :millisecond)
    elapsed_ms >= debounce_ms and anchor_due?(now, weekday, anchor_hour)
  end

  defp anchor_due?(%DateTime{} = now, weekday, anchor_hour) do
    date = DateTime.to_date(now)
    Date.day_of_week(date) == weekday and now.hour >= anchor_hour
  end

  @doc """
  Pure predicate: should a threshold-triggered dispatch fire right now?

  Returns `true` iff `pending_tokens` is at or above `threshold_tokens` AND
  either no prior run has been stamped OR the time since `last_run_at` is at
  or above the debounce window.

  Extracted as a pure function so the debounce policy is unit-testable
  without a database round-trip.
  """
  @spec should_fire_threshold?(
          non_neg_integer(),
          DateTime.t() | nil,
          DateTime.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: boolean()
  def should_fire_threshold?(
        pending_tokens,
        last_run_at,
        now,
        threshold_tokens \\ @default_threshold_tokens,
        debounce_ms \\ @default_debounce_ms
      )

  def should_fire_threshold?(pending_tokens, _last_run_at, _now, threshold_tokens, _debounce_ms)
      when pending_tokens < threshold_tokens,
      do: false

  def should_fire_threshold?(_pending_tokens, nil, _now, _threshold_tokens, _debounce_ms),
    do: true

  def should_fire_threshold?(
        _pending_tokens,
        %DateTime{} = last_run_at,
        %DateTime{} = now,
        _threshold_tokens,
        debounce_ms
      ) do
    elapsed_ms = DateTime.diff(now, last_run_at, :millisecond)
    elapsed_ms >= debounce_ms
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    config = Application.get_env(:platform, __MODULE__, [])

    state = %{
      check_interval_ms:
        Keyword.get(
          opts,
          :check_interval_ms,
          Keyword.get(config, :check_interval_ms, @default_check_interval_ms)
        ),
      anchors: Keyword.get(opts, :anchors, Keyword.get(config, :anchors, @anchors)),
      # Map of {workspace_id, anchor_hour} => %DateTime{} of last fire.
      last_fired: %{},
      # %DateTime{} of last TENANTS_SUMMARY recompute; `nil` until the
      # first weekly heartbeat fires.
      tenants_summary_last_run_at: nil
    }

    schedule_check(state)

    Logger.info(
      "[SystemEventScheduler] started (interval=#{state.check_interval_ms}ms, anchors=#{inspect(state.anchors)})"
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    now = DateTime.utc_now()
    new_last_fired = check_and_fire(now, state)
    _ = run_threshold_sweep(now)
    new_tenants_last = maybe_fire_tenants_summary(now, state.tenants_summary_last_run_at)
    schedule_check(state)

    {:noreply,
     %{
       state
       | last_fired: new_last_fired,
         tenants_summary_last_run_at: new_tenants_last
     }}
  end

  @impl GenServer
  def handle_call({:fire_now, event_type}, _from, state) do
    result = dispatch_event(event_type)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:run_anchor_check_now, now}, _from, state) do
    new_last_fired = check_and_fire(now, state)

    fired =
      for {key, fired_at} <- new_last_fired,
          Map.get(state.last_fired, key) != fired_at,
          do: key

    {:reply, fired, %{state | last_fired: new_last_fired}}
  end

  @impl GenServer
  def handle_call(:run_threshold_check_now, _from, state) do
    results = run_threshold_sweep(DateTime.utc_now())
    {:reply, results, state}
  end

  @impl GenServer
  def handle_call({:recompute_tenants_summary_now, opts}, _from, state) do
    result = run_tenants_summary(opts)

    new_state =
      case result do
        {:ok, _} -> %{state | tenants_summary_last_run_at: DateTime.utc_now()}
        _ -> state
      end

    {:reply, result, new_state}
  end

  # ── Scheduling ───────────────────────────────────────────────────────────────

  defp schedule_check(%{check_interval_ms: ms}) do
    Process.send_after(self(), :check, ms)
  end

  @doc """
  Return the soonest `(anchor_hour, offset_minute)` fire time strictly in the
  future for the given workspace.

  The offset is `:erlang.phash2(workspace_id, 360)` minutes added to each
  anchor hour. The function searches the next 48h horizon (today's anchors
  + tomorrow's) and picks the earliest target strictly greater than `now`.
  """
  @spec next_fire_time(DateTime.t(), binary() | nil, [non_neg_integer()]) :: DateTime.t()
  def next_fire_time(%DateTime{} = now, workspace_id, anchors) when is_list(anchors) do
    offset_minutes = offset_for(workspace_id)

    candidates =
      for day_offset <- 0..1,
          hour <- anchors do
        base = %{now | hour: hour, minute: 0, second: 0, microsecond: {0, 6}}

        base
        |> DateTime.add(day_offset * 86_400, :second)
        |> DateTime.add(offset_minutes * 60, :second)
      end

    candidates
    |> Enum.filter(fn dt -> DateTime.compare(now, dt) == :lt end)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond))
  end

  @doc """
  Per-workspace minute offset within an anchor window.

  V1 deterministic phash so adjacent UUIDs land at different minutes; a `nil`
  workspace_id (org-scope V1 fan-out) hashes to a stable value too.
  """
  @spec offset_for(binary() | nil) :: non_neg_integer()
  def offset_for(workspace_id), do: :erlang.phash2(workspace_id, @stagger_modulus)

  defp check_and_fire(now, state) do
    workspaces = Projects.list_active_workspaces()

    Enum.reduce(workspaces, state.last_fired, fn workspace_id, last_fired ->
      Enum.reduce(state.anchors, last_fired, fn anchor_hour, lf ->
        if anchor_due?(now, workspace_id, anchor_hour, lf) do
          fire_anchor(workspace_id, anchor_hour)
          Map.put(lf, {workspace_id, anchor_hour}, now)
        else
          lf
        end
      end)
    end)
  end

  # The every-6h anchor fire. Mirrors `fire_threshold/2`: stamp
  # `last_run_at` BEFORE dispatch, then go through
  # `HistorianDispatcher.dispatch_windowed/4` so each dispatched window
  # advances its corpus cursor and the next anchor only sees activity since
  # this one.
  #
  # This used to call `dispatch_event/1` — the un-windowed path that renders
  # a fixed trailing-24h digest and touches no cursor. With anchors 6h apart
  # every pass re-sent ~18h of the previous pass's activity, and because the
  # anchor never stamped `last_run_at` the threshold debounce could not see
  # anchor passes either (prod had zero `org_historian_cursors` rows after
  # weeks of 4x/day passes). Task 019f4f55 windowed only the threshold path, to keep
  # its change set off the anchor path; nothing documents the anchor as
  # deliberately un-windowed, and both templates promise the cursor advances
  # "via `Historian.mark_run_started/1` in the dispatch pipeline".
  #
  # A pass with nothing new since the cursor dispatches nothing (the
  # dispatcher emits `:no_op_pass` instead of posting an empty digest).
  defp fire_anchor(workspace_id, anchor_hour) do
    pending_tokens = safe_pending_tokens(workspace_id)
    :ok = mark_run_started_safe(workspace_id)

    Logger.info(
      "[SystemEventScheduler] firing historian event " <>
        "workspace=#{inspect(workspace_id)} anchor=#{anchor_hour} pending=#{pending_tokens}"
    )

    metadata = %{
      trigger: "anchor",
      anchor_hour: anchor_hour,
      pending_tokens: pending_tokens,
      workspace_id: workspace_id
    }

    case HistorianDispatcher.dispatch_windowed(
           @historian_event,
           template_slug_for(@historian_event),
           metadata,
           workspace_id
         ) do
      {:ok, %{dispatched: dispatched, remaining: remaining}} ->
        if remaining > 0 do
          Logger.info(
            "[SystemEventScheduler] anchor pass capped " <>
              "workspace=#{inspect(workspace_id)} anchor=#{anchor_hour} " <>
              "dispatched=#{dispatched} remaining=#{remaining}"
          )
        end

        :ok

      {:error, reason} ->
        Logger.error(
          "[SystemEventScheduler] windowed anchor dispatch failed " <>
            "workspace=#{inspect(workspace_id)} anchor=#{anchor_hour}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # An anchor is "due" iff `now` is at or past today's `anchor_hour:offset_minute`
  # AND we haven't already fired within the last anchor window (6h) for that
  # `(workspace_id, anchor_hour)` pair.
  defp anchor_due?(now, workspace_id, anchor_hour, last_fired) do
    offset_minutes = offset_for(workspace_id)

    base = %{now | hour: anchor_hour, minute: 0, second: 0, microsecond: {0, 6}}
    target_today = DateTime.add(base, offset_minutes * 60, :second)

    last = Map.get(last_fired, {workspace_id, anchor_hour})

    DateTime.compare(now, target_today) != :lt and
      not recently_fired?(workspace_id, anchor_hour, last)
  end

  @doc """
  True if the given `(workspace_id, anchor_hour)` pair was fired within the
  same 6h anchor window as `now` (default: `DateTime.utc_now/0`).

  Replaces the legacy `fired_today?/2` — keyed per-anchor so a workspace can
  fire 4× per day (once per anchor) but never twice in the same window.
  """
  @spec recently_fired?(binary() | nil, non_neg_integer(), DateTime.t() | nil) :: boolean()
  @spec recently_fired?(binary() | nil, non_neg_integer(), DateTime.t() | nil, DateTime.t()) ::
          boolean()
  def recently_fired?(workspace_id, anchor_hour, last_fired, now \\ DateTime.utc_now())

  def recently_fired?(_workspace_id, _anchor_hour, nil, _now), do: false

  def recently_fired?(_workspace_id, _anchor_hour, %DateTime{} = last, %DateTime{} = now) do
    # Anchors are 6h apart. Once a window has elapsed (>6h) the same anchor
    # next day is eligible again; within the window we stay debounced.
    DateTime.diff(now, last, :second) < 6 * 3_600
  end

  # ── Threshold sweep (100k-token auto-trigger) ───────────────────────────────

  defp run_threshold_sweep(%DateTime{} = now) do
    threshold = threshold_tokens()
    debounce = debounce_ms()

    Projects.list_active_workspaces()
    |> Enum.map(fn workspace_id ->
      action = evaluate_and_maybe_fire(workspace_id, now, threshold, debounce)
      {workspace_id, action}
    end)
  end

  defp evaluate_and_maybe_fire(workspace_id, now, threshold, debounce) do
    pending = safe_pending_tokens(workspace_id)
    last_run = safe_last_run_at(workspace_id)

    cond do
      pending < threshold ->
        :under_threshold

      should_fire_threshold?(pending, last_run, now, threshold, debounce) ->
        fire_threshold(workspace_id, pending)
        :fired

      true ->
        emit_telemetry(:threshold_debounced, %{pending_tokens: pending}, %{
          workspace_id: workspace_id,
          last_run_at: last_run
        })

        Logger.debug(
          "[SystemEventScheduler] historian threshold met but debounced " <>
            "workspace=#{inspect(workspace_id)} pending=#{pending} last_run=#{inspect(last_run)}"
        )

        :debounced
    end
  end

  # Stamp `last_run_at` BEFORE dispatch so a slow LLM reply can't permit a
  # second tick to re-fire while the first run is in flight.
  #
  # Task 019f4f55 stage 3: the terminal `dispatch_event/3` call became a
  # `HistorianDispatcher.dispatch_windowed/4` call so the sweep emits one
  # digest per bounded window (up to `historian_max_windows_per_pass`)
  # and per-window telemetry surfaces the cap-hit + remaining backlog
  # for the next tick. `mark_run_started_safe/1` still runs BEFORE the
  # dispatch — the debounce contract is intact.
  defp fire_threshold(workspace_id, pending_tokens) do
    :ok = mark_run_started_safe(workspace_id)

    emit_telemetry(:threshold_fired, %{pending_tokens: pending_tokens}, %{
      workspace_id: workspace_id
    })

    Logger.info(
      "[SystemEventScheduler] firing historian threshold trigger " <>
        "workspace=#{inspect(workspace_id)} pending=#{pending_tokens}"
    )

    metadata = %{
      trigger: "threshold",
      pending_tokens: pending_tokens,
      workspace_id: workspace_id
    }

    case HistorianDispatcher.dispatch_windowed(
           @historian_event,
           "historian.threshold",
           metadata,
           workspace_id
         ) do
      {:ok, %{dispatched: dispatched, remaining: remaining}} ->
        emit_telemetry(
          :threshold_windows_dispatched,
          %{dispatched: dispatched, remaining: remaining},
          %{workspace_id: workspace_id}
        )

        if remaining > 0 do
          emit_telemetry(
            :threshold_sweep_capped,
            %{remaining: remaining},
            %{workspace_id: workspace_id}
          )

          Logger.info(
            "[SystemEventScheduler] threshold sweep capped " <>
              "workspace=#{inspect(workspace_id)} dispatched=#{dispatched} remaining=#{remaining}"
          )
        end

        :ok

      {:error, reason} ->
        Logger.error(
          "[SystemEventScheduler] windowed threshold dispatch failed " <>
            "workspace=#{inspect(workspace_id)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp safe_pending_tokens(workspace_id) do
    Historian.pending_tokens(workspace_id)
  rescue
    error ->
      Logger.warning(
        "[SystemEventScheduler] Historian.pending_tokens/1 raised " <>
          "workspace=#{inspect(workspace_id)}: #{Exception.message(error)}"
      )

      0
  end

  defp safe_last_run_at(workspace_id) do
    Historian.last_run_at(workspace_id)
  rescue
    error ->
      Logger.warning(
        "[SystemEventScheduler] Historian.last_run_at/1 raised " <>
          "workspace=#{inspect(workspace_id)}: #{Exception.message(error)}"
      )

      nil
  end

  defp mark_run_started_safe(workspace_id) do
    Historian.mark_run_started(workspace_id)
  rescue
    error ->
      Logger.warning(
        "[SystemEventScheduler] Historian.mark_run_started/1 raised " <>
          "workspace=#{inspect(workspace_id)}: #{Exception.message(error)}"
      )

      :ok
  end

  # ── Weekly TENANTS_SUMMARY heartbeat (ADR 0042 Stage 3) ────────────────

  defp maybe_fire_tenants_summary(now, last_run_at) do
    if should_fire_tenants_summary?(now, last_run_at) do
      Logger.info("[SystemEventScheduler] firing weekly TENANTS_SUMMARY recompute")

      case run_tenants_summary([]) do
        {:ok, _} -> now
        _ -> last_run_at
      end
    else
      last_run_at
    end
  end

  defp run_tenants_summary(opts) do
    TenantsSummary.recompute(opts)
  rescue
    error ->
      Logger.error(
        "[SystemEventScheduler] TenantsSummary.recompute/1 raised: " <>
          Exception.message(error)
      )

      {:error, {:raised, Exception.message(error)}}
  end

  defp threshold_tokens do
    Application.get_env(:platform, :historian_threshold_tokens, @default_threshold_tokens)
  end

  defp debounce_ms do
    Application.get_env(:platform, :historian_debounce_ms, @default_debounce_ms)
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute(
      [:platform, :agents, :historian_scheduler, event],
      measurements,
      metadata
    )
  end

  # ── Dispatch ─────────────────────────────────────────────────────────────────
  #
  # The full dispatch pipeline (agent lookup, runtime check, system space +
  # participant resolution, prompt render, AgentResponder fan-out) lives
  # in `Platform.Agents.HistorianDispatcher` so the scheduler and the
  # meeting-ended handler share one implementation. This module only picks
  # the right (template_slug, metadata) pair for each fire path.

  defp dispatch_event(event_type) do
    dispatch_event(event_type, template_slug_for(event_type), %{})
  end

  defp dispatch_event(event_type, template_slug, extra_metadata)
       when is_binary(template_slug) and is_map(extra_metadata) do
    normalized_event = normalize_event(event_type)
    HistorianDispatcher.dispatch(normalized_event, template_slug, extra_metadata)
  end

  # Defensive: legacy callers passing `"daily_summary"` are remapped to
  # the canonical `"historian"` event. Logged so we can spot stragglers
  # post-rollup. `"dreaming"` was deleted in task 019f70e9 stage 6 —
  # the memory.dreaming responsibility now owns its own cron trigger
  # (03:00 America/Chicago) via `Platform.Responsibilities.Router`, so
  # a stale caller passing `"dreaming"` here falls through to the
  # `normalize_event/1` catchall and logs "unknown event" (which is
  # correct — the scheduler no longer owns that firing).
  defp normalize_event("daily_summary") do
    Logger.warning(
      "[SystemEventScheduler] legacy event \"daily_summary\" received — " <>
        "routing to historian (drop call site after T6 rollup)"
    )

    @historian_event
  end

  defp normalize_event(@historian_event), do: @historian_event

  defp normalize_event(other) do
    Logger.warning("[SystemEventScheduler] unknown event #{inspect(other)} — passing through")
    other
  end

  defp template_slug_for(@historian_event), do: "historian.scheduled"
  # Legacy mapping — drop after rollup confirms no straggler call sites.
  defp template_slug_for("daily_summary"), do: "historian.scheduled"
  defp template_slug_for(_), do: "historian.scheduled"
end

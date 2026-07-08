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

  # ── Weekly events (ADR-0044 stage 5) ──────────────────────────────────
  #
  # Map keyed by event name → `{day_of_week, hour_of_day}` in UTC. Day
  # of week uses ISO 8601 numbering: 1 = Monday, 7 = Sunday (matches
  # `Date.day_of_week/1`). Kept SEPARATE from the historian anchor map
  # because the daily historian path is load-bearing for org memory —
  # weekly events are per-key opt-in behind a runtime flag and must not
  # share state with the anchor cache.
  #
  # Each weekly event carries an associated opt-in flag key. When the
  # flag is `false` (default), the scheduler's `check_and_fire_weekly/2`
  # skips the event even if its day/hour is due. Dispatch is delegated
  # to `Platform.Responsibilities.fire/2` — the Router-level cron
  # trigger for the same key ALSO fires it (belt-and-braces); the
  # handler is idempotent at the flag-gate.
  @default_weekly_events %{
    "architecture_cron_sweep" => {1, 4}
  }

  # Per-event opt-in flag key. Extracted so tests can stub without
  # reaching into `Application.get_env`.
  @weekly_event_flag_keys %{
    "architecture_cron_sweep" => :enable_architect_cron_sweep
  }

  # Responsibility key each weekly event dispatches to.
  @weekly_event_responsibility_keys %{
    "architecture_cron_sweep" => "architecture.cron_sweep"
  }

  # Weekly debounce window — one week minus a safety margin. Prevents
  # a scheduler restart on Monday 04:15 from re-firing Monday 04:00's
  # event.
  @weekly_debounce_ms 6 * 24 * 60 * 60 * 1_000

  # ── Public API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force-fire the historian event now (for testing/admin)."
  @spec fire_now(String.t()) :: :ok | {:error, term()}
  def fire_now(event_type \\ @historian_event) do
    GenServer.call(__MODULE__, {:fire_now, event_type}, :timer.minutes(2))
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

  @doc """
  Default weekly-events map. Public so tests can lock the shipped set
  without spinning up the GenServer.

  Keys are event names (strings); values are `{day_of_week, hour}` in
  UTC where day_of_week matches `Date.day_of_week/1` (1 = Mon, 7 = Sun).
  """
  @spec default_weekly_events() :: %{String.t() => {1..7, 0..23}}
  def default_weekly_events, do: @default_weekly_events

  @doc """
  Opt-in flag key for the given weekly event. Returns `nil` for unknown
  events. Public so tests can toggle the flag by key rather than magic
  constant.
  """
  @spec weekly_event_flag_key(String.t()) :: atom() | nil
  def weekly_event_flag_key(event_name) when is_binary(event_name),
    do: Map.get(@weekly_event_flag_keys, event_name)

  @doc """
  True when the weekly event's opt-in flag is set. Unknown events
  return `false` — the safe default is "do not fire".
  """
  @spec weekly_event_enabled?(String.t()) :: boolean()
  def weekly_event_enabled?(event_name) when is_binary(event_name) do
    case Map.get(@weekly_event_flag_keys, event_name) do
      nil -> false
      key -> Application.get_env(:platform, key, false) == true
    end
  end

  @doc """
  Next weekly fire time strictly in the future for `(weekday, hour)`.
  Handles the wrap case where today is the target weekday but the hour
  has already passed (returns the following week's slot).

  Weekday follows `Date.day_of_week/1`: 1 = Monday, 7 = Sunday.
  """
  @spec next_weekly_fire_time(DateTime.t(), 1..7, 0..23) :: DateTime.t()
  def next_weekly_fire_time(%DateTime{} = now, weekday, hour)
      when weekday in 1..7 and hour in 0..23 do
    today_weekday = now |> DateTime.to_date() |> Date.day_of_week()

    days_ahead =
      cond do
        # Same weekday, target hour still ahead → today.
        today_weekday == weekday and now.hour < hour -> 0
        # Same weekday but hour already passed → next week.
        today_weekday == weekday -> 7
        # Future weekday this ISO week.
        weekday > today_weekday -> weekday - today_weekday
        # Weekday already passed this week → next week.
        true -> 7 - today_weekday + weekday
      end

    now
    |> DateTime.add(days_ahead * 86_400, :second)
    |> Map.merge(%{hour: hour, minute: 0, second: 0, microsecond: {0, 6}})
  end

  @doc """
  True if the weekly event's `(weekday, hour)` is due right now AND we
  haven't already fired within the debounce window.

  `last_fired` is `nil` for events that never fired.
  """
  @spec weekly_event_due?(DateTime.t(), {1..7, 0..23}, DateTime.t() | nil) :: boolean()
  def weekly_event_due?(now, day_hour, last_fired, debounce_ms \\ @weekly_debounce_ms)

  def weekly_event_due?(%DateTime{} = now, {weekday, hour}, nil, _debounce_ms) do
    weekly_anchor_due?(now, weekday, hour)
  end

  def weekly_event_due?(%DateTime{} = now, {weekday, hour}, %DateTime{} = last, debounce_ms) do
    elapsed_ms = DateTime.diff(now, last, :millisecond)
    elapsed_ms >= debounce_ms and weekly_anchor_due?(now, weekday, hour)
  end

  defp weekly_anchor_due?(%DateTime{} = now, weekday, hour) do
    date = DateTime.to_date(now)
    Date.day_of_week(date) == weekday and now.hour >= hour
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
      tenants_summary_last_run_at: nil,
      # Map of event_name => %DateTime{} of last weekly fire. Only
      # populated when a weekly event actually fires — an event whose
      # flag is off never enters this map.
      weekly_last_fired: %{}
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
    new_weekly_last = check_and_fire_weekly(now, state.weekly_last_fired)
    schedule_check(state)

    {:noreply,
     %{
       state
       | last_fired: new_last_fired,
         tenants_summary_last_run_at: new_tenants_last,
         weekly_last_fired: new_weekly_last
     }}
  end

  @impl GenServer
  def handle_call({:fire_now, event_type}, _from, state) do
    result = dispatch_event(event_type)
    {:reply, result, state}
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
          Logger.info(
            "[SystemEventScheduler] firing historian event " <>
              "workspace=#{inspect(workspace_id)} anchor=#{anchor_hour}"
          )

          dispatch_event(@historian_event)
          Map.put(lf, {workspace_id, anchor_hour}, now)
        else
          lf
        end
      end)
    end)
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

    dispatch_event(@historian_event, "historian.threshold", metadata)
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

  # ── Weekly events (ADR-0044 stage 5) ─────────────────────────────────
  #
  # Walk `@default_weekly_events`, skipping any whose opt-in flag is
  # off. For each remaining event, check `weekly_event_due?/4` against
  # `last_fired[event_name]`; when due, delegate dispatch to
  # `Platform.Responsibilities.fire/2` for the mapped key. Failures are
  # swallowed with a warning — the router itself is `try/rescue`-wrapped,
  # but the belt-and-braces guard here keeps a router-shape change from
  # crashing the scheduler tick.

  defp check_and_fire_weekly(%DateTime{} = now, weekly_last_fired) do
    Enum.reduce(@default_weekly_events, weekly_last_fired, fn {event_name, day_hour}, acc ->
      cond do
        not weekly_event_enabled?(event_name) ->
          acc

        weekly_event_due?(now, day_hour, Map.get(acc, event_name)) ->
          fire_weekly(event_name, day_hour, now)
          Map.put(acc, event_name, now)

        true ->
          acc
      end
    end)
  end

  defp fire_weekly(event_name, {weekday, hour}, %DateTime{} = now) do
    responsibility_key = Map.get(@weekly_event_responsibility_keys, event_name)

    Logger.info(
      "[SystemEventScheduler] firing weekly event=#{event_name} " <>
        "responsibility=#{inspect(responsibility_key)} weekday=#{weekday} hour=#{hour}"
    )

    if is_binary(responsibility_key) do
      dispatch_weekly_responsibility(responsibility_key, event_name, now)
    end

    :ok
  end

  defp dispatch_weekly_responsibility(responsibility_key, event_name, now) do
    if Code.ensure_loaded?(Platform.Responsibilities) and
         function_exported?(Platform.Responsibilities, :fire, 2) do
      Platform.Responsibilities.fire(responsibility_key, %{
        kind: :cron,
        source: :system_event_scheduler_weekly,
        event_name: event_name,
        fired_at: now
      })
    else
      Logger.debug(
        "[SystemEventScheduler] Responsibilities.fire/2 unavailable — skipping weekly " <>
          "event=#{event_name}"
      )

      :ok
    end
  rescue
    error ->
      Logger.warning(
        "[SystemEventScheduler] weekly dispatch raised event=#{event_name} " <>
          "error=#{Exception.message(error)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[SystemEventScheduler] weekly dispatch exited event=#{event_name} reason=#{inspect(reason)}"
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
    legacy_result = HistorianDispatcher.dispatch(normalized_event, template_slug, extra_metadata)

    maybe_dual_write(normalized_event, extra_metadata, legacy_result)

    legacy_result
  end

  # ── Dual-write shim (ADR-0041 M8 stage 2) ───────────────────────────
  #
  # When `:responsibility_router_enabled` is `true`, every legacy
  # historian dispatch also fans out to the M6 responsibility router for
  # `memory.daily_summary` + `memory.dreaming`. The router's `fire/2`
  # looks each key up by canonical string, walks the assignee, and
  # either dispatches to the assigned agent OR no-ops (unfilled
  # responsibility). Logged with the `[dual_write]` tag so a cutover
  # diff job can grep both paths' outcomes.
  #
  # When the flag is `false` (default in `config/config.exs`), this is
  # a no-op — legacy is the only writer. We never block the legacy
  # return value on router failure; the legacy path is the source of
  # truth until the cutover follow-up deletes this scheduler.

  defp maybe_dual_write(normalized_event, extra_metadata, legacy_result) do
    if dual_write_enabled?() do
      do_dual_write(normalized_event, extra_metadata, legacy_result)
    else
      :ok
    end
  rescue
    error ->
      Logger.warning(
        "[SystemEventScheduler] [dual_write] shim raised: #{Exception.message(error)} — " <>
          "legacy path unaffected"
      )

      :ok
  end

  defp dual_write_enabled? do
    Application.get_env(:platform, :responsibility_router_enabled, false)
  end

  defp do_dual_write(@historian_event, extra_metadata, legacy_result) do
    workspace_id =
      Map.get(extra_metadata, :workspace_id) || Map.get(extra_metadata, "workspace_id")

    trigger_meta = %{
      kind: :cron,
      workspace_id: workspace_id,
      date: Date.utc_today(),
      fired_at: DateTime.utc_now(),
      source: :system_event_scheduler_dual_write
    }

    Enum.each(dual_write_keys(), fn key ->
      router_result = safe_router_fire(key, trigger_meta)
      legacy_summary = summarise_result(legacy_result)
      router_summary = summarise_result(router_result)

      Logger.info(
        "[SystemEventScheduler] [dual_write] key=#{key} " <>
          "legacy=#{inspect(legacy_summary)} " <>
          "router=#{inspect(router_summary)} " <>
          "workspace=#{inspect(workspace_id)}"
      )

      emit_dual_write_telemetry(key, legacy_summary, router_summary, workspace_id)
    end)
  end

  # M8 stage 6 (ADR-0041): the CutoverMonitor subscribes to this event
  # to maintain per-day per-key counters of router/legacy/divergence
  # outcomes. Kept separate from the per-key info log so log scraping
  # isn't the cutover signal — the monitor counts structured events.
  defp emit_dual_write_telemetry(key, legacy_summary, router_summary, workspace_id) do
    :telemetry.execute(
      [:platform, :responsibilities, :dual_write],
      %{system_time: System.system_time()},
      %{
        key: key,
        legacy_result: legacy_summary,
        router_result: router_summary,
        legacy_ok?: result_ok?(legacy_summary),
        router_ok?: result_ok?(router_summary),
        workspace_id: workspace_id
      }
    )
  rescue
    _ -> :ok
  end

  defp result_ok?(:ok), do: true
  defp result_ok?({:ok, _}), do: true
  defp result_ok?(_), do: false

  defp do_dual_write(_other_event, _extra_metadata, _legacy_result), do: :ok

  defp dual_write_keys do
    [
      Platform.Responsibilities.Handlers.DailySummary.key(),
      Platform.Responsibilities.Handlers.Dreaming.key()
    ]
  end

  defp safe_router_fire(key, trigger_meta) do
    if Code.ensure_loaded?(Platform.Responsibilities.Router) and
         function_exported?(Platform.Responsibilities.Router, :fire, 2) do
      Platform.Responsibilities.Router.fire(key, trigger_meta)
    else
      {:error, :router_not_loaded}
    end
  rescue
    error -> {:error, {:fire_raised, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:fire_exited, reason}}
  end

  defp summarise_result(:ok), do: :ok
  defp summarise_result({:ok, _}), do: :ok
  defp summarise_result({:error, reason}), do: {:error, reason}
  defp summarise_result(other), do: other

  # Defensive: legacy callers passing `"daily_summary"` or `"dreaming"` are
  # remapped to the canonical `"historian"` event. Logged so we can spot
  # stragglers post-rollup.
  defp normalize_event(legacy) when legacy in ["daily_summary", "dreaming"] do
    Logger.warning(
      "[SystemEventScheduler] legacy event #{inspect(legacy)} received — " <>
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
  defp template_slug_for("dreaming"), do: "historian.scheduled"
  defp template_slug_for(_), do: "historian.scheduled"
end

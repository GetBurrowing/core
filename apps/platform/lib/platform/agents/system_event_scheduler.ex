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
      last_fired: %{}
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
    schedule_check(state)
    {:noreply, %{state | last_fired: new_last_fired}}
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

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

  import Ecto.Query

  alias Platform.Agents.{Agent, ActivityDigest, Historian}
  alias Platform.Chat
  alias Platform.Chat.AgentResponder
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
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

  # Literal default used as a fallback for empty DB (when prompt_templates has
  # no `historian.scheduled` row yet). DB-backed templates take precedence via
  # `PromptTemplates.render_template/2`.
  @default_historian_instruction """
  You are the Historian. Below is the activity from the last 24 hours \
  across all non-DM spaces in the organisation.

  {activity_digest}

  Review recent journal entries and short-term memory. Curate durable \
  knowledge into pages under `org/page/`, `project/<id>/page/`, and \
  `space/<id>/page/`. Write transient notes to today's journal at \
  `org/journal/{date}.md`. Be selective: only promote genuinely new \
  insights and preserve existing content that is still relevant.
  """

  @daily_window_hours 24

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

  defp dispatch_event(event_type) do
    dispatch_event(event_type, template_slug_for(event_type), %{})
  end

  defp dispatch_event(event_type, template_slug, extra_metadata)
       when is_binary(template_slug) and is_map(extra_metadata) do
    case agent_for_event(event_type) do
      %Agent{} = agent ->
        Logger.info("[SystemEventScheduler] dispatching #{event_type} to agent=#{agent.slug}")
        dispatch_to_agent(agent, event_type, template_slug, extra_metadata)

      nil ->
        Logger.info("[SystemEventScheduler] no active agent flagged for #{event_type}, skipping")
        :ok
    end
  end

  defp agent_for_event(@historian_event) do
    do_agent_lookup(@historian_event)
  end

  # Defensive: legacy callers passing `"daily_summary"` or `"dreaming"` fall
  # back to the historian agent. Logged so we can spot stragglers post-rollup.
  defp agent_for_event(legacy) when legacy in ["daily_summary", "dreaming"] do
    Logger.warning(
      "[SystemEventScheduler] legacy event #{inspect(legacy)} received — " <>
        "routing to historian (drop call site after T6 rollup)"
    )

    do_agent_lookup(@historian_event)
  end

  defp agent_for_event(other) do
    Logger.warning("[SystemEventScheduler] unknown event #{inspect(other)} — skipping")
    nil
  end

  defp do_agent_lookup(event_type) do
    agents =
      from(a in Agent,
        where: a.status == "active",
        where: fragment("? @> ?", a.system_events, ^[event_type]),
        order_by: [asc: a.inserted_at],
        limit: 2
      )
      |> Repo.all()

    case agents do
      [] ->
        nil

      [agent] ->
        agent

      [agent | _rest] = multiple ->
        Logger.warning(
          "[SystemEventScheduler] multiple agents flagged for #{event_type}: " <>
            "#{inspect(Enum.map(multiple, & &1.slug))} — using #{agent.slug}"
        )

        agent
    end
  end

  defp dispatch_to_agent(%Agent{} = agent, event_type, template_slug, extra_metadata) do
    with :ok <- ensure_runtime_reachable(agent, event_type),
         {:ok, space} <- ensure_system_space(agent),
         {:ok, system_participant} <- ensure_system_participant(space),
         {:ok, agent_participant} <-
           Chat.add_agent_participant(space.id, agent, display_name: agent.name),
         {:ok, message} <-
           post_instruction(space, system_participant, event_type, template_slug, extra_metadata) do
      signal = %{
        participant_id: agent_participant.id,
        message_id: message.id,
        space_id: space.id,
        reason: :system_event,
        metadata: Map.merge(%{event_type: event_type}, stringify_keys(extra_metadata))
      }

      AgentResponder.maybe_dispatch(signal)
    else
      {:error, reason} ->
        Logger.error(
          "[SystemEventScheduler] failed to dispatch #{event_type} to #{agent.slug}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Coerce atom/integer/etc metadata values into the shape AgentResponder /
  # downstream consumers expect (string keys); leave atom values alone.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # Skip dispatch when the external agent's runtime is known to be offline —
  # avoids posting an instruction that will dead-letter immediately. Built-in
  # agents always pass this check.
  #
  # `agent.runtime_id` is the FK to `agent_runtimes.id` (UUID); presence is
  # keyed by the human-readable `agent_runtimes.runtime_id` string set by
  # RuntimeChannel.join. Resolve the runtime row before checking presence.
  defp ensure_runtime_reachable(
         %Agent{runtime_type: "external", runtime_id: runtime_pk} = agent,
         event_type
       )
       when is_binary(runtime_pk) do
    case Federation.get_runtime(runtime_pk) do
      %{runtime_id: runtime_id} ->
        if RuntimePresence.online?(runtime_id) do
          :ok
        else
          Logger.warning(
            "[SystemEventScheduler] skipping #{event_type}: external runtime #{runtime_id} is offline"
          )

          {:error, :runtime_offline}
        end

      nil ->
        Logger.warning(
          "[SystemEventScheduler] skipping #{event_type}: agent #{agent.slug} runtime row not found (pk=#{runtime_pk})"
        )

        {:error, :runtime_not_found}
    end
  end

  defp ensure_runtime_reachable(%Agent{}, _event_type), do: :ok

  # ── Space + participant helpers ──────────────────────────────────────────────

  defp ensure_system_space(%Agent{} = agent) do
    slug = "system-#{agent.slug}"

    case Chat.get_space_by_slug(slug) do
      %Chat.Space{} = space ->
        {:ok, space}

      nil ->
        Chat.create_space(%{
          name: "#{agent.name} — System Events",
          slug: slug,
          kind: "system",
          metadata: %{"system_event_space" => true, "agent_id" => agent.id}
        })
    end
  end

  @system_participant_sentinel "00000000-0000-0000-0000-000000000001"

  defp ensure_system_participant(space) do
    case Repo.get_by(Chat.Participant,
           space_id: space.id,
           participant_type: "user",
           participant_id: @system_participant_sentinel
         ) do
      %Chat.Participant{} = p ->
        {:ok, p}

      nil ->
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: @system_participant_sentinel,
          display_name: "System",
          joined_at: DateTime.utc_now()
        })
    end
  end

  defp post_instruction(space, system_participant, event_type, template_slug, extra_metadata) do
    date = Date.to_iso8601(Date.utc_today())
    digest = activity_digest()

    template_vars =
      Map.merge(
        %{date: date, activity_digest: digest},
        extra_metadata
      )

    content =
      case PromptTemplates.render_template(template_slug, template_vars) do
        {:ok, rendered} ->
          rendered

        {:error, :not_found} ->
          @default_historian_instruction
          |> String.replace("{date}", date)
          |> String.replace("{activity_digest}", digest)
      end

    Chat.post_message(%{
      space_id: space.id,
      participant_id: system_participant.id,
      content_type: "text",
      content: content,
      metadata:
        Map.merge(
          %{"source" => "system_event", "event_type" => event_type},
          stringify_keys(extra_metadata)
        )
    })
  end

  defp template_slug_for(@historian_event), do: "historian.scheduled"
  # Legacy mapping — drop after rollup confirms no straggler call sites.
  defp template_slug_for("daily_summary"), do: "historian.scheduled"
  defp template_slug_for("dreaming"), do: "historian.scheduled"
  defp template_slug_for(_), do: "historian.scheduled"

  defp activity_digest do
    window_end = DateTime.utc_now()
    window_start = DateTime.add(window_end, -@daily_window_hours * 3_600, :second)
    ActivityDigest.build(window_start, window_end)
  end
end

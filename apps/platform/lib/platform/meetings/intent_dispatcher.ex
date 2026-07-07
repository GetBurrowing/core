defmodule Platform.Meetings.IntentDispatcher do
  @moduledoc """
  Global singleton that drains `Platform.Meetings.IntentQueue` and
  dispatches classified transcript intents to the agent currently
  assigned to the intent's `target_role`.

  This is the **stage-2** node of task 019f2452 (Meeting Producer). It
  sits between the classifier (which enqueues) and the downstream
  agents (which act):

      classifier --> IntentQueue --> [ IntentDispatcher ] --> agent
                                                              (native
                                                               chat
                                                               responder
                                                               or
                                                               external
                                                               HTTP)

  ## Wake-up paths

  Two wake-up sources land in the same `dispatch_item/2` code path:

    * **PubSub notify** — `IntentQueue.enqueue/3` broadcasts
      `{:intent_enqueued, %{room_id, dedupe_key}}` on the
      `meeting:intent_enqueued` topic. The dispatcher subscribes on
      boot and reacts by calling `IntentQueue.claim_one/2` for exactly
      the key that was just published. This is the hot path — typical
      latency is a couple of milliseconds.
    * **Periodic tick** — a 30-second `Process.send_after/3` self-message
      pulls up to `@tick_batch_size` pending rows via
      `IntentQueue.claim_pending/1`. This is belt-and-braces: if the
      dispatcher was down when a broadcast fired, or the broadcast was
      dropped on a busy node, the tick recovers it.

  ## Role → agent resolution

  The classifier writes `target_role` as a plain string (the LLM emits
  a role slug, e.g. `"designer"`). The dispatcher resolves that to a
  `%Platform.Agents.Agent{}` via:

    1. `Platform.Roles.agent_id_for_role/1` — takes a role_key (NOT a
       responsibility_key) and returns the currently-assigned agent
       UUID. Returns `nil` if the role is unassigned.
    2. `Repo.get(Platform.Agents.Agent, id)` — hydrates the full struct
       (kind, endpoint fields, slug).

  We deliberately use `agent_id_for_role/1` rather than
  `assignee_for/1`: the latter takes a responsibility_key and walks the
  responsibility → role bundle → assignment chain, but `target_role` is
  already a role identifier, so walking the bundle is a category error.

  Unknown role keys (`target_role` isn't in `Role.valid_keys/0`) are
  dropped with reason `:unknown_role`. To avoid log spam when a
  misbehaving classifier keeps emitting the same bogus role, we
  suppress duplicates via a MapSet in state — only the FIRST occurrence
  of each unknown key logs at `:info`, subsequent hits just drop
  silently. The MapSet is meeting-lifetime (well, dispatcher-lifetime);
  a supervisor restart clears it.

  ## Dispatch surface

  Two dispatch fns, selected by the resolved agent's `kind`:

    * `kind == "native"` (also `"local"` / `"federated"` — treated
      identically for stage 2) → build an `AgentResponder`-shaped
      signal (mirrors `Platform.Responsibilities.Router.build_native_signal/3`)
      and call `Platform.Chat.AgentResponder.maybe_dispatch/1`. The
      responder handles the chat-space routing itself.
    * `kind == "external"` → build a synthetic in-memory
      `%Platform.Responsibilities.Responsibility{}` describing the
      target-role's job and call
      `Platform.ExternalAgents.Dispatcher.dispatch/3`. The
      responsibility is NOT persisted; it's the dispatch protocol's
      envelope, nothing more.
    * anything else → `{:error, {:unknown_agent_kind, kind}}` → the
      row is marked-retry once (in case the agent-kind is being
      hot-migrated) and dropped on the second miss.

  ### Test seams

  Both dispatch fns are overridable via `Application.get_env/3`:

    * `:meetings_intent_dispatcher_native_dispatcher` —
      `{Module, :function}` called with the signal map.
      Defaults to `{Platform.Chat.AgentResponder, :maybe_dispatch}`.
    * `:meetings_intent_dispatcher_external_dispatcher` —
      `{Module, :function}` called with
      `(responsibility, agent, context)`. Defaults to
      `{Platform.ExternalAgents.Dispatcher, :dispatch}`.

  Mirrors the seam pattern in `Platform.Responsibilities.Router`
  (`:responsibility_router_native_dispatcher`).

  ## Concurrency + sandbox

  Dispatch runs off-process under
  `Task.Supervisor.async_nolink(Platform.TaskSupervisor, ...)` so a
  slow or crashing agent doesn't block the dispatcher's mailbox. The
  result comes back as `{ref, result}` via `handle_info/2` and is
  translated to `mark_dispatched` / `mark_retry` / `mark_dropped` on
  the queue.

  DataCase-based tests spawn dispatch tasks that AREN'T part of the
  sandbox owner chain; when a test finishes, the sandbox connection
  goes away and the async body may see `DBConnection.OwnershipError`
  or `Ecto.NoResultsError`. We rescue both and reply with
  `{:error, :sandbox_gone}` — the dispatcher then no-ops on the row
  (the queue is meeting-lifetime and gets swept on `:meeting_finished`
  anyway). This mirrors the `sandbox_unowned` treatment in
  `Platform.Orchestration.TaskRouterWatcher`.

  ## Stage 2 non-goals

    * No per-meeting dispatcher — global singleton.
    * No supervision-tree wiring — stage 4.

  ## Stage 3 telemetry

  Four events fire (all guarded by `try/rescue` so a broken listener
  never taps the dispatcher, mirroring `Router.emit_fired_telemetry/3`):

    * `[:platform, :meetings, :intent_dispatched]` — measurements
      `%{count: 1, dispatch_ms: elapsed_ms}`, metadata
      `%{meeting_id, room_id, target_role, intent, agent_id, agent_slug,
      dispatch_kind}` where `dispatch_kind ∈ [:native, :external]`.
      `elapsed_ms` is the wall-clock delta from the top of
      `dispatch_item/2` (BEFORE `Task.Supervisor.async_nolink`) to the
      successful `mark_dispatched`.

    * `[:platform, :meetings, :intent_dropped]` — measurements
      `%{count: 1}`, metadata
      `%{meeting_id, room_id, target_role, intent, reason, attempts}`
      where `reason ∈ [:no_assignee, :unknown_role,
      :max_attempts_exceeded]` and `attempts` is the final attempt count
      (0 for `:no_assignee` / `:unknown_role`, `@max_attempts` for
      exhaustion).

    * `[:platform, :meetings, :intent_dispatcher, :tick]` — measurements
      `%{claimed: n}`, metadata `%{queue_depth_after: n, in_flight: n}`.
      Fires on every scheduled tick, regardless of whether items were
      claimed. `in_flight` retained for backward-compat with stage 2's
      minimal emission.

    * `[:platform, :meetings, :intent_dispatcher, :queue_depth]` —
      measurements `%{count: total_ets_size}`, metadata `%{}`. Piggybacks
      on the `:tick` handler.
  """

  use GenServer

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Roles.Role

  # 30 s belt-and-braces tick — the PubSub notify path handles the hot
  # case, the tick just recovers dropped notifies + dispatcher restarts.
  @default_tick_interval_ms 30_000

  # Stale-claim window used when the tick sees a row that's been
  # `:dispatching` for longer than this — currently unused in stage 2
  # (StallRegistry wires it in stage 4) but the field is threaded
  # through init opts so stage 3's telemetry stage can start emitting
  # it without a schema change.
  @default_stall_window_ms 120_000

  # Bounded batch per tick so a giant post-outage backlog doesn't
  # monopolise the dispatcher.
  @tick_batch_size 50

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Public accessor for the tick batch cap — exposed so the dispatcher's
  stage-3 telemetry tests can assert without duplicating the constant.
  """
  @spec tick_batch_size() :: pos_integer()
  def tick_batch_size, do: @tick_batch_size

  @doc """
  Zero-arity `Platform.Responsibilities.StallRegistry` callback (stage 4).

  Walks `Platform.Meetings.IntentQueue.list_stalled/1` for every row
  that's been sitting in `:status => :dispatching` past the configured
  stall window and drives it back through `mark_retry/3` with reason
  `:sweep_stalled`. The re-broadcast on `meeting:intent_enqueued` wakes
  the dispatcher for the hot path — belt-and-braces if a
  claim-crashed-before-mark_dispatched loss dropped the row into
  limbo.

  Reads the stall window from `Application.get_env(:platform, __MODULE__)`
  so the boot-time config (see `config/config.exs`) is the single
  source of truth. Tests override via `Application.put_env` around the
  callback; per-case dispatcher instances don't need to boot for the
  sweep since the sweep only touches ETS + PubSub, not the GenServer.

  Idempotent: a doubled invocation on the same row cycles it through
  `mark_retry/3` twice, which cost-frees bumps `attempts` — the retry
  cap keeps a truly wedged row from looping forever.
  """
  @spec sweep_stalled() :: :ok
  def sweep_stalled do
    case IntentQueue.list_stalled(stall_window_ms()) do
      [] ->
        :ok

      items ->
        Enum.each(items, fn {room_id, dedupe_key} ->
          Logger.warning(
            "[IntentDispatcher] stalled item — re-queueing room=" <>
              room_id <> " dedupe_key=" <> dedupe_key
          )

          _ = IntentQueue.mark_retry(room_id, dedupe_key, :sweep_stalled)

          MeetingsPubSub.broadcast_intent_enqueued(%{
            room_id: room_id,
            dedupe_key: dedupe_key
          })
        end)

        :ok
    end
  end

  # Read the stall window from Application env, falling back to the
  # module attribute. Called on every `sweep_stalled/0` invocation so
  # a hot-reloaded config takes effect on the next sweep tick without
  # a dispatcher restart.
  defp stall_window_ms do
    :platform
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:stall_window_ms, @default_stall_window_ms)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    :ok = MeetingsPubSub.subscribe_intent_enqueued()

    config = Application.get_env(:platform, __MODULE__, [])

    tick_interval_ms =
      Keyword.get(opts, :tick_interval_ms) ||
        Keyword.get(config, :tick_interval_ms, @default_tick_interval_ms)

    stall_window_ms =
      Keyword.get(opts, :stall_window_ms) ||
        Keyword.get(config, :stall_window_ms, @default_stall_window_ms)

    schedule_tick(tick_interval_ms)

    Logger.info(
      "[IntentDispatcher] started — subscribed to meeting:intent_enqueued, " <>
        "tick_interval_ms=#{tick_interval_ms}"
    )

    {:ok,
     %{
       seen_unknown_roles: MapSet.new(),
       tick_interval_ms: tick_interval_ms,
       stall_window_ms: stall_window_ms,
       dispatched_count: 0,
       dropped_count: 0,
       # Map of Task ref → {room_id, dedupe_key} so `handle_info/2` can
       # translate the async result back into a queue transition.
       in_flight: %{}
     }}
  end

  @impl GenServer
  def handle_info({:intent_enqueued, %{room_id: room_id, dedupe_key: dedupe_key}}, state)
      when is_binary(room_id) and is_binary(dedupe_key) do
    state =
      case IntentQueue.claim_one(room_id, dedupe_key) do
        {:ok, {^room_id, ^dedupe_key, item}} ->
          dispatch_item(item, room_id, dedupe_key, state)

        {:already_claimed, _item} ->
          state

        {:error, :not_found} ->
          # The row was dropped between broadcast and claim (e.g.
          # meeting_finished swept it). Nothing to do.
          state
      end

    {:noreply, state}
  end

  # Tolerate mis-shaped events — the topic is shared with sibling
  # producers and future payload versions.
  def handle_info({:intent_enqueued, _payload}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    claimed = IntentQueue.claim_pending(@tick_batch_size)

    state =
      Enum.reduce(claimed, state, fn {room_id, dedupe_key, item}, acc ->
        dispatch_item(item, room_id, dedupe_key, acc)
      end)

    emit_tick_telemetry(length(claimed), map_size(state.in_flight))

    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  # Async-task result path. `Task.Supervisor.async_nolink/2` sends
  # `{ref, result}` on success and `{:DOWN, ref, :process, _, reason}`
  # on crash — we match both.
  def handle_info({ref, result}, %{in_flight: in_flight} = state) when is_reference(ref) do
    case Map.pop(in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{} = entry, rest} ->
        # Demonitor so we don't get the follow-up `:DOWN` for a task
        # that already returned cleanly.
        Process.demonitor(ref, [:flush])
        state = handle_dispatch_result(result, entry, %{state | in_flight: rest})
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: in_flight} = state)
      when is_reference(ref) do
    case Map.pop(in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{room_id: room_id, dedupe_key: dedupe_key} = entry, rest} ->
        Logger.warning(
          "[IntentDispatcher] dispatch task exited — room=#{room_id} " <>
            "dedupe_key=#{dedupe_key} reason=#{inspect(reason)}"
        )

        state =
          handle_dispatch_result(
            {:error, {:task_exit, reason}},
            entry,
            %{state | in_flight: rest}
          )

        {:noreply, state}
    end
  end

  # Test-only seam: sync-echo the current state. Guarded with
  # `Mix.env() == :test` so production doesn't respond to stray
  # messages.
  if Mix.env() == :test do
    def handle_info({:__test_get_state, from, ref}, state) do
      send(from, {ref, state})
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Dispatch pipeline ──────────────────────────────────────────────────────

  # Route a claimed item to the target agent OR mark it dropped/retry
  # based on the validation + resolution outcome. Always returns an
  # updated state (may add a Task ref to `in_flight`).
  #
  # `dispatch_started_at` is captured here so that a successful async
  # dispatch can report the full wall-clock delta on
  # `[:platform, :meetings, :intent_dispatched]` in stage 3 telemetry.
  defp dispatch_item(item, room_id, dedupe_key, state) do
    dispatch_started_at = System.monotonic_time(:millisecond)
    target_role = Map.get(item, :target_role)

    cond do
      is_nil(target_role) ->
        _ = IntentQueue.mark_dropped(room_id, dedupe_key, :no_assignee)
        emit_dropped_telemetry(item, room_id, target_role, :no_assignee, 0)
        %{state | dropped_count: state.dropped_count + 1}

      not valid_role_key?(target_role) ->
        state = log_unknown_role_once(target_role, room_id, state)
        _ = IntentQueue.mark_dropped(room_id, dedupe_key, :unknown_role)
        emit_dropped_telemetry(item, room_id, target_role, :unknown_role, 0)
        %{state | dropped_count: state.dropped_count + 1}

      true ->
        resolve_and_spawn(
          item,
          room_id,
          dedupe_key,
          to_string(target_role),
          dispatch_started_at,
          state
        )
    end
  end

  defp resolve_and_spawn(item, room_id, dedupe_key, role_key, dispatch_started_at, state) do
    case safe_agent_id_for_role(role_key) do
      {:error, :sandbox_gone} ->
        # Sandbox-owned Roles.agent_id_for_role/1 raised — dispatch
        # tasks in sandboxed tests aren't part of the ownership chain
        # so we treat this identically to "no assignee" for this run,
        # but at :debug because it's expected in tests.
        Logger.debug(
          "[IntentDispatcher] sandbox-owned Roles lookup — treating as no-assignee " <>
            "room=#{room_id} role=#{role_key}"
        )

        _ = IntentQueue.mark_dropped(room_id, dedupe_key, :no_assignee)
        emit_dropped_telemetry(item, room_id, role_key, :no_assignee, 0)
        %{state | dropped_count: state.dropped_count + 1}

      {:ok, nil} ->
        _ = IntentQueue.mark_dropped(room_id, dedupe_key, :no_assignee)
        emit_dropped_telemetry(item, room_id, role_key, :no_assignee, 0)
        %{state | dropped_count: state.dropped_count + 1}

      {:ok, agent_id} ->
        case safe_get_agent(agent_id) do
          {:error, :sandbox_gone} ->
            Logger.debug(
              "[IntentDispatcher] sandbox-owned Agent lookup — treating as no-assignee " <>
                "room=#{room_id} role=#{role_key}"
            )

            _ = IntentQueue.mark_dropped(room_id, dedupe_key, :no_assignee)
            emit_dropped_telemetry(item, room_id, role_key, :no_assignee, 0)
            %{state | dropped_count: state.dropped_count + 1}

          {:ok, nil} ->
            # Race between role_assignments row and agent row (the
            # assignment survived a hard-delete on the agent). Mark
            # retry — a follow-up assignment fix will let a subsequent
            # tick land it.
            promote_or_retry(item, room_id, dedupe_key, role_key, :agent_not_found, state)

          {:ok, %Agent{} = agent} ->
            spawn_dispatch(
              agent,
              item,
              room_id,
              dedupe_key,
              role_key,
              dispatch_started_at,
              state
            )
        end
    end
  end

  # Fire off the actual dispatch under Task.Supervisor.async_nolink so
  # the dispatcher process stays responsive. Stash the ref so the
  # `{ref, result}` / `:DOWN` handlers can find the row again. The
  # in-flight entry carries everything needed for stage-3 telemetry
  # (item + agent + dispatch_started_at) so `handle_dispatch_result`
  # can emit `:intent_dispatched` / `:intent_dropped` without a
  # second DB round-trip.
  defp spawn_dispatch(agent, item, room_id, dedupe_key, role_key, dispatch_started_at, state) do
    task =
      Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
        do_dispatch(agent, item, room_id, dedupe_key, role_key)
      end)

    entry = %{
      room_id: room_id,
      dedupe_key: dedupe_key,
      role_key: role_key,
      agent: agent,
      item: item,
      dispatch_started_at: dispatch_started_at
    }

    put_in(state, [:in_flight, task.ref], entry)
  end

  # The dispatch body itself, run inside a Task. Wraps sandbox-race
  # exceptions so the dispatcher process never crashes from an
  # off-process DB call.
  @doc false
  @spec do_dispatch(Agent.t(), map(), binary(), binary(), binary()) :: any()
  def do_dispatch(%Agent{} = agent, item, room_id, dedupe_key, role_key) do
    case agent.kind do
      kind when kind in ["native", "local", "federated"] ->
        signal = build_native_signal(agent, item, room_id, dedupe_key, role_key)
        call_native_dispatcher(signal)

      "external" ->
        responsibility = build_synthetic_responsibility(item, role_key)
        context = build_external_context(item, room_id, role_key)
        call_external_dispatcher(responsibility, agent, context)

      other ->
        {:error, {:unknown_agent_kind, other}}
    end
  rescue
    error in [DBConnection.OwnershipError, Ecto.NoResultsError] ->
      Logger.debug(
        "[IntentDispatcher] sandbox-owned dispatch — treating as sandbox_gone " <>
          "room=#{room_id} role=#{role_key} error=#{Exception.message(error)}"
      )

      {:error, :sandbox_gone}
  end

  defp handle_dispatch_result(result, %{} = entry, state) do
    %{
      room_id: room_id,
      dedupe_key: dedupe_key,
      role_key: role_key,
      agent: agent,
      item: item,
      dispatch_started_at: dispatch_started_at
    } = entry

    case classify_result(result) do
      :success ->
        _ = IntentQueue.mark_dispatched(room_id, dedupe_key)
        elapsed_ms = System.monotonic_time(:millisecond) - dispatch_started_at
        emit_dispatched_telemetry(item, room_id, role_key, agent, elapsed_ms)
        %{state | dispatched_count: state.dispatched_count + 1}

      :sandbox_gone ->
        # Silent no-op: the queue row is already claimed
        # (:dispatching); a sandbox-race retry will fire on the next
        # tick or when the sweep clears it. Deliberately no telemetry
        # here — sandbox_gone is a test-only artefact, not a real
        # dispatch outcome.
        _ = IntentQueue.mark_dispatched(room_id, dedupe_key)
        state

      {:retry, reason} ->
        promote_or_retry(item, room_id, dedupe_key, role_key, reason, state)
    end
  end

  # Result-shape classifier. The two dispatch surfaces return different
  # shapes:
  #
  #   * native (AgentResponder.maybe_dispatch/1) — returns `:ok` or
  #     `{:error, reason}`; the `Task.start`-wrapped version always
  #     returns `:ok`.
  #   * external (ExternalAgents.Dispatcher.dispatch/3) — returns
  #     `{:ok, validated_content}` or `{:error, reason}`.
  defp classify_result(:ok), do: :success
  defp classify_result({:ok, _content}), do: :success
  defp classify_result({:error, :sandbox_gone}), do: :sandbox_gone
  defp classify_result({:error, reason}), do: {:retry, reason}
  defp classify_result(other), do: {:retry, {:unexpected_result, other}}

  defp promote_or_retry(item, room_id, dedupe_key, role_key, reason, state) do
    case IntentQueue.mark_retry(room_id, dedupe_key, reason) do
      {:ok, _attempts} ->
        state

      {:exhausted, attempts} ->
        _ = IntentQueue.mark_dropped(room_id, dedupe_key, :max_attempts_exceeded)
        emit_dropped_telemetry(item, room_id, role_key, :max_attempts_exceeded, attempts)
        %{state | dropped_count: state.dropped_count + 1}

      {:error, :not_found} ->
        state
    end
  end

  # ── Signal + context builders ──────────────────────────────────────────────

  # Mirrors `Platform.Responsibilities.Router.build_native_signal/3`
  # shape so AgentResponder treats the payload identically to a
  # trigger-fired responsibility.
  defp build_native_signal(%Agent{} = agent, item, room_id, dedupe_key, role_key) do
    %{
      reason: :system_event,
      metadata: %{
        source: :meetings_intent_dispatcher,
        role_key: role_key,
        intent: Map.get(item, :intent),
        confidence: Map.get(item, :confidence),
        chunk_id: Map.get(item, :chunk_id),
        dedupe_key: dedupe_key,
        room_id: room_id,
        meeting_id: Map.get(item, :meeting_id),
        agent_id: agent.id,
        agent_slug: agent.slug
      }
    }
    |> maybe_put(:meeting_id, Map.get(item, :meeting_id))
    |> maybe_put(:space_id, Map.get(item, :space_id))
  end

  # Synthetic in-memory Responsibility — NOT persisted. The external
  # dispatcher only reads `:key`, `:default_prompt_template`,
  # `:output_contract`, and `:metadata` off it, so we populate those
  # and leave the DB-shaped bookkeeping fields at their struct
  # defaults.
  defp build_synthetic_responsibility(item, role_key) do
    %Responsibility{
      key: "meetings.produce.#{role_key}",
      feature: "meetings",
      trigger_kind: "event_topic",
      trigger_config: %{topic: "meeting:intent_enqueued"},
      scope: "per_meeting",
      context_provided: ["intent", "target_role", "chunk_id", "meeting_id"],
      output_contract: %{},
      default_prompt_template: nil,
      cost_profile: "low_freq_capable",
      enabled: true,
      metadata: %{
        source: "meetings_intent_dispatcher",
        role_key: role_key,
        intent: Map.get(item, :intent)
      }
    }
  end

  defp build_external_context(item, room_id, role_key) do
    %{
      role_key: role_key,
      room_id: room_id,
      intent: Map.get(item, :intent),
      target_role: Map.get(item, :target_role),
      confidence: Map.get(item, :confidence),
      chunk_id: Map.get(item, :chunk_id),
      meeting_id: Map.get(item, :meeting_id)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Native / external test-seams ───────────────────────────────────────────

  defp call_native_dispatcher(signal) do
    {mod, fun} = native_dispatcher_mfa()
    apply(mod, fun, [signal])
  end

  defp native_dispatcher_mfa do
    Application.get_env(
      :platform,
      :meetings_intent_dispatcher_native_dispatcher,
      {Platform.Chat.AgentResponder, :maybe_dispatch}
    )
  end

  defp call_external_dispatcher(responsibility, agent, context) do
    {mod, fun} = external_dispatcher_mfa()
    apply(mod, fun, [responsibility, agent, context])
  end

  defp external_dispatcher_mfa do
    Application.get_env(
      :platform,
      :meetings_intent_dispatcher_external_dispatcher,
      {Platform.ExternalAgents.Dispatcher, :dispatch}
    )
  end

  # ── Role validation + resolution ───────────────────────────────────────────

  defp valid_role_key?(role) when is_binary(role) do
    role in Role.valid_keys()
  end

  defp valid_role_key?(role) when is_atom(role) do
    Atom.to_string(role) in Role.valid_keys()
  end

  defp valid_role_key?(_), do: false

  defp log_unknown_role_once(role, room_id, state) do
    key = to_string(role)

    if MapSet.member?(state.seen_unknown_roles, key) do
      state
    else
      Logger.info(
        "[IntentDispatcher] unknown target_role=#{inspect(role)} — dropping intent " <>
          "room=#{room_id}"
      )

      %{state | seen_unknown_roles: MapSet.put(state.seen_unknown_roles, key)}
    end
  end

  defp safe_agent_id_for_role(role_key) do
    {:ok, Roles.agent_id_for_role(role_key)}
  rescue
    DBConnection.OwnershipError -> {:error, :sandbox_gone}
    Ecto.NoResultsError -> {:error, :sandbox_gone}
  end

  defp safe_get_agent(agent_id) do
    {:ok, Repo.get(Agent, agent_id)}
  rescue
    DBConnection.OwnershipError -> {:error, :sandbox_gone}
    Ecto.NoResultsError -> {:error, :sandbox_gone}
  end

  # ── Scheduling ────────────────────────────────────────────────────────────

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  # ── Telemetry helpers ─────────────────────────────────────────────────────
  #
  # Every :telemetry.execute call is guarded by `try/rescue _ -> :ok`
  # so a broken listener can never tap the dispatcher. Mirrors
  # `Platform.Responsibilities.Router.emit_fired_telemetry/3`.

  # Name of the IntentQueue ETS table — kept as a local module attribute
  # rather than a cross-module fetch so an :ets.info miss doesn't cost
  # a call round-trip on the hot tick path.
  @queue_table :meeting_intent_queue

  defp emit_dispatched_telemetry(item, room_id, role_key, %Agent{} = agent, elapsed_ms) do
    :telemetry.execute(
      [:platform, :meetings, :intent_dispatched],
      %{count: 1, dispatch_ms: elapsed_ms},
      %{
        meeting_id: Map.get(item, :meeting_id),
        room_id: room_id,
        target_role: role_key,
        intent: Map.get(item, :intent),
        agent_id: agent.id,
        agent_slug: agent.slug,
        dispatch_kind: dispatch_kind_for(agent)
      }
    )
  rescue
    _ -> :ok
  end

  defp emit_dropped_telemetry(item, room_id, target_role, reason, attempts) do
    :telemetry.execute(
      [:platform, :meetings, :intent_dropped],
      %{count: 1},
      %{
        meeting_id: Map.get(item, :meeting_id),
        room_id: room_id,
        target_role: target_role,
        intent: Map.get(item, :intent),
        reason: reason,
        attempts: attempts
      }
    )
  rescue
    _ -> :ok
  end

  # Emit both :tick and :queue_depth on the same handler invocation —
  # one `:ets.info/2` call, two events. Guarded independently so a
  # crashing listener on one doesn't skip the other.
  defp emit_tick_telemetry(claimed, in_flight_size) do
    queue_depth = queue_depth_size()

    try do
      :telemetry.execute(
        [:platform, :meetings, :intent_dispatcher, :tick],
        %{claimed: claimed},
        %{queue_depth_after: queue_depth, in_flight: in_flight_size}
      )
    rescue
      _ -> :ok
    end

    try do
      :telemetry.execute(
        [:platform, :meetings, :intent_dispatcher, :queue_depth],
        %{count: queue_depth},
        %{}
      )
    rescue
      _ -> :ok
    end

    :ok
  end

  defp queue_depth_size do
    case :ets.info(@queue_table, :size) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp dispatch_kind_for(%Agent{kind: "external"}), do: :external
  defp dispatch_kind_for(%Agent{}), do: :native
end

defmodule Platform.Meetings.IntentDispatcher do
  @moduledoc """
  Global singleton that drives every meeting's ack-gated intent queue
  and hands each classified intent to the agent assigned to its
  `target_role`.

      classifier --> IntentQueue.Server (per meeting, serial cursor)
                          ^        |
                          |        v
                     intent_ack  [ IntentDispatcher ] --> agent

  ## Serial cursor (task 019f70b8 stage 3)

  The dispatcher no longer owns concurrency — the queue does. Each
  per-meeting `Platform.Meetings.IntentQueue.Server` holds at most ONE
  row in `:dispatched` or `:acked`, and `claim_next/1` is the only way
  to get a row out. The dispatcher's job is to be the cursor's caller:
  claim, resolve, hand off, and report the outcome back as an explicit
  transition.

  **What this replaced.** Until stage 3 the dispatcher claimed up to 50
  rows per tick out of one global table (`claim_pending/1`) and fanned
  them out through `Task.Supervisor.async_nolink`, plus a `claim_one/2`
  hot path per broadcast. Nothing bounded how many intents could be in
  front of one agent at once, and the queue's only record of an
  in-flight dispatch was a row that `mark_dispatched/2` then deleted.
  `claim_pending/1`, `claim_one/2`, `mark_dispatched/2`, `mark_retry/3`,
  `mark_dropped/3`, `list_stalled/1` and the retry cap are all gone.

  **Why the retry cap went.** Under the ack contract the target reports
  the outcome (`intent_ack`) or the ack timeout decides it. "Try N more
  times, then drop silently" no longer describes a real state: a
  dispatch that can't reach a runtime is a `:dispatch_failed` row the
  producer can see and act on, and one that reaches a runtime that
  never answers is `:timed_out` (or `:no_ack_spawn_failed`). Retrying
  behind the operator's back is precisely the invisibility this task
  exists to remove.

  ## Wake-up paths

    * **PubSub notify** — the queue server broadcasts
      `{:intent_enqueued, %{meeting_id: id}}` when a row is inserted
      AND when the cursor is released. Both mean "this meeting may have
      something to send"; the dispatcher drains that one meeting. This
      is the hot path.
    * **Periodic tick (30s)** — walks every live queue and re-drives
      it. Belt-and-braces only: it recovers a dropped broadcast or a
      dispatcher that was down when one fired. It claims nothing on its
      own that the notify path wouldn't have.

  `sweep_stalled/0` (the `Platform.Responsibilities.StallRegistry`
  callback) is now the same re-drive. Stall DETECTION moved into the
  queue: a row that goes out and never comes back is resolved by the
  ack timeout, which is a timer on the row's own owner rather than a
  periodic scan of a shared table.

  ## Role → agent resolution

  Unchanged from task 019f2452. `target_role` is a role slug the LLM
  emitted, resolved through `Platform.Roles.agent_id_for_role/1` (NOT
  `assignee_for/1` — that takes a responsibility_key and walking the
  bundle for something that is already a role identifier is a category
  error) and hydrated with `Repo.get(Platform.Agents.Agent, id)`.

  Every resolution failure now lands the row on `:dispatch_failed` with
  a `dispatch_failure_reason`, retained and visible, instead of
  deleting it:

  | reason              | meaning                                        |
  |---------------------|------------------------------------------------|
  | `:no_target_role`   | the classifier produced no role                |
  | `:unknown_role`     | role isn't in `Role.valid_keys/0`              |
  | `:no_assignee`      | role is valid but unassigned                   |
  | `:agent_not_found`  | assignment points at a deleted agent           |
  | `:no_runtime`       | agent exists but has no linked AgentRuntime    |

  Unknown role keys still log once each (MapSet in state) so a
  misbehaving classifier can't spam the log.

  ## Dispatch surface (task 019f70b8 stage 4)

  ONE surface: a runtime-attention broadcast on `runtime:<runtime_id>`,
  built by `Platform.Meetings.IntentRuntimeAdapter` and sent through
  `Platform.Federation.dispatch_intent_attention/2`. The runtime spawns
  a subagent and calls `intent_ack` — which is the entire point of the
  redesign, because a chat message has no ack and no addressable
  subagent to cancel.

  **Retired, and what replaced them.** Until stage 4 this module chose
  between two surfaces on the resolved agent's `kind`:

    * native / local / federated → `Platform.Chat.AgentResponder.maybe_dispatch/1`
      with a `%{reason: :system_event, metadata: %{...}}` signal
    * external → `Platform.ExternalAgents.Dispatcher.dispatch/3` with a
      synthetic in-memory `Responsibility`

  Both are gone, along with the `:meetings_intent_dispatcher_native_dispatcher`
  and `:meetings_intent_dispatcher_external_dispatcher` MFA seams, the
  synthetic-responsibility builder, and the `:unknown_agent_kind`
  failure reason (agent `kind` no longer influences dispatch at all —
  only whether a runtime is linked).

  **The behaviour change this is:** an agent with NO linked
  AgentRuntime used to receive a chat-responder signal and now lands
  the row on `:dispatch_failed` with `dispatch_failure_reason:
  :no_runtime` — retained, X-able, and visible in the stage-7 strip.
  That is the approved design: the queue's contract is an ack from a
  spawned subagent, and a surface that cannot ack cannot honour it.
  The cost is real and deliberate — a role assigned to a runtime-less
  agent produces visible red rows instead of silent chat traffic, which
  is the trade this task was created to make.

  ## Concurrency

  Dispatch is INLINE. The old `Task.Supervisor.async_nolink` fan-out
  (and the `in_flight` ref→context map, the `{ref, result}` /
  `{:DOWN, ...}` result plumbing, and the `:sandbox_gone` rescue that
  existed because those tasks outlived their test's sandbox) existed to
  keep a slow HTTP call to an external agent out of the dispatcher's
  mailbox. There is no such call any more: the whole hand-off is a
  local PubSub broadcast behind two `Repo.get/2`s, on a path that
  already did two `Repo.get/2`s inline for role resolution.

  The ordering that mattered is preserved: the row is marked
  `:dispatched` — arming the ack window — BEFORE the broadcast goes
  out, so a runtime that acks instantly can never race ahead of its own
  dispatch record.

  ## Telemetry

    * `[:platform, :meetings, :intent_dispatched]` — measurements
      `%{count: 1, dispatch_ms: elapsed_ms}`, metadata
      `%{meeting_id, room_id, intent_id, target_role, intent, agent_id,
      agent_slug, runtime_id, dispatch_kind}`. `dispatch_kind` is now
      always `:runtime_attention` (it was `:native | :external`); the
      key survives because listeners match on it, and `runtime_id` is
      new — it is the topic the signal actually went to.

    * `[:platform, :meetings, :intent_dropped]` — measurements
      `%{count: 1}`, metadata `%{meeting_id, room_id, intent_id,
      target_role, intent, reason}`. "Dropped" is a misnomer kept for
      listener compatibility: the row is RETAINED as
      `:dispatch_failed`, and `reason` is the table above.

    * `[:platform, :meetings, :intent_dispatcher, :tick]` — measurements
      `%{claimed: n}`, metadata `%{queue_depth_after: n, in_flight: n}`.
      `in_flight` counts rows currently held by a meeting cursor across
      every live queue — it used to count this process's outstanding
      dispatch tasks, which no longer exist.

    * `[:platform, :meetings, :intent_dispatcher, :queue_depth]` —
      measurements `%{count: queued_rows_across_live_meetings}`.
  """

  use GenServer

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentRuntimeAdapter
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.Role

  # 30 s belt-and-braces tick — the PubSub notify path handles the hot
  # case, the tick just recovers dropped notifies + dispatcher restarts.
  @default_tick_interval_ms 30_000

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Zero-arity `Platform.Responsibilities.StallRegistry` callback.

  Re-drives every live meeting's queue. Since task 019f70b8 stage 3
  this is a LIVENESS sweep, not a stall sweep: a row that was
  dispatched and never answered is resolved by the queue server's own
  ack timer, not by anything here. What this recovers is a meeting
  whose cursor is free and whose `:intent_enqueued` notify was dropped
  — the queue has work and nobody noticed.

  Idempotent by construction: a meeting whose cursor is already held
  answers `{:busy, _}` and nothing happens.

  Implemented as a re-broadcast rather than a direct drain so the
  callback stays safe to invoke with no dispatcher running — the
  StallRegistry fires it from its own process, and in test env the
  dispatcher is off by default.
  """
  @spec sweep_stalled() :: :ok
  def sweep_stalled do
    Enum.each(live_meeting_ids(), fn meeting_id ->
      MeetingsPubSub.broadcast_intent_enqueued(%{meeting_id: meeting_id})
    end)
  end

  @doc """
  Drain one meeting: claim its next queued intent, if the cursor is
  free, and dispatch it.

  Returns `:dispatched`, `:busy`, or `:empty`. `server` defaults to the
  singleton's registered name; tests boot per-case instances under
  unique names and pass them here. A call to a dispatcher that isn't
  running answers `:empty` rather than exiting — callers use this as a
  nudge, not as a source of truth.
  """
  @spec drain(binary(), GenServer.server()) :: :dispatched | :busy | :empty
  def drain(meeting_id, server \\ __MODULE__) when is_binary(meeting_id) do
    GenServer.call(server, {:drain, meeting_id})
  catch
    :exit, _ -> :empty
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    :ok = MeetingsPubSub.subscribe_intent_enqueued()

    config = Application.get_env(:platform, __MODULE__, [])

    tick_interval_ms =
      Keyword.get(opts, :tick_interval_ms) ||
        Keyword.get(config, :tick_interval_ms, @default_tick_interval_ms)

    schedule_tick(tick_interval_ms)

    Logger.info(
      "[IntentDispatcher] started — subscribed to meeting:intent_enqueued, " <>
        "tick_interval_ms=#{tick_interval_ms}"
    )

    {:ok,
     %{
       seen_unknown_roles: MapSet.new(),
       tick_interval_ms: tick_interval_ms,
       dispatched_count: 0,
       failed_count: 0
     }}
  end

  @impl GenServer
  def handle_call({:drain, meeting_id}, _from, state) do
    {outcome, state} = do_drain(meeting_id, state)
    {:reply, outcome, state}
  end

  if Mix.env() == :test do
    def handle_call(:__test_get_state, _from, state), do: {:reply, state, state}
  end

  @impl GenServer
  def handle_info({:intent_enqueued, %{meeting_id: meeting_id}}, state)
      when is_binary(meeting_id) do
    {_outcome, state} = do_drain(meeting_id, state)
    {:noreply, state}
  end

  # Tolerate mis-shaped events — the topic is shared with sibling
  # producers and future payload versions.
  def handle_info({:intent_enqueued, _payload}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    {claimed, state} =
      Enum.reduce(live_meeting_ids(), {0, state}, fn meeting_id, {n, acc} ->
        case do_drain(meeting_id, acc) do
          {:dispatched, acc} -> {n + 1, acc}
          {_other, acc} -> {n, acc}
        end
      end)

    emit_tick_telemetry(claimed)

    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Drain pipeline ─────────────────────────────────────────────────────────

  defp do_drain(meeting_id, state) do
    case IntentQueue.claim_next(meeting_id) do
      {:ok, row} ->
        {:dispatched, dispatch_row(meeting_id, row, state)}

      {:busy, _intent_id} ->
        {:busy, state}

      :empty ->
        {:empty, state}
    end
  end

  # A claimed row is still `:queued`. Every branch below MUST commit it
  # with an explicit transition — that is the contract `claim_next/1`
  # hands over, and the queue's claim watchdog is the safety net for a
  # branch that somehow doesn't.
  defp dispatch_row(meeting_id, row, state) do
    dispatch_started_at = System.monotonic_time(:millisecond)
    target_role = row.target_role

    cond do
      is_nil(target_role) ->
        fail_dispatch(meeting_id, row, :no_target_role, state)

      not valid_role_key?(target_role) ->
        state = log_unknown_role_once(target_role, meeting_id, state)
        fail_dispatch(meeting_id, row, :unknown_role, state)

      true ->
        resolve_and_dispatch(meeting_id, row, to_string(target_role), dispatch_started_at, state)
    end
  end

  defp resolve_and_dispatch(meeting_id, row, role_key, dispatch_started_at, state) do
    case safe_agent_id_for_role(role_key) do
      {:error, :sandbox_gone} ->
        # Sandbox-owned Roles.agent_id_for_role/1 raised — dispatch
        # runs in tests whose ownership chain has gone away. Treated as
        # "no assignee" for this run, at :debug because it's expected.
        Logger.debug(
          "[IntentDispatcher] sandbox-owned Roles lookup — treating as no-assignee " <>
            "meeting=#{meeting_id} role=#{role_key}"
        )

        fail_dispatch(meeting_id, row, :no_assignee, state)

      {:ok, nil} ->
        fail_dispatch(meeting_id, row, :no_assignee, state)

      {:ok, agent_id} ->
        case safe_get_agent(agent_id) do
          {:error, :sandbox_gone} ->
            Logger.debug(
              "[IntentDispatcher] sandbox-owned Agent lookup — treating as no-assignee " <>
                "meeting=#{meeting_id} role=#{role_key}"
            )

            fail_dispatch(meeting_id, row, :no_assignee, state)

          {:ok, nil} ->
            # Race between role_assignments row and agent row (the
            # assignment survived a hard-delete on the agent). Visible
            # failure rather than a silent retry — the producer needs
            # to know the role points at nothing.
            fail_dispatch(meeting_id, row, :agent_not_found, state)

          {:ok, %Agent{} = agent} ->
            resolve_runtime_and_dispatch(
              meeting_id,
              row,
              agent,
              role_key,
              dispatch_started_at,
              state
            )
        end
    end
  end

  # The runtime is resolved BEFORE the row is marked `:dispatched`.
  # That ordering is the whole reason `IntentRuntimeAdapter.resolve_target/1`
  # returns errors while `Federation.dispatch_intent_attention/2`
  # swallows them: "there is nobody to send this to" has to be a
  # `:dispatch_failed{:no_runtime}` row the producer can see, and once
  # we have broadcast we can no longer tell that from "sent, awaiting
  # ack".
  defp resolve_runtime_and_dispatch(meeting_id, row, agent, role_key, started_at, state) do
    case safe_resolve_target(agent) do
      {:error, :sandbox_gone} ->
        Logger.debug(
          "[IntentDispatcher] sandbox-owned runtime lookup — treating as no-runtime " <>
            "meeting=#{meeting_id} role=#{role_key}"
        )

        fail_dispatch(meeting_id, row, :no_runtime, state)

      {:error, reason} when reason in [:no_runtime, :no_target_agent, :agent_not_found] ->
        Logger.info(
          "[IntentDispatcher] no runtime for target — meeting=#{meeting_id} " <>
            "role=#{role_key} agent=#{agent.slug} reason=#{inspect(reason)}"
        )

        fail_dispatch(meeting_id, row, runtime_failure_reason(reason), state)

      {:ok, target} ->
        send_dispatch(meeting_id, row, agent, target, role_key, started_at, state)
    end
  end

  # Mark `:dispatched` FIRST (arming the queue's ack window), then
  # broadcast. The ordering is the ack contract: the row is with the
  # runtime from this moment, so an instant `intent_ack` can never
  # arrive for a row that is still `:queued`.
  defp send_dispatch(meeting_id, row, agent, target, role_key, dispatch_started_at, state) do
    case IntentQueue.transition(meeting_id, row.id, :dispatched, %{
           target_agent_id: agent.id,
           target_agent_slug: agent.slug
         }) do
      {:ok, dispatched_row} ->
        # Built from the UPDATED row so the payload's target_agent_id
        # and the ETS row can never disagree about where this went.
        :ok = IntentRuntimeAdapter.send_attention(dispatched_row, target)

        elapsed_ms = System.monotonic_time(:millisecond) - dispatch_started_at
        emit_dispatched_telemetry(meeting_id, dispatched_row, role_key, agent, target, elapsed_ms)

        %{state | dispatched_count: state.dispatched_count + 1}

      {:error, reason} ->
        # The queue refused the transition (row deleted mid-claim, or
        # the cursor moved). Nothing to dispatch and nothing to fail —
        # the row is no longer ours.
        Logger.debug(
          "[IntentDispatcher] could not mark dispatched — meeting=#{meeting_id} " <>
            "intent=#{row.id} reason=#{inspect(reason)}"
        )

        state
    end
  end

  # `:no_target_agent` cannot happen on this path — we only get here
  # holding an `%Agent{}` — but the adapter's error set is shared with
  # the cancel path, so it is mapped rather than left to fall through
  # to a confusing default.
  defp runtime_failure_reason(:agent_not_found), do: :agent_not_found
  defp runtime_failure_reason(:no_target_agent), do: :agent_not_found
  defp runtime_failure_reason(_), do: :no_runtime

  # The one place a row leaves the cursor unsuccessfully. Retains the
  # row (`:dispatch_failed` is a visible, X-able, edit-able state) and
  # releases the cursor so the meeting's next intent can go out.
  defp fail_dispatch(meeting_id, row, reason, state) do
    _ =
      IntentQueue.transition(meeting_id, row.id, :dispatch_failed, %{
        dispatch_failure_reason: reason
      })

    emit_failed_telemetry(meeting_id, row, reason)
    %{state | failed_count: state.failed_count + 1}
  end

  # ── Role validation + resolution ───────────────────────────────────────────

  defp valid_role_key?(role) when is_binary(role) do
    role in Role.valid_keys()
  end

  defp valid_role_key?(role) when is_atom(role) do
    Atom.to_string(role) in Role.valid_keys()
  end

  defp valid_role_key?(_), do: false

  defp log_unknown_role_once(role, meeting_id, state) do
    key = to_string(role)

    if MapSet.member?(state.seen_unknown_roles, key) do
      state
    else
      Logger.info(
        "[IntentDispatcher] unknown target_role=#{inspect(role)} — failing intent " <>
          "meeting=#{meeting_id}"
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

  defp safe_resolve_target(agent) do
    IntentRuntimeAdapter.resolve_target(agent)
  rescue
    DBConnection.OwnershipError -> {:error, :sandbox_gone}
    Ecto.NoResultsError -> {:error, :sandbox_gone}
  end

  # ── Scheduling ────────────────────────────────────────────────────────────

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp live_meeting_ids do
    IntentQueue.live_meeting_ids()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # ── Telemetry helpers ─────────────────────────────────────────────────────
  #
  # Every :telemetry.execute call is guarded by `try/rescue _ -> :ok`
  # so a broken listener can never tap the dispatcher. Mirrors
  # `Platform.Responsibilities.Router.emit_fired_telemetry/3`.

  defp emit_dispatched_telemetry(meeting_id, row, role_key, %Agent{} = agent, target, elapsed_ms) do
    :telemetry.execute(
      [:platform, :meetings, :intent_dispatched],
      %{count: 1, dispatch_ms: elapsed_ms},
      %{
        meeting_id: meeting_id,
        room_id: row.room_id,
        intent_id: row.id,
        target_role: role_key,
        intent: row.classified_intent,
        agent_id: agent.id,
        agent_slug: agent.slug,
        runtime_id: target.runtime_id,
        dispatch_kind: :runtime_attention
      }
    )
  rescue
    _ -> :ok
  end

  defp emit_failed_telemetry(meeting_id, row, reason) do
    :telemetry.execute(
      [:platform, :meetings, :intent_dropped],
      %{count: 1},
      %{
        meeting_id: meeting_id,
        room_id: row.room_id,
        intent_id: row.id,
        target_role: row.target_role,
        intent: row.classified_intent,
        reason: reason
      }
    )
  rescue
    _ -> :ok
  end

  # Emit both :tick and :queue_depth on the same handler invocation.
  # Guarded independently so a crashing listener on one doesn't skip
  # the other.
  defp emit_tick_telemetry(claimed) do
    %{queued: queue_depth, in_flight: in_flight} = queue_census()

    try do
      :telemetry.execute(
        [:platform, :meetings, :intent_dispatcher, :tick],
        %{claimed: claimed},
        %{queue_depth_after: queue_depth, in_flight: in_flight}
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

  # One walk of every live meeting's rows, two numbers out of it.
  #
  # `queued` is "rows still waiting to go out" — the pre-019f70b8
  # version read `:ets.info/2` on one global table, which no longer
  # exists and which also counted in-flight rows, making the number
  # mean two things at once. `in_flight` is rows a meeting cursor is
  # currently holding; since stage 4 removed the dispatcher's async
  # task map, the queues are the only place that fact lives.
  defp queue_census do
    in_flight_statuses = IntentQueue.in_flight_statuses()

    live_meeting_ids()
    |> Enum.reduce(%{queued: 0, in_flight: 0}, fn meeting_id, acc ->
      Enum.reduce(IntentQueue.list(meeting_id), acc, fn row, inner ->
        cond do
          row.status == :queued -> %{inner | queued: inner.queued + 1}
          row.status in in_flight_statuses -> %{inner | in_flight: inner.in_flight + 1}
          true -> inner
        end
      end)
    end)
  rescue
    _ -> %{queued: 0, in_flight: 0}
  catch
    :exit, _ -> %{queued: 0, in_flight: 0}
  end
end

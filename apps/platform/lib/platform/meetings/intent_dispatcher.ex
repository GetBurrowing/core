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

  ## Per-meeting mute hold (task 019fbaac)

  `do_drain/2` answers `:muted` — without claiming — while
  `Platform.Meetings.intent_muted?/1` is true for the meeting. Every
  wake-up path funnels through that one function, so the hold covers
  the notify, the tick and the explicit `drain/2` call alike. The
  classifier is where mute actually stops work (no model call, no row);
  this hold only stops a backlog classified in the seconds BEFORE the
  toggle from firing afterwards. It cancels nothing.

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
  | `:no_target_role`   | no role, or an intent that reaches nobody      |
  | `:unknown_role`     | role isn't in `Role.valid_keys/0`              |
  | `:no_assignee`      | role is valid but unassigned                   |
  | `:agent_not_found`  | assignment points at a deleted agent           |
  | `:no_runtime`       | agent exists but has no linked AgentRuntime    |
  | `:cannot_ack`       | runtime is linked but not authorized for `intent_ack` |

  `:no_target_role` covers BOTH shapes small talk arrives in. The
  classifier's own "nobody" is the STRING `"null"`, but the response
  schema demands a `target_role` on every answer, so an `off_topic`
  row routinely names a real role instead — usually `meeting_scribe`.
  `IntentRouting.unroutable_intent?/1` is therefore asked FIRST in
  `dispatch_row/3`: without it such a row resolves an agent, reaches
  `:dispatched`, and HOLDS the meeting's serial cursor for the whole
  ack window while a real ask behind it sits `:queued`. Both shapes
  land the one reason, so the red strip reads the same way for what
  is the same event (task 01a06637).

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

  ## Space resolution is not a dispatch failure

  Every dispatch names the meeting's own chat space
  (`meetings.chat_space_id`) so the funnel can put the target agent in a
  writable posture there before the signal goes out. That resolution is
  best-effort: a meeting id with no row behind it yields `nil`, the envelope
  omits `target_space_id`, and the row still transitions to `:dispatched`.

  It is deliberately NOT a member of the `dispatch_failure_reason` table
  above. That table is about **reachability** — every reason in it means "this
  intent can never reach anybody", which is why each one lands a red,
  X-able row. "The dispatch reached a runtime but named no space it could
  write to" is a writability problem, not a runtime outage, and folding it in
  would make the two look identical to whoever is triaging a red strip. The
  refusal is not lost either: it surfaces as a distinct outcome atom on
  `[:platform, :chat, :dispatch_auto_invite]`.

  ## A reachable runtime is not necessarily an ACK-capable one (task 01a08875 stage 2)

  Being reachable and being able to answer are different facts, and until
  this stage only the first was checked. `resolve_target/1`'s entire test is
  `agent.runtime_id != nil`, so a runtime whose `allowed_bundles` did not
  carry the bundle registering `intent_ack` was dispatched to anyway. It then
  tried to ack, `Platform.Federation.ToolAuthorization.authorize/2` refused
  it ABOVE `ToolSurface.execute/3`, and the refusal reached nobody: the MCP
  transport emits no log, no telemetry and no audit row for a
  not-in-allowed-bundles denial. The queue therefore heard nothing at all,
  held the meeting's SERIAL cursor for the whole `:awaiting_delivery` window
  (`ack_timeout_ms` × 2 — the shorter 90s `:awaiting_ack` phase only arms on
  first contact, and a refusal is not contact), and finally recorded a plain
  `:timed_out` / `:never_delivered` that is byte-identical to "the runtime was
  offline". A real ask spoken behind it sat `:queued` for that entire time.

  So the runtime is now asked, before dispatch, whether it may call
  `intent_ack` at all. A "no" is a `:dispatch_failed{:cannot_ack}` row
  recorded IMMEDIATELY — `:dispatch_failed` is in the queue's
  `@advancing_statuses`, so the cursor releases in the same transaction and
  the next intent goes out at once instead of ~180s later.

  It costs no extra runtime lookup: `resolve_target/1` already hands back the
  `%AgentRuntime{}` struct, so the bundle membership is read off something
  already in hand. It is not free, though — `authorize/2` also asks
  `Platform.Tenancy.external_user?/1`, which is one indexed `Repo.exists?` on
  `org_memberships`. One extra indexed existence check on a path that already
  performs two `Repo.get/2`s inline is the whole price.

  ### Two limits, deliberate — do not design them away

  1. **This is not a substitute for registering `intent_ack` in a bundle the
     target actually holds** (stage 1 of this task moved it into `meetings`).
     On its own, this check converts an invisible 180s stall into a visible
     red row; it does not make the intent answerable. The meeting still does
     not get what it asked for — it just finds out immediately, and the asks
     behind it are no longer punished for it.
  2. **It closes "provably cannot ack", never "didn't ack".** The only thing
     asked is a membership test against a struct already loaded. A runtime
     that holds the bundle and then goes silent — offline, wedged, crashed
     mid-spawn — is still resolved by the full ack timeout, exactly as
     before. That is the correct boundary: presence and liveness are not
     capability, and guessing at them here would trade a truthful late answer
     for a fast wrong one. Same trade, made for the same reason, as stage 4's
     `:no_runtime` (task 019f70b8): "a surface that cannot ack cannot honour
     it... the cost is real and deliberate."

  Because stage 1 moved `intent_ack` into `meetings`, and migration
  20260908150000 appended `meetings` to every `agent_runtimes` row
  unconditionally, this refusal should essentially never fire today. That is
  the intended state, not a reason the check is redundant: it is the guard for
  the NEXT capability gap, which is the class `fcb58cfa` left open when it
  fixed only the instance.

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
      agent_slug, runtime_id, dispatch_kind}`. `dispatch_kind` is
      `:runtime_attention` for the role path and `:responsibility` for
      the action-item fork below (it was `:native | :external`); the
      key survives because listeners match on it, and `runtime_id` is
      new — it is the topic the signal actually went to, and is nil on
      the responsibility path because there is no runtime involved.

  ## Responsibility fork (task 019fb90f-36e3 stage 1; generalised 2026-07-31)

  Some classified intents are NOT handed to a role's runtime.
  `Platform.Meetings.IntentRouting` maps each such intent to the
  responsibility that serves it, and `dispatch_row/3` forks on that
  BEFORE any role resolution: the row is marked `:dispatched` and a
  single global `{<event>, payload}` broadcast goes out for
  `Platform.Responsibilities.Router` to pick up. The fork lives here
  rather than in `IntentClassifier` on purpose — broadcasting at
  classify time would double-produce (the row would ALSO go out as
  runtime attention) and would lose both the meeting's serial cursor
  and the producer's cancel/correct control over the row.

  The roster started as a one-entry map inline in this module, with a
  comment requiring each addition to be argued per key. Rowan made that
  argument on 2026-07-31 — every classified intent should reach its
  responsibility with a prompt an operator can tune, rather than every
  intent but one sharing a single generic runtime envelope. The table
  moved to `IntentRouting` at the same time, because the topic and the
  event atom were being restated in three files and a disagreement
  between any two of them produces a dispatch nobody hears and a
  cursor held until the ack window expires.

  An intent with NO routing row still takes the runtime-attention path
  below. That is the ordinary case, not a gap.

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
  alias Platform.Federation.ToolAuthorization
  alias Platform.Meetings
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentRouting
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.IntentRuntimeAdapter
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Roles

  # 30 s belt-and-braces tick — the PubSub notify path handles the hot
  # case, the tick just recovers dropped notifies + dispatcher restarts.
  @default_tick_interval_ms 30_000

  # The roster of intents served by a RESPONSIBILITY rather than by a
  # role's runtime now lives in `Platform.Meetings.IntentRouting`, which
  # also owns the topic and the event atom each one travels on. It moved
  # out of this module when the second entry landed; see the
  # "Responsibility fork" section of the moduledoc for why.

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

  Returns `:dispatched`, `:busy`, `:empty`, or `:muted`. `server`
  defaults to the singleton's registered name; tests boot per-case
  instances under unique names and pass them here. A call to a
  dispatcher that isn't running answers `:empty` rather than exiting —
  callers use this as a nudge, not as a source of truth.

  `:muted` means the meeting's per-meeting intent mute is on (task
  019fbaac): nothing was claimed, every queued row is still `:queued`,
  and the next drain after an unmute picks up where this one stopped.
  It is deliberately distinct from `:empty` — "held" and "nothing to
  do" are different facts.
  """
  @spec drain(binary(), GenServer.server()) :: :dispatched | :busy | :empty | :muted
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

  # Per-meeting mute hold (task 019fbaac stage 2). Checked BEFORE
  # `claim_next/1` so a muted meeting never takes a row off its queue:
  # rows stay `:queued`, the serial cursor stays free, and nothing is
  # cancelled. This is not a second product — it is the completion of
  # "stop now" for rows the classifier had already banked in the seconds
  # before the click. Without it, muting mid-sentence still lets the
  # backlog fire, which is exactly what the toggle exists to prevent.
  #
  # No extra wake-up is needed after an unmute: the `:tick` reduce above
  # re-visits every live meeting, and the queue's own `:intent_enqueued`
  # notify covers the hot path.
  #
  # Rows already `:dispatched` or `:acked` are untouched — muting does
  # not cancel in flight work. The producer's per-row X already runs
  # `IntentQueue.cancel/3` under the `intent_cancelled` -> `cancel_honored`
  # contract, and auto-firing N cancels nobody asked for would race the
  # 90s ack window and manufacture `:cancelled_late` rows for work that
  # had already landed.
  defp do_drain(meeting_id, state) do
    if Meetings.intent_muted?(meeting_id) do
      {:muted, state}
    else
      claim_and_dispatch(meeting_id, state)
    end
  end

  defp claim_and_dispatch(meeting_id, state) do
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
    responsibility_key = responsibility_key_for(row.classified_intent)

    cond do
      # Asked FIRST, mirroring the order `IntentRouting.routable?/2`
      # already uses. An unroutable intent reaches nobody WHATEVER role
      # it names, and the classifier's response schema demands it name
      # one — so `off_topic` carrying a real `meeting_scribe` is an
      # ordinary output, not a contrived shape. Without this branch that
      # row resolves an agent, lands `:dispatched`, and holds the
      # meeting's serial cursor for the full ack window while the next
      # real ask sits `:queued` and nobody sees an error.
      # `:dispatch_failed` is an ADVANCING status, so failing here
      # releases the cursor immediately (task 01a06637).
      IntentRouting.unroutable_intent?(row.classified_intent) ->
        fail_dispatch(meeting_id, row, :no_target_role, state)

      # Checked BEFORE the target_role arms, deliberately: these rows
      # carry whatever role the cheap classifier guessed (usually
      # `meeting_scribe`), and resolving it would send a runtime
      # attention broadcast in ADDITION to the responsibility fire.
      not is_nil(responsibility_key) ->
        dispatch_to_responsibility(
          meeting_id,
          row,
          responsibility_key,
          dispatch_started_at,
          state
        )

      no_target_role?(target_role) ->
        fail_dispatch(meeting_id, row, :no_target_role, state)

      not valid_role_key?(target_role) ->
        state = log_unknown_role_once(target_role, meeting_id, state)
        fail_dispatch(meeting_id, row, :unknown_role, state)

      true ->
        resolve_and_dispatch(meeting_id, row, to_string(target_role), dispatch_started_at, state)
    end
  end

  # ── Responsibility fork (task 019fb90f-36e3 stage 1) ───────────────────────
  #
  # The one branch that does NOT resolve a runtime. The row is moved to
  # `:dispatched` — which arms the queue's 90s ack window AND keeps the
  # meeting's serial cursor HELD across the model round-trip, so two
  # utterances can never be reconciling one action-items canvas at the
  # same time — and then a single global broadcast hands the utterance
  # to `Platform.Responsibilities.Router`.
  #
  # The row is closed terminally by the responsibility handler's
  # `handle_output/3`. Between here and there, the queue server's ack
  # window (`@default_ack_timeout_ms 90_000`) is the safety net: a model
  # call that overruns it lands the row `:timed_out` and releases the
  # cursor. That is the same contract every runtime target already lives
  # under and is deliberately NOT extended for this path.
  defp dispatch_to_responsibility(meeting_id, row, responsibility_key, started_at, state) do
    # Stamped for honesty, not for routing: the broadcast is global and
    # the Router resolves the assignee itself. A nil here (role
    # unassigned) is not a failure — the Router's own no-assignee
    # handling owns that outcome, and failing the row for it would make
    # the queue lie about what happened.
    agent = safe_assignee_for(responsibility_key)

    attrs =
      case agent do
        %Agent{} = agent -> %{target_agent_id: agent.id, target_agent_slug: agent.slug}
        nil -> %{}
      end

    case IntentQueue.transition(meeting_id, row.id, :dispatched, attrs) do
      {:ok, dispatched_row} ->
        # NOT `:ok = ...`. `broadcast_intent/2` answers
        # `{:error, :unroutable_intent}` for an intent with no routing
        # row, and a hard match would turn a table inconsistency into a
        # crash of the ONE dispatcher process that serves every live
        # meeting. It is unreachable today — we only got here because
        # `responsibility_key_for/1` found a row, and the topic comes
        # off that same row — so this arm exists to bound the blast
        # radius of a future half-added intent, not because the case is
        # expected.
        case MeetingsPubSub.broadcast_intent(
               to_string(dispatched_row.classified_intent),
               intent_payload(meeting_id, dispatched_row)
             ) do
          :ok ->
            elapsed_ms = System.monotonic_time(:millisecond) - started_at

            emit_responsibility_dispatched_telemetry(
              meeting_id,
              dispatched_row,
              responsibility_key,
              agent,
              elapsed_ms
            )

            %{state | dispatched_count: state.dispatched_count + 1}

          {:error, :unroutable_intent} ->
            # Logged and left `:dispatched` on purpose. The row's ack
            # window is already armed and will land it `:timed_out` in
            # 90s, releasing the cursor — a legal transition the queue
            # already owns. Forcing `:dispatch_failed` from here would
            # mean inventing a new `dispatch_failure_reason` and
            # transitioning out of `:dispatched`, i.e. two new contracts
            # for a branch that is unreachable while this table and the
            # handlers agree.
            Logger.error(
              "[IntentDispatcher] responsibility fork found key=#{responsibility_key} for " <>
                "intent=#{inspect(dispatched_row.classified_intent)} but IntentRouting has no " <>
                "topic for it — the row is dispatched with nothing listening and will time out. " <>
                "Add the routing row or remove the key."
            )

            state
        end

      {:error, reason} ->
        Logger.debug(
          "[IntentDispatcher] could not mark dispatched (responsibility) — " <>
            "meeting=#{meeting_id} intent=#{row.id} key=#{responsibility_key} " <>
            "reason=#{inspect(reason)}"
        )

        state
    end
  end

  # Delegated to `Platform.Meetings.IntentRouting`, which is the single
  # declaration of intent -> {responsibility key, topic, event atom}.
  # Kept as a private wrapper rather than inlined so every call site in
  # this module keeps reading as a question about THIS dispatcher's
  # fork, and so the string/atom normalisation lives in one place.
  defp responsibility_key_for(intent), do: IntentRouting.responsibility_key(intent)

  # Everything the handler's context gatherer reads. Only `intent_id`,
  # `meeting_id` and `chunk_excerpt` are reliably non-nil; the rest come
  # off the room's transcript row, which mid-meeting may not exist yet.
  # Each is left nil rather than defaulted, because "we don't know the
  # space" and "the space is X" have to stay distinguishable downstream.
  #
  # Named `action_item_payload/2` until 2026-07-31 — the shape was never
  # action-item-specific and every intent responsibility reads the same
  # fields via `Platform.Meetings.IntentContext`.
  defp intent_payload(meeting_id, row) do
    transcript = safe_transcript_for_room(row.room_id)

    %{
      intent_id: row.id,
      meeting_id: meeting_id,
      room_id: row.room_id,
      space_id: transcript && transcript.space_id,
      transcript_id: transcript && transcript.id,
      chunk_excerpt: row.chunk_excerpt,
      classified_intent: row.classified_intent,
      confidence: row.confidence,
      speaker: speaker_for(transcript, row.chunk_excerpt)
    }
  end

  # Speaker attribution is recovered from the transcript rather than
  # read off the row, because the row has no speaker column. It cannot
  # be recovered by id either: `transcript_chunk_id` is
  # `segment[:id] || payload.transcript_id` (intent_classifier.ex) and
  # production segments — built by `normalize_segment/1` in
  # `MeetingAgentController` — carry no `id` at all, so that field is
  # the TRANSCRIPT id in practice and matching on it would silently
  # attribute every utterance to nobody.
  #
  # So we match on the text: `chunk_excerpt` is a 280-char prefix of the
  # segment's own text (`IntentClassifier.excerpt/1`), and we scan from
  # the newest segment backwards because a speaker can repeat a line.
  # No match → nil, which is honest: stage 2's window still carries the
  # speaker-attributed lines.
  defp speaker_for(nil, _excerpt), do: nil
  defp speaker_for(_transcript, excerpt) when excerpt in [nil, ""], do: nil

  defp speaker_for(transcript, excerpt) do
    (transcript.segments || [])
    |> Enum.reverse()
    |> Enum.find_value(fn segment ->
      text = segment_field(segment, "text", :text)

      if is_binary(text) and String.starts_with?(text, excerpt) do
        segment_field(segment, "speaker_name", :speaker_name) ||
          segment_field(segment, "speaker", :speaker)
      end
    end)
  end

  # Segments are `{:array, :map}` JSONB, so they come back
  # string-keyed from the database and atom-keyed from a test fixture
  # or an in-flight broadcast payload. Both spellings are read rather
  # than depending on either.
  defp segment_field(segment, string_key, atom_key) when is_map(segment),
    do: Map.get(segment, string_key) || Map.get(segment, atom_key)

  defp segment_field(_segment, _string_key, _atom_key), do: nil

  defp safe_assignee_for(responsibility_key) do
    Roles.assignee_for(responsibility_key)
  rescue
    DBConnection.OwnershipError -> nil
    Ecto.NoResultsError -> nil
  end

  defp safe_transcript_for_room(nil), do: nil

  defp safe_transcript_for_room(room_id) when is_binary(room_id) do
    Meetings.get_transcript_for_room(room_id)
  rescue
    DBConnection.OwnershipError -> nil
    Ecto.NoResultsError -> nil
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
        authorize_and_dispatch(meeting_id, row, agent, target, role_key, started_at, state)
    end
  end

  # The tool the dispatch contract is built on. A target that may not call
  # this name cannot honour an intent no matter how reachable it is, so the
  # membership test is the last gate before the row leaves the cursor.
  #
  # Not read from a shared constant because there is no shared constant to
  # read: `Platform.Federation.ToolSurface` registers tool names as literals
  # inside its per-bundle catalogue functions, and `ToolAuthorization`
  # authorizes by binary name. A typo here therefore fails CLOSED — an
  # unknown name is in no bundle and `authorize/2` denies it — which the
  # positive-control case in the test file is what catches.
  @ack_tool_name "intent_ack"

  # See "A reachable runtime is not necessarily an ACK-capable one" in the
  # moduledoc for why this exists, what it costs, and the two things it
  # deliberately does NOT do.
  #
  # Ordered AFTER `resolve_target/1` on purpose. The two failures are
  # genuinely different — `:no_runtime` means "no surface at all",
  # `:cannot_ack` means "a surface that is not allowed to answer" — and
  # whoever is triaging a red strip needs to be able to tell them apart, so
  # they are separate reasons rather than one merged "unreachable".
  defp authorize_and_dispatch(meeting_id, row, agent, target, role_key, started_at, state) do
    case safe_authorize_ack(target.runtime) do
      :ok ->
        send_dispatch(meeting_id, row, agent, target, role_key, started_at, state)

      {:error, :forbidden} ->
        # At :info, matching the `:no_runtime` branch above. Unlike the MCP
        # transport's silent denial, this one is on the record BEFORE any
        # time is spent waiting on it.
        Logger.info(
          "[IntentDispatcher] target cannot ack — meeting=#{meeting_id} " <>
            "role=#{role_key} agent=#{agent.slug} runtime=#{target.runtime_id} " <>
            "tool=#{@ack_tool_name}"
        )

        fail_dispatch(meeting_id, row, :cannot_ack, state)
    end
  end

  # `authorize/2` resolves the runtime profile and owner cap through Access,
  # which touches the DB — so this shares
  # the sandbox-gone hazard every other DB touch on this path is wrapped for.
  #
  # It fails OPEN, and that direction is deliberate: this gate refuses only
  # what it can PROVE cannot ack, and a check that could not complete has
  # proved nothing. Failing closed would mint `:cannot_ack` rows for a
  # database problem, which is precisely the misattribution this stage exists
  # to remove — the same bug wearing a new reason. A sandbox-gone run
  # dispatches exactly as it did before this gate existed.
  defp safe_authorize_ack(runtime) do
    ToolAuthorization.authorize(@ack_tool_name, runtime)
  rescue
    DBConnection.OwnershipError -> :ok
    Ecto.NoResultsError -> :ok
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
        #
        # The space is resolved HERE rather than inside the adapter because
        # this is the one frame holding `meeting_id` — the adapter reads a
        # queue row, and a queue row knows nothing about chat.
        :ok =
          IntentRuntimeAdapter.send_attention(
            dispatched_row,
            target,
            meeting_target_space_id(meeting_id)
          )

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

  # "The classifier produced no role", in both spellings it can arrive in.
  #
  # `is_nil/1` alone was DEAD CODE. The classifier never emits Elixir's
  # `nil`: `normalise_target_role/1` maps the prompt's JSON `null` onto
  # the STRING `"null"` (`IntentClassifier.no_target_role/0`) because
  # `target_role` is hashed into the dedupe key and has to be a binary.
  # So every `off_topic` row fell through to `not valid_role_key?/1` and
  # was recorded `:unknown_role` — which reads as "the model emitted a
  # role outside the enum", a model defect that is not occurring, and
  # which also spent the once-per-key log line on the single most common
  # value in the queue. `:no_target_role` is what this module's own
  # reason table and `IntentRouting`'s `off_topic` comment already
  # promise happens here (task 01a06575).
  #
  # `nil` stays in the set: `IntentQueue.enqueue/2` accepts a nil
  # `target_role` from any caller that is not the classifier, and that
  # row means the same thing.
  defp no_target_role?(nil), do: true
  defp no_target_role?(role) when is_binary(role), do: role == IntentClassifier.no_target_role()
  defp no_target_role?(role) when is_atom(role), do: no_target_role?(Atom.to_string(role))
  defp no_target_role?(_), do: false

  # Delegated to `IntentRouting.routable_role?/1` rather than asking
  # `Role.valid_keys/0` here. The countdown rail has to ask the same
  # question — see that function's docs — and a second copy of it in
  # this module is exactly how the two rails drift back apart.
  defp valid_role_key?(role), do: IntentRouting.routable_role?(role)

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

  # The space a meeting-intent dispatch names: the meeting's own chat space.
  # Resolving it is what lets `Platform.Federation.AttentionDispatch` put the
  # target agent in a writable posture there BEFORE the signal goes out.
  #
  # `nil` is a RESULT here, never a failure. A meeting id with no row behind it
  # (the queue is Registry-keyed and outlives nothing but itself, so this is a
  # real state) means the dispatch simply names no space: the envelope omits
  # the key, the funnel reports `:no_space_named`, the broadcast still goes
  # out, and the row still transitions to `:dispatched`. See
  # "Space resolution is not a dispatch failure" in the moduledoc for why this
  # must not be folded into `dispatch_failure_reason`.
  #
  # A dangling `chat_space_id` is deliberately NOT filtered out here: passing
  # the id through is what lets `DispatchMembership` answer `:space_not_found`
  # rather than `:no_space_named`. Checking the space's existence first would
  # collapse two operator situations into one atom — the exact defect this
  # task keeps refusing.
  defp meeting_target_space_id(meeting_id) do
    if Platform.UUID.valid?(meeting_id) do
      case Repo.get(Meeting, meeting_id) do
        %Meeting{chat_space_id: chat_space_id} -> chat_space_id
        nil -> nil
      end
    else
      nil
    end
  rescue
    # Same sandbox-ownership rescue every other lookup on this path carries:
    # the dispatcher is a singleton GenServer and tests hand it ids whose
    # ownership chain has gone away.
    DBConnection.OwnershipError -> nil
    Ecto.NoResultsError -> nil
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

  # Same event name as the runtime path so "how many intents went out"
  # stays one number, distinguished by `dispatch_kind`. `runtime_id` is
  # nil by construction — there is no runtime on this path — and
  # `target_role` carries whatever the classifier guessed, which the
  # fork deliberately ignored.
  defp emit_responsibility_dispatched_telemetry(meeting_id, row, key, agent, elapsed_ms) do
    :telemetry.execute(
      [:platform, :meetings, :intent_dispatched],
      %{count: 1, dispatch_ms: elapsed_ms},
      %{
        meeting_id: meeting_id,
        room_id: row.room_id,
        intent_id: row.id,
        target_role: row.target_role,
        intent: row.classified_intent,
        agent_id: agent && agent.id,
        agent_slug: agent && agent.slug,
        runtime_id: nil,
        responsibility_key: key,
        dispatch_kind: :responsibility
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

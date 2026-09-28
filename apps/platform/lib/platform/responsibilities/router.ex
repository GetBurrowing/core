defmodule Platform.Responsibilities.Router do
  @moduledoc """
  Runtime trigger router for declarative responsibilities (ADR-0041 M6).

  This GenServer is the runtime dispatch surface that pairs with
  `Platform.Responsibilities.Registry` (the boot-time owner of the
  responsibilities table). On `init/1` it walks the registry and
  partitions every enabled responsibility into four buckets by
  `trigger_kind`:

      %{
        cron:           [%Responsibility{}, ...],
        event_topics:   [%Responsibility{}, ...],
        chat_patterns:  [%Responsibility{}, ...],
        webhooks:       [%Responsibility{}, ...]
      }

  Each bucket gets a single `:info` log on boot with the row count so
  operators can confirm at a glance which trigger surfaces have any
  active responsibilities. Subsequent stages of M6 fill in the actual
  trigger handlers:

    * stage 2 — cron tick + shared `fire_trigger/3` pipeline,
    * stage 3 — `Phoenix.PubSub` subscriptions for event_topic + webhook,
    * stage 4 — `chat_pattern` matcher attached to the
      `[:platform, :chat, :message_posted]` telemetry as a SIBLING
      fan-out to `Platform.Chat.AttentionRouter` (NOT a new ingest
      path — chat remains the sole publisher),
    * stage 5 — `Platform.ExternalAgents.Dispatcher` integration.

  ## Coexistence with SystemEventScheduler

  The Router runs **alongside** `Platform.Agents.SystemEventScheduler`
  until M8 cuts over the historian event to a responsibility row. The
  schedulers do not share any state; both can be started/stopped
  independently via their respective `:start_*` flags.

  ## Boot safety

  If `Platform.Responsibilities.Registry` is not loaded (e.g. a stripped
  test build), the Router logs `[ResponsibilityRouter] registry not
  loaded, idling` and starts with empty buckets rather than crashing.
  An empty registry walk is also a valid steady state.

  ## Provider resolution (stage 6)

  When `fire_trigger/3` lands on an `:external` assignee, it dispatches
  via `Platform.ExternalAgents.Dispatcher.dispatch/3` and then calls
  `handle_output/3` on the per-feature provider module. The provider is
  resolved through the explicit registry in
  `Platform.Responsibilities.Providers` — `feature == "meetings"` maps to
  `Platform.Responsibilities.Providers.Meetings`. The handler is
  optional: an unresolved provider / missing `handle_output/3` logs
  `[ResponsibilityRouter] no output handler for <key>` and returns `:ok`
  rather than crashing. This keeps stage 6 a no-op for feature areas
  whose providers haven't grown a handler yet (e.g. M6-only deploys
  before M8 lands `meetings.summarize`).

  That log line used to be a single `Logger.info` covering three very
  different situations. Task 019f9b28 stage 2 split it by what
  `Providers.feature_provider/1` returns: `:error` (nothing registered —
  actionable, `:warning`), `{:retired, why}` (deliberate, `:debug`), and
  `{:ok, module}` that nonetheless fails the `handle_output/3` probe (a
  contract break in a module we ship — `:error` level).

  ## Quantum-vs-minimal decision (recorded)

  This module deliberately does **not** depend on `:quantum`. The
  existing `SystemEventScheduler` proves the 60s-tick pattern handles
  hour-granular cron just fine; stage 2 extends that to support full
  `{minute, hour, day, month, dow}` cron expressions in ~80 LOC. We
  revisit `:quantum` if and only if we cross either of these
  thresholds: more than 50 cron triggers, or sub-minute granularity.
  Neither is on the roadmap.

  ## Configuration

      config :platform, Platform.Responsibilities.Router,
        check_interval_ms: 60_000

  Boot flag: `:start_responsibility_router` (default `true`, set to
  `false` in `config/test.exs` so tests start per-case instances under
  their own DataCase sandbox).

  ## Public API

    * `start_link/1` — supervised start, registered as `__MODULE__`
      unless `:name` opt overrides.
    * `snapshot/1` — returns the bucketed registry snapshot for
      introspection (used by integration tests and an eventual
      health-check endpoint).
    * `dispatch/3` — stage 1 stub that logs and returns
      `{:error, :not_implemented_yet}`. Stage 2 fills this in.

  ## Fire outcomes (ADR-0046)

  `fire_trigger/2,3` returns `t:fire_outcome/0` —
  `{:ok, :dispatched} | {:ok, :unfilled} | {:ok, :placeholder} | {:ok, :no_measurement} | {:error, term()}`
  — so a caller can tell "nobody holds this responsibility" apart from
  "the dispatch died". ADR-0046 requires a per-step
  `not_applicable | complete | failed` and those two states used to be the
  same `:ok`.

  `fire/2` (key lookup) adds a fourth value on top of that union:
  `{:ok, :unknown_responsibility}` when no row is seeded for the key. It
  sits in the ok channel for the same reason `:unfilled` does — an
  unseeded key is a progressive-enhancement state, not a failure.
  `Platform.Responsibilities.outcome/1` maps the full four-value union
  onto the ADR's `complete | not_applicable | failed`.

  **Honesty limit, native path.** `Platform.Chat.AgentResponder.maybe_dispatch/1`
  returns `:ok` unconditionally because outside sync mode it wraps the work
  in `Task.start/1`. So `{:ok, :dispatched}` from a native/federated
  assignee means **the handoff was accepted**, never **the agent
  responded** — post-handoff native failure is still invisible. Do not
  over-trust the value on that path. See `fire_trigger/3` for the full
  contract.
  """

  use GenServer

  require Logger

  alias Platform.Chat.Message
  alias Platform.ExternalAgents.Dispatcher, as: ExternalDispatcher
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.{ContextGatherer, Cron, Providers, Responsibility}

  @typedoc """
  The outcomes `fire_trigger/3` distinguishes (ADR-0046).

    * `{:ok, :dispatched}` — an assignee was resolved and the dispatch was
      handed off (external: an HTTP response was parsed; native/federated:
      the signal was accepted). Maps to the ADR's `complete`.
    * `{:ok, :unfilled}` — no agent holds the responsibility. A normal,
      expected system state under the ADR-0041 progressive-enhancement
      contract, NOT a failure. Maps to the ADR's `not_applicable`.
    * `{:ok, :placeholder}` — the row declares
      `metadata["dispatch"] == "inert"`, i.e. it is registered but
      deliberately not dispatchable yet. Nothing was attempted, so this
      is `not_applicable`, not `failed`; it gets its own tag rather than
      reusing `:unfilled` because an assignee may well exist — what is
      missing is the handler's downstream half, not a role holder.
    * `{:ok, :no_measurement}` — the assignee is a native/federated agent
      and the provider's `build_prompt/1` refused with
      `{:no_measurement, reason}` (currently only
      `AgentsGoalHeartbeat`). `dispatch_native/6` skips the hand-off
      entirely rather than waking the runtime with a bare signal — there
      is nothing to do, not merely nothing to say, which is a stronger
      statement than the `:no_work` envelopes `@no_work_refusals`
      dispatches. Native-only: `dispatch_external/5` already aborts on
      any `{:error, _}` refusal, `:no_measurement` included.
    * `{:error, term()}` — an assignee existed and the dispatch died.
      Maps to the ADR's `failed`.

  `not_applicable` and `failed` must never be conflated
  (`docs/decisions/0046-design-and-architecture-phases-in-planning.md`), which
  is why the unfilled case lives in the ok channel with its own tag rather
  than sharing a bare `:ok` with success.
  """
  @type fire_outcome ::
          {:ok, :dispatched}
          | {:ok, :unfilled}
          | {:ok, :placeholder}
          | {:ok, :no_measurement}
          | {:error, term()}

  @default_check_interval_ms :timer.seconds(60)

  @trigger_kinds [:cron, :event_topic, :chat_pattern, :webhook]

  @pubsub Platform.PubSub

  # PubSub topic a writer of a responsibility row broadcasts
  # `{:responsibilities_changed, :cron}` on, so every node's Router
  # re-reads its cron bucket without a restart (task 01a0e882 stage 1).
  @changed_topic "responsibilities:changed"

  # Telemetry event the chat ingest publishes on every persisted message
  # (see `Platform.Chat.publish_message_posted/2`). The Router subscribes
  # to it as a SIBLING fan-out to `Platform.Chat.AttentionRouter`, not a
  # new ingest path — the chat module remains the sole publisher.
  @chat_message_posted_event [:platform, :chat, :message_posted]

  @typedoc "Bucketed snapshot of the registry by trigger kind."
  @type snapshot :: %{
          cron: [Responsibility.t()],
          event_topics: [Responsibility.t()],
          chat_patterns: [Responsibility.t()],
          webhooks: [Responsibility.t()]
        }

  @typedoc """
  Internal state. `cron_next_fire` is a `%{responsibility_id =>
  DateTime.t()}` cache the tick loop walks each cycle. `cron_last_fire`
  is a `%{responsibility_id => DateTime.t()}` debounce so a slow tick
  can't re-fire the same minute twice (mirrors
  `SystemEventScheduler.fired_today?/2` keyed at minute granularity).
  """
  @type state :: %{
          check_interval_ms: pos_integer(),
          registry_snapshot: [Responsibility.t()],
          by_trigger: snapshot(),
          cron_next_fire: %{binary() => DateTime.t()},
          cron_last_fire: %{binary() => DateTime.t()},
          subscribed_topics: MapSet.t(binary()),
          compiled_chat_patterns: [{Regex.t(), Responsibility.t()}],
          chat_telemetry_handler_id: binary(),
          now_fn: (-> DateTime.t())
        }

  # ── start_link / init ──────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    config = Application.get_env(:platform, __MODULE__, [])

    check_interval_ms =
      Keyword.get(
        opts,
        :check_interval_ms,
        Keyword.get(config, :check_interval_ms, @default_check_interval_ms)
      )

    # Clock seam (task 01a0e882 stage 1). Every read of "now" on the cron
    # path goes through this fun, so a test can drive simulated time; see
    # the `{:tick_at, now}` clause.
    now_fn = Keyword.get(opts, :now_fn, &DateTime.utc_now/0)

    {snapshot, by_trigger} = walk_registry()

    cron_next_fire = compute_initial_cron_schedule(by_trigger.cron, now_fn.())

    :ok = Phoenix.PubSub.subscribe(@pubsub, @changed_topic)

    subscribed_topics = subscribe_event_topics(by_trigger.event_topics)

    compiled_chat_patterns = compile_chat_patterns(by_trigger.chat_patterns)

    chat_telemetry_handler_id =
      "platform-responsibility-router-chat-#{System.unique_integer([:positive])}"

    attach_chat_telemetry(chat_telemetry_handler_id, self())

    schedule_check(check_interval_ms)

    Logger.info(
      "[ResponsibilityRouter] started (interval=#{check_interval_ms}ms, " <>
        "buckets cron=#{length(by_trigger.cron)} " <>
        "event_topics=#{length(by_trigger.event_topics)} " <>
        "chat_patterns=#{length(by_trigger.chat_patterns)} " <>
        "webhooks=#{length(by_trigger.webhooks)}, " <>
        "compiled_chat_patterns=#{length(compiled_chat_patterns)})"
    )

    state = %{
      check_interval_ms: check_interval_ms,
      registry_snapshot: snapshot,
      by_trigger: by_trigger,
      cron_next_fire: cron_next_fire,
      cron_last_fire: %{},
      subscribed_topics: subscribed_topics,
      compiled_chat_patterns: compiled_chat_patterns,
      chat_telemetry_handler_id: chat_telemetry_handler_id,
      now_fn: now_fn
    }

    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, %{chat_telemetry_handler_id: handler_id})
      when is_binary(handler_id) do
    detach_chat_telemetry(handler_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── public API ────────────────────────────────────────────────────────────

  @doc """
  Return the bucketed registry snapshot.

  Used by integration tests and the (future) health-check endpoint to
  confirm the Router walked the registry as expected. Stage 1 surfaces
  only the static boot snapshot — stage 4+ may add live mutators.
  """
  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc """
  Re-read the enabled cron rows and replace the Router's cron bucket,
  without a restart. Synchronous: returns `:ok` once the new bucket is
  in place, so a caller can use it as a barrier.

  Performs the same reload as a `{:responsibilities_changed, :cron}`
  broadcast on `changed_topic/0`. A row whose `trigger_config` is
  unchanged keeps its pending next fire; a new or changed row is
  rescheduled from now; a row no longer returned (disabled, deleted,
  or moved off cron) leaves the bucket and the schedule. The per-row
  `cron_last_fire` debounce is carried forward untouched.
  """
  @spec reload_cron(GenServer.server()) :: :ok
  def reload_cron(server \\ __MODULE__), do: GenServer.call(server, :reload_cron)

  @doc "PubSub topic that carries `{:responsibilities_changed, :cron}`."
  @spec changed_topic() :: binary()
  def changed_topic, do: @changed_topic

  @doc """
  Dispatch a fired trigger to the responsibility's assignee.

  **Stage 1 stub.** Logs the dispatch attempt and returns
  `{:error, :not_implemented_yet}`. Stage 2 replaces the body with the
  full role-resolution + context-gather + LLM-call pipeline.

  Kept as the public entry point now so the cron/event/chat handlers
  added in subsequent stages can all funnel through one canonical
  function without churn.
  """
  @spec dispatch(Responsibility.t(), map()) ::
          :ok | {:error, :not_implemented_yet | term()}
  def dispatch(%Responsibility{} = responsibility, trigger_meta)
      when is_map(trigger_meta) do
    Logger.info(
      "[ResponsibilityRouter] dispatch stub key=#{responsibility.key} " <>
        "trigger=#{inspect(Map.get(trigger_meta, :kind))}"
    )

    {:error, :not_implemented_yet}
  end

  @doc """
  Lookup-and-fire convenience used by M8's dual-write shim and any
  call site that knows the responsibility key but doesn't already
  hold the `%Responsibility{}` row.

  Accepts the canonical string key (`"memory.daily_summary"`) or the
  atom shorthand (`:memory_daily_summary`) — the atom form is
  underscored and re-canonicalised to dotted-string by replacing the
  first underscore (`memory_daily_summary` → `memory.daily_summary`).

  ## Return contract

  A matched row returns `t:fire_outcome/0` verbatim from
  `fire_trigger/2`. A key with no seeded row logs and returns
  `{:ok, :unknown_responsibility}` rather than crashing; the dual-write
  shim treats this as "router path no-op" so legacy dispatch isn't
  blocked.

  WHY `{:ok, :unknown_responsibility}` AND NOT AN ERROR (ADR-0046
  member 1, stage 2): an unseeded key is a progressive-enhancement
  state, identical in kind to an unfilled assignee — a code site hooked
  the key before its seed migration landed. Reporting it through the
  error channel would make `Platform.Responsibilities.outcome/1` map it
  to `:failed`, i.e. ADR-0046 would report a failed step for a
  responsibility nobody ever configured. That is exactly the
  `not_applicable` / `failed` conflation
  `docs/decisions/0046-design-and-architecture-phases-in-planning.md:79-83`
  forbids. It was `{:error, :unknown_responsibility}` until stage 2 of
  that task.

  The supplied `trigger_meta` is passed through to `fire_trigger/2`
  verbatim; callers should set `:kind` (e.g. `:cron`, `:webhook`) and
  any feature-specific keys (`:workspace_id`, `:date`, etc.).
  """
  @spec fire(atom() | binary(), map()) :: fire_outcome() | {:ok, :unknown_responsibility}
  def fire(key, trigger_meta \\ %{}) when is_map(trigger_meta) do
    canonical = canonical_key(key)

    case lookup_by_key(canonical) do
      %Responsibility{} = responsibility ->
        fire_trigger(responsibility, trigger_meta)

      nil ->
        Logger.info(
          "[ResponsibilityRouter] fire/2 no row for key=#{inspect(canonical)} — skipping"
        )

        {:ok, :unknown_responsibility}
    end
  end

  @doc """
  Return `true` when the responsibility identified by `key` has a
  resolvable assignee — either a `ResponsibilityOverride` row or a
  `Role`-bundle assignment with an agent attached.

  M8 stage 4's dual-write bridge inside
  `Platform.Meetings.Summarizer.run_summary/1` gates on this: when
  the Meeting Scribe role is held by an agent, the legacy LLM path
  delegates to the router; otherwise it falls back to its existing
  body.

  Accepts the same atom / dotted-string shorthand as `fire/2`. Unknown
  keys, missing `Platform.Roles`, and resolver raises all degrade to
  `false` so the caller's "is anyone home?" check never crashes the
  legacy path.
  """
  @spec responsibility_filled?(atom() | binary()) :: boolean()
  def responsibility_filled?(key) when is_atom(key) or is_binary(key) do
    canonical = canonical_key(key)
    not is_nil(safe_assignee_for(canonical))
  end

  def responsibility_filled?(_), do: false

  defp canonical_key(key) when is_binary(key), do: key

  defp canonical_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.replace("_", ".", global: false)
  end

  defp lookup_by_key(key) when is_binary(key) do
    if Code.ensure_loaded?(Responsibilities) and
         function_exported?(Responsibilities, :get_by_key, 1) do
      Responsibilities.get_by_key(key)
    else
      nil
    end
  rescue
    _ -> nil
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, state.by_trigger, state}
  end

  def handle_call(:reload_cron, _from, state) do
    {:reply, :ok, reload_cron_bucket(state)}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = run_cron_tick(state, state.now_fn.())
    schedule_check(state.check_interval_ms)
    {:noreply, state}
  end

  # Simulated-time tick: the SAME reduce as `:tick` at the supplied
  # instant, without re-arming the timer, so a test can step the cron
  # schedule minute by minute with no sleeps.
  def handle_info({:tick_at, %DateTime{} = now}, state) do
    {:noreply, run_cron_tick(state, now)}
  end

  # Cron reload broadcast on `@changed_topic`.
  #
  # CLAUSE ORDER IS LOAD-BEARING: this MUST stay above the generic
  # `{event, payload} when is_atom(event)` clause below. That clause
  # matches this message too, would hand it to `fire_event_match/3` as an
  # event named "responsibilities_changed", and the reload would silently
  # never happen.
  def handle_info({:responsibilities_changed, :cron}, state) do
    {:noreply, reload_cron_bucket(state)}
  end

  # Chat ingest fan-out: a sibling subscriber to AttentionRouter. The
  # telemetry handler (a private fn attached via `attach_chat_telemetry/2`)
  # forwards every `[:platform, :chat, :message_posted]` event into this
  # GenServer mailbox so the actual matching work happens on our process,
  # NOT on the publisher's. Mirrors `AttentionRouter`'s telemetry-to-info
  # pattern so we don't double-load the publisher when both subscribers
  # are running.
  #
  # NOTE: this clause MUST stay above the generic `{topic, payload}` PubSub
  # clauses below — both clauses match a 2-tuple-with-atom-head, so the
  # first one wins. Otherwise the PubSub clause would silently swallow our
  # telemetry forward (checking `MapSet.member?(subscribed_topics, "…")`
  # → false → no-op) and chat_pattern firing would just not happen.
  @impl GenServer
  def handle_info({:telemetry_chat_message_posted, metadata}, state) do
    handle_chat_message_posted(metadata, state)
    {:noreply, state}
  end

  # Topic-as-head envelope: `{topic_string, payload}`. No publisher in
  # this codebase currently emits this shape — the clause is retained
  # for any future publisher that wants to name its topic in the
  # message — so only fan out if the topic was actually subscribed at
  # boot, otherwise the message belongs to someone else who happens to
  # share our process tree.
  @impl GenServer
  def handle_info({topic, payload}, state)
      when is_binary(topic) do
    if MapSet.member?(state.subscribed_topics, topic) do
      fire_event_topic(topic, payload, state)
    end

    {:noreply, state}
  end

  # Event-as-head envelope: `{:some_event, payload}`. This is what every
  # real publisher in the app emits (`Platform.Meetings.PubSub`,
  # `Platform.Org.Wiki`, …). Phoenix.PubSub does NOT deliver the topic
  # alongside the message, so the atom here is the EVENT NAME, never the
  # topic — matching it against `subscribed_topics` (as this clause used
  # to) compares `:meeting_finished` to `"meeting:finished"` and can
  # never succeed. Route on the responsibility's declared
  # `trigger_config["event_match"]` instead; see `config_event_match/1`.
  @impl GenServer
  def handle_info({event, payload}, state) when is_atom(event) and not is_nil(event) do
    fire_event_match(Atom.to_string(event), payload, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  # Webhook ingress: thin GenServer cast so the HTTP controller can
  # nudge the Router without coupling to PubSub. The lookup matches
  # against the webhook responsibility's `trigger_config["path"]`
  # (the canonical key per the M1 schema validator).
  @impl GenServer
  def handle_cast({:webhook_fire, webhook_path, payload}, state)
      when is_binary(webhook_path) do
    matches =
      Enum.filter(state.by_trigger.webhooks, fn responsibility ->
        config_path(responsibility) == webhook_path
      end)

    case matches do
      [] ->
        Logger.info(
          "[ResponsibilityRouter] webhook fired with no matching responsibility " <>
            "path=#{webhook_path}"
        )

      list ->
        Enum.each(list, fn responsibility ->
          fire_trigger(
            responsibility,
            %{kind: :webhook, path: webhook_path, payload: payload},
            state
          )
        end)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  # ── internals ─────────────────────────────────────────────────────────────

  defp schedule_check(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  # ── Event-topic subscriptions ─────────────────────────────────────────────
  #
  # On boot we subscribe to every distinct topic declared by an enabled
  # event_topic responsibility. We dedupe so two responsibilities sharing
  # a topic only result in one Phoenix.PubSub subscription (the
  # fan-out happens in our handle_info, not in PubSub).

  defp subscribe_event_topics(event_rows) do
    event_rows
    |> Enum.map(&config_topic/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(MapSet.new(), fn topic, acc ->
      case Phoenix.PubSub.subscribe(@pubsub, topic) do
        :ok ->
          MapSet.put(acc, topic)

        {:error, reason} ->
          Logger.warning(
            "[ResponsibilityRouter] PubSub.subscribe failed topic=#{topic} " <>
              "reason=#{inspect(reason)}"
          )

          acc
      end
    end)
  end

  # Look up event-topic responsibilities whose configured topic matches
  # the inbound broadcast topic and fire each one with the payload
  # carried as trigger_meta (the Provider's gather_context/2 reads it
  # from there).
  defp fire_event_topic(topic, payload, state) when is_binary(topic) do
    state.by_trigger.event_topics
    |> Enum.filter(&(config_topic(&1) == topic))
    |> fire_matches(payload, state)
  end

  # Look up event-topic responsibilities whose declared `event_match`
  # equals the inbound event name.
  #
  # The `subscribed_topics` conjunct is load-bearing, not belt-and-
  # braces: it preserves the guarantee that we only ever fire for topics
  # we actually subscribed at boot. Without it, an atom-headed message
  # that merely happens to reach our mailbox (we share a process tree,
  # and the chat telemetry forward already sends us one) could fire a
  # responsibility subscribed to a completely different topic.
  defp fire_event_match(event_name, payload, state) when is_binary(event_name) do
    state.by_trigger.event_topics
    |> Enum.filter(fn responsibility ->
      config_event_match(responsibility) == event_name and
        MapSet.member?(state.subscribed_topics, config_topic(responsibility))
    end)
    |> fire_matches(payload, state)
  end

  # Shared fan-out for both delivery envelopes. `topic` in trigger_meta
  # is always the topic the responsibility DECLARED, which for the
  # topic-as-head path is by construction the delivery topic too.
  defp fire_matches(matches, payload, state) when is_list(matches) do
    Enum.each(matches, fn responsibility ->
      fire_trigger(
        responsibility,
        %{kind: :event_topic, topic: config_topic(responsibility), payload: payload},
        state
      )
    end)
  end

  defp config_topic(%Responsibility{trigger_config: config}) do
    Map.get(config, "topic") || Map.get(config, :topic)
  end

  # The event-name half of the event_topic delivery contract: the atom
  # a publisher puts at the head of its `{event, payload}` message,
  # spelled as a string (e.g. `"meeting_finished"` for
  # `Platform.Meetings.PubSub.broadcast_meeting_finished/2`).
  #
  # AMBIGUITY, deliberately accepted here and constrained elsewhere:
  # because Phoenix.PubSub withholds the topic on delivery, we cannot
  # tell which subscription a message arrived through. Two
  # responsibilities on DIFFERENT topics that declare the SAME
  # `event_match` will therefore both fire on either broadcast. Same-
  # topic sharing is correct fan-in (three `meetings.*` rows share
  # `meeting_finished` on `meeting:finished`); cross-topic sharing is a
  # declaration bug, and is forbidden by an assertion in
  # `test/platform/responsibilities/event_topic_delivery_test.exs`.
  defp config_event_match(%Responsibility{trigger_config: config}) do
    Map.get(config, "event_match") || Map.get(config, :event_match)
  end

  defp config_path(%Responsibility{trigger_config: config}) do
    Map.get(config, "path") || Map.get(config, :path)
  end

  # ── Cron firing ───────────────────────────────────────────────────────────

  # One cron pass over the current bucket at `now`. Shared by `:tick` and
  # `{:tick_at, now}` so the real and simulated clocks cannot drift.
  defp run_cron_tick(state, %DateTime{} = now) do
    {new_next, new_last} =
      Enum.reduce(
        state.by_trigger.cron,
        {state.cron_next_fire, state.cron_last_fire},
        fn responsibility, {next_acc, last_acc} ->
          maybe_fire_cron(responsibility, now, next_acc, last_acc)
        end
      )

    %{state | cron_next_fire: new_next, cron_last_fire: new_last}
  end

  defp maybe_fire_cron(%Responsibility{id: id} = responsibility, now, next_acc, last_acc) do
    next = Map.get(next_acc, id)

    cond do
      is_nil(next) ->
        case compute_next_fire(responsibility, now) do
          {:ok, dt} -> {Map.put(next_acc, id, dt), last_acc}
          :error -> {next_acc, last_acc}
        end

      DateTime.compare(now, next) == :lt ->
        # Not yet due.
        {next_acc, last_acc}

      fired_this_minute?(responsibility, now, last_acc) ->
        # Debounce: don't refire within the same minute window.
        case compute_next_fire(responsibility, now) do
          {:ok, dt} -> {Map.put(next_acc, id, dt), last_acc}
          :error -> {Map.delete(next_acc, id), last_acc}
        end

      true ->
        # Counting seam (task 01a0e882 stage 1): one event per cron fire
        # that reaches `fire_trigger/2`. Deliberately NOT registered with
        # `Platform.Audit.TelemetryHandler`.
        :telemetry.execute(
          [:platform, :responsibility, :cron_fired],
          %{count: 1},
          %{key: responsibility.key, responsibility_id: id, fired_at: now}
        )

        fire_trigger(responsibility, %{kind: :cron, fired_at: now})

        next_acc =
          case compute_next_fire(responsibility, now) do
            {:ok, dt} -> Map.put(next_acc, id, dt)
            :error -> Map.delete(next_acc, id)
          end

        {next_acc, Map.put(last_acc, id, now)}
    end
  end

  # Replace the cron bucket with a fresh read. Unchanged rows (same
  # `trigger_config`) keep their `cron_next_fire` entry, so a pending fire
  # is not pushed to the next slot; new or changed rows are rescheduled
  # from `state.now_fn`. `Cron.next_fire_after/3` starts at the NEXT
  # minute boundary, so a recompute cannot return the minute that just
  # fired. Ids no longer returned drop out of `cron_next_fire`;
  # `cron_last_fire` is carried forward as-is so the debounce survives.
  #
  # A read that raises keeps the current bucket: unlike boot, a failed
  # reload must not read as "no cron rows" and silence every schedule.
  defp reload_cron_bucket(state) do
    case read_cron_rows() do
      {:ok, rows} -> apply_cron_reload(state, rows)
      :error -> state
    end
  end

  defp read_cron_rows do
    {:ok, Responsibilities.get_by_trigger(:cron)}
  rescue
    error ->
      Logger.warning(
        "[ResponsibilityRouter] cron reload read failed, keeping current bucket: " <>
          Exception.message(error)
      )

      :error
  end

  defp apply_cron_reload(state, rows) do
    now = state.now_fn.()
    old_rows = state.by_trigger.cron
    old_by_id = Map.new(old_rows, &{&1.id, &1})

    next_fire =
      Enum.reduce(rows, %{}, fn %Responsibility{id: id} = row, acc ->
        kept = Map.get(state.cron_next_fire, id)

        case Map.get(old_by_id, id) do
          %Responsibility{trigger_config: config}
          when config == row.trigger_config and kept != nil ->
            Map.put(acc, id, kept)

          _ ->
            case compute_next_fire(row, now) do
              {:ok, dt} -> Map.put(acc, id, dt)
              :error -> acc
            end
        end
      end)

    old_ids = MapSet.new(Map.keys(old_by_id))

    registry_snapshot =
      Enum.reject(state.registry_snapshot, &MapSet.member?(old_ids, &1.id)) ++ rows

    Logger.info("[ResponsibilityRouter] cron reload: #{length(old_rows)} -> #{length(rows)} rows")

    %{
      state
      | by_trigger: %{state.by_trigger | cron: rows},
        registry_snapshot: registry_snapshot,
        cron_next_fire: next_fire
    }
  end

  # Mirrors `SystemEventScheduler.recently_fired?/4` but keyed at minute
  # granularity — cron grammar's smallest unit is one minute, so we
  # never want to fire the same row twice for the same minute boundary.
  defp fired_this_minute?(%Responsibility{id: id}, %DateTime{} = now, last_acc) do
    case Map.get(last_acc, id) do
      nil -> false
      %DateTime{} = last -> DateTime.diff(now, last, :second) < 60
    end
  end

  defp compute_initial_cron_schedule(cron_rows, %DateTime{} = now) do
    Enum.reduce(cron_rows, %{}, fn responsibility, acc ->
      case compute_next_fire(responsibility, now) do
        {:ok, dt} -> Map.put(acc, responsibility.id, dt)
        :error -> acc
      end
    end)
  end

  defp compute_next_fire(%Responsibility{trigger_config: config, key: key}, %DateTime{} = now) do
    expression = Map.get(config, "expression") || Map.get(config, :expression)
    # Optional named IANA timezone (e.g. "America/Chicago"). Unknown /
    # missing / non-binary values are silently ignored so a corrupted
    # row can't crash the tick — Cron.next_fire_after treats `nil` and
    # UTC aliases identically. Task 019f70e9 stage 6.
    timezone = Map.get(config, "timezone") || Map.get(config, :timezone)
    opts = if is_binary(timezone), do: [timezone: timezone], else: []

    if is_binary(expression) do
      with {:ok, spec} <- Cron.parse(expression),
           {:ok, dt} <- Cron.next_fire_after(now, spec, opts) do
        {:ok, dt}
      else
        other ->
          Logger.warning(
            "[ResponsibilityRouter] cron schedule failed key=#{key} expr=#{inspect(expression)} reason=#{inspect(other)}"
          )

          :error
      end
    else
      Logger.warning(
        "[ResponsibilityRouter] cron schedule missing/non-binary expression key=#{key} expr=#{inspect(expression)}"
      )

      :error
    end
  end

  # ── Chat-pattern triggers ─────────────────────────────────────────────────
  #
  # The chat ingest publishes `[:platform, :chat, :message_posted]` once
  # per persisted Message. We subscribe ALONGSIDE
  # `Platform.Chat.AttentionRouter` (the canonical fan-out) and fire any
  # chat_pattern responsibility whose compiled regex matches the message
  # content. Filter rules (planner-specified):
  #
  #   * agent-authored messages are skipped to avoid feedback loops
  #   * `kind: "system"` spaces are skipped (system_events spaces don't
  #     drive product-level pattern responsibilities)
  #   * each pattern fires AT MOST ONCE per message even if the regex
  #     matches multiple times in the content
  #
  # Patterns are compiled at boot via `Regex.compile/2`. An invalid
  # pattern logs a warning and is dropped from the cache; the row still
  # appears in the snapshot bucket (so operators can see it) but it
  # won't fire until the responsibility is updated and the Router
  # restarts. That matches the planner's "reject + log, don't crash"
  # contract.

  defp compile_chat_patterns(chat_pattern_rows) do
    Enum.flat_map(chat_pattern_rows, fn %Responsibility{} = responsibility ->
      pattern = config_chat_pattern(responsibility)

      case compile_chat_pattern_string(pattern) do
        {:ok, regex} ->
          [{regex, responsibility}]

        {:error, reason} ->
          Logger.warning(
            "[ResponsibilityRouter] dropping chat_pattern responsibility " <>
              "key=#{responsibility.key} reason=#{inspect(reason)} pattern=#{inspect(pattern)}"
          )

          []
      end
    end)
  end

  defp compile_chat_pattern_string(pattern) when is_binary(pattern) and pattern != "" do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compile_chat_pattern_string(_), do: {:error, :missing_or_non_binary_pattern}

  # M1's chat_pattern schema validator (see
  # `Platform.Responsibilities.Responsibility.validate_trigger_config_for_kind/3`)
  # canonicalises the field as `"regex"`. We accept the `"pattern"`
  # alias as a forward-compat hedge in case the schema is renamed; if
  # both are present `"regex"` wins because that's what the validator
  # actually persists.
  defp config_chat_pattern(%Responsibility{trigger_config: config}) do
    Map.get(config, "regex") || Map.get(config, :regex) ||
      Map.get(config, "pattern") || Map.get(config, :pattern)
  end

  defp attach_chat_telemetry(handler_id, router_pid)
       when is_binary(handler_id) and is_pid(router_pid) do
    :telemetry.attach(
      handler_id,
      @chat_message_posted_event,
      &__MODULE__.handle_chat_telemetry/4,
      %{router_pid: router_pid}
    )
  end

  defp detach_chat_telemetry(handler_id) when is_binary(handler_id) do
    :telemetry.detach(handler_id)
  rescue
    _ -> :ok
  end

  @doc false
  # Telemetry callback — runs on the publishing process. Keep it tiny:
  # forward to the router GenServer so all DB / matching work happens on
  # our own process. Mirrors `Platform.Chat.AttentionRouter`'s pattern.
  def handle_chat_telemetry(
        @chat_message_posted_event,
        _measurements,
        metadata,
        %{router_pid: pid}
      )
      when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, {:telemetry_chat_message_posted, metadata})
    end

    :ok
  rescue
    error ->
      Logger.error(
        "[ResponsibilityRouter] chat telemetry handler crashed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  def handle_chat_telemetry(_event, _measurements, _metadata, _config), do: :ok

  # ── Message ingest + filter + match ───────────────────────────────────────

  defp handle_chat_message_posted(_metadata, %{compiled_chat_patterns: []}) do
    # Hot-path short circuit: no patterns means no work, regardless of
    # how chatty the space is. Doubles as a guard against the
    # `Code.ensure_loaded?(Platform.Chat)` lookup below in stripped
    # builds.
    :ok
  end

  defp handle_chat_message_posted(metadata, state)
       when is_map(metadata) do
    message_id = Map.get(metadata, :message_id) || Map.get(metadata, "message_id")

    if is_binary(message_id) do
      try do
        case load_message_with_space_kind(message_id) do
          {:ok, %Message{} = message, space_kind} ->
            maybe_fire_chat_patterns(message, space_kind, state)

          {:error, :not_found} ->
            Logger.debug(
              "[ResponsibilityRouter] chat_pattern: message not found id=#{message_id}"
            )

            :ok

          {:error, reason} ->
            Logger.debug(
              "[ResponsibilityRouter] chat_pattern: load failed id=#{message_id} reason=#{inspect(reason)}"
            )

            :ok
        end
      rescue
        error ->
          Logger.debug(
            "[ResponsibilityRouter] chat_pattern: handler raised " <>
              "(#{Exception.message(error)})"
          )

          :ok
      catch
        :exit, reason ->
          Logger.debug("[ResponsibilityRouter] chat_pattern: handler exited (#{inspect(reason)})")

          :ok
      end
    else
      :ok
    end
  end

  defp handle_chat_message_posted(_metadata, _state), do: :ok

  defp load_message_with_space_kind(message_id) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      %Message{space_id: space_id} = message when is_binary(space_id) ->
        space_kind =
          case Repo.get(Platform.Chat.Space, space_id) do
            %Platform.Chat.Space{kind: kind} -> kind
            _ -> nil
          end

        {:ok, message, space_kind}

      %Message{} ->
        {:error, :missing_space_id}
    end
  end

  defp maybe_fire_chat_patterns(%Message{} = message, space_kind, state) do
    cond do
      message.author_participant_type == "agent" ->
        # Feedback-loop guard — agent-authored messages never trigger
        # chat_pattern responsibilities, otherwise an agent that echoes
        # its own prompt could thrash the dispatch pipeline.
        :ok

      space_kind == "system" ->
        # System spaces are operator-only event logs; pattern
        # responsibilities are for product spaces.
        :ok

      Platform.Chat.AttentionRouter.untrusted_inbound?(message) ->
        # Inbound email (task 01a0cf21 stage 3) and a peer install's
        # shared-space message (task 01a0d90f stage 5) are untrusted outside
        # text: a pattern in them must not fire a responsibility dispatch,
        # any more than it may route an agent.
        :ok

      not is_binary(message.content) or message.content == "" ->
        :ok

      true ->
        fire_matching_chat_patterns(message, state)
    end
  end

  defp fire_matching_chat_patterns(%Message{content: content} = message, state) do
    Enum.each(state.compiled_chat_patterns, fn {regex, responsibility} ->
      if Regex.match?(regex, content) do
        captures = Regex.run(regex, content) || []

        trigger_meta = %{
          kind: :chat_pattern,
          message_id: message.id,
          space_id: message.space_id,
          match: captures
        }

        fire_trigger(responsibility, trigger_meta, state)
      end
    end)

    :ok
  end

  # ── Canonical fire pipeline ───────────────────────────────────────────────
  #
  # ALL trigger kinds (cron now; event_topic, chat_pattern, webhook in
  # later stages) funnel through `fire_trigger/3` so the
  # role-resolution → dispatch → stamp pipeline lives in exactly one
  # place. The function never raises: every failure mode is caught and
  # returned as `{:error, reason}`. An unfilled responsibility emits
  # telemetry + an info log and returns `{:ok, :unfilled}` — that is the
  # "progressive enhancement" contract from ADR-0041, an empty Roles
  # table is a perfectly valid system state, and it is deliberately a
  # DIFFERENT value from both success and failure.
  #
  # NON-RAISING IS LOAD-BEARING: `Platform.Tasks.fire_architecture_review_plan/1`
  # fires inside the plan-submit transition and
  # `Platform.Tasks.PlanEngine.after_stage_completed/1` fires inside
  # `evaluate_validation/2`'s Ecto transaction. A raise from here rolls back a
  # validation update. Return the error, never raise it.

  @doc """
  Fire a trigger through the canonical pipeline.

  Short-circuits FIRST on a declared-inert row — if
  `metadata["dispatch"] == "inert"` the fire is logged and skipped
  before any assignee lookup, returning `{:ok, :placeholder}`. See
  `dispatch_inert?/1` below for why the gate lives in this funnel, why
  it reads `metadata` rather than `enabled`, and why it is NOT keyed on
  `metadata["status"] == "placeholder"` (eleven rows carry that marker
  and seven of them fire today).

  Otherwise looks up the assignee via `Platform.Roles.assignee_for/1`,
  then:

    * if no agent is assigned → telemetry
      `[:platform, :responsibility, :unfilled]` + info log, returns
      `{:ok, :unfilled}`
    * if the agent is `kind == "external"` → gather context via the
      provider (falling back to `ContextGatherer.gather/2`), render the
      prompt, call `Platform.ExternalAgents.Dispatcher.dispatch/3`, hand
      the parsed response to the provider's `handle_output/3` (when
      present), stamp `last_successful_fire_at`, emit
      `[:platform, :responsibility, :fired]` telemetry, and return
      `{:ok, :dispatched}`.
    * if the agent is `kind == "native"` (alias: `"local"` /
      `"federated"`) → build the AgentResponder signal shape (mirrors
      `Platform.Agents.HistorianDispatcher`'s, carrying the rendered
      prompt under `metadata.prompt`) and hand off via
      `Platform.Chat.AgentResponder.maybe_dispatch/1`. On acceptance:
      stamp, emit `fired`, return `{:ok, :dispatched}`. The Router
      remains a drop-in dispatch surface for the existing native path —
      `SystemEventScheduler` keeps running alongside until M8 cuts the
      historian event over to a responsibility row.

  ## Return contract

  See `t:fire_outcome/0`. The three values are mutually exclusive and
  callers are expected to branch on them:

    * `{:ok, :dispatched}` — handed off
    * `{:ok, :unfilled}` — nobody holds the responsibility
    * `{:ok, :placeholder}` — the row is declared inert; nothing attempted
    * `{:error, reason}` — an assignee existed and the dispatch died

  Failure modes (HTTP error, contract violation, provider refusal, a
  raising native dispatcher, an unknown assignee shape, a caught exit)
  log, emit `[:platform, :responsibility, :failed]`, and return
  `{:error, reason}` — the Router never crashes the GenServer, and never
  raises, for a single fired trigger.

  ## Honesty limit on the native path (do not over-trust `:dispatched`)

  `Platform.Chat.AgentResponder.maybe_dispatch/1` returns `:ok`
  unconditionally: outside sync mode it wraps the real work in
  `Task.start/1`, so the return value is observed before the agent has
  done anything. Therefore `{:ok, :dispatched}` on the native/federated
  path means **the handoff was accepted**, never **the agent responded**.
  A native agent that fails after handoff is still invisible here. Making
  post-handoff native failure observable requires a completion signal from
  an artifact the agent produces (a canvas attach, a validation write) and
  is deliberately out of scope for this contract. The external path is
  stronger: it has actually parsed an HTTP response by the time it returns
  `{:ok, :dispatched}`.

  Called from `handle_info(:tick, …)` for cron triggers, and from the
  event_topic, chat_pattern, and webhook handlers. Public so tests
  can drive it directly without standing up a fully-populated cron
  schedule.
  """
  @spec fire_trigger(Responsibility.t(), map()) :: fire_outcome()
  def fire_trigger(%Responsibility{} = responsibility, trigger_meta) when is_map(trigger_meta) do
    fire_trigger(responsibility, trigger_meta, %{})
  end

  @spec fire_trigger(Responsibility.t(), map(), map()) :: fire_outcome()
  def fire_trigger(%Responsibility{} = responsibility, trigger_meta, _state)
      when is_map(trigger_meta) do
    if dispatch_inert?(responsibility) do
      Logger.info(
        "[ResponsibilityRouter] placeholder responsibility=#{responsibility.key} " <>
          "— declared inert (metadata.dispatch=inert), not dispatching"
      )

      {:ok, :placeholder}
    else
      do_fire_trigger(responsibility, trigger_meta)
    end
  end

  # A row that declares `metadata["dispatch"] == "inert"` is registered
  # but deliberately not dispatchable: its handler's downstream half
  # does not exist yet, so firing it would spend a model round-trip on
  # output nothing consumes. `Handlers.MeetingAttendanceFollowup` is
  # the first and currently only such row — see its moduledoc for the
  # argument.
  #
  # WHY THIS GATE IS HERE and not in each caller: the check sits above
  # assignee resolution in the ONE funnel every trigger kind passes
  # through, so an inert row stays inert on cron ticks, webhooks, chat
  # patterns, event_topic broadcasts, and direct `fire/2` calls alike —
  # there is no second path that forgets.
  #
  # WHY THE METADATA FIELD IS READ DIRECTLY: `metadata` is in
  # `Platform.Responsibilities.@upsert_replace_fields` while `enabled`
  # is deliberately NOT (it is operator territory, preserved across
  # upserts so admin-UI toggles survive redeploys). So a provider
  # declaring `enabled: false` in `register/0` would be a guaranteed
  # no-op against an existing production row, whereas a metadata
  # declaration propagates on the next boot's `upsert_by_key/1`.
  #
  # WHY `"dispatch"` AND NOT `metadata["status"] == "placeholder"`,
  # which is what task 019fa56b-c81f stage 4 originally specified:
  # eleven rows already carry `status: "placeholder"` and for them it
  # means "registered ahead of its own runtime, grep-able by an
  # operator" — NOT "never fire". Seven of them dispatch today
  # (`tasks.triage` and `tasks.weekly_review` on cron; `tasks.unblock`
  # and the three `design.*` keys on chat_pattern;
  # `meetings.intent_classify` on `meeting:transcript_chunk`, whose
  # delivery stage 1 of that same task had just repaired). Vetoing on
  # `status` would have silently re-broken all seven.
  # `Platform.Responsibilities.Reachability` (sibling task 019fa510)
  # reads the same field and is explicit about the distinction — it
  # names its output `declared_inert?` rather than `inert?` because it
  # reports what the row DECLARES. So inert rows keep
  # `status: "placeholder"` (earning `declared_inert_reason:
  # :placeholder_status` there for free) and additionally declare
  # `dispatch: "inert"`, which has exactly one meaning and exactly one
  # reader: this function. We do NOT call into Reachability — it is not
  # on `main`, and the Router must not take a runtime dependency on a
  # reporting surface.
  defp dispatch_inert?(%Responsibility{metadata: metadata}) when is_map(metadata) do
    (Map.get(metadata, "dispatch") || Map.get(metadata, :dispatch)) == "inert"
  end

  defp dispatch_inert?(%Responsibility{}), do: false

  defp do_fire_trigger(%Responsibility{} = responsibility, trigger_meta) do
    try do
      assignee = safe_assignee_for(responsibility.key)

      case assignee do
        nil ->
          Logger.info(
            "[ResponsibilityRouter] unfilled responsibility=#{responsibility.key} " <>
              "trigger=#{inspect(Map.get(trigger_meta, :kind))}"
          )

          :telemetry.execute(
            [:platform, :responsibility, :unfilled],
            %{system_time: System.system_time()},
            %{key: responsibility.key, feature: responsibility.feature}
          )

          {:ok, :unfilled}

        %{kind: kind} = agent
        when kind in ["external", "native", "local", "federated"] ->
          dispatch_assignee(responsibility, agent, trigger_meta, kind)

        other ->
          # A real defect, not a progressive-enhancement path: something
          # resolved an assignee we cannot dispatch to.
          Logger.warning(
            "[ResponsibilityRouter] unknown assignee shape key=#{responsibility.key} " <>
              "assignee=#{inspect(other)}"
          )

          {:error, {:unknown_assignee_shape, inspect(other)}}
      end
    rescue
      DBConnection.OwnershipError ->
        # A downstream DB touch (dispatch_external → gather_context_via_provider →
        # ContextGatherer.gather, dispatch_native → context resolution, etc.)
        # raised from a Task.Supervised child whose $callers chain doesn't reach
        # the DataCase sandbox owner. Contract: the Router never crashes the
        # GenServer for a single fired trigger — swallow at :debug. The
        # dispatch genuinely did not complete, so `failed` is the honest
        # answer; do NOT report success here.
        Logger.debug(
          "[ResponsibilityRouter] fire_trigger swallowed sandbox-owned DB call " <>
            "key=#{responsibility.key}"
        )

        {:error, {:sandbox_ownership, responsibility.key}}

      error ->
        Logger.warning(
          "[ResponsibilityRouter] fire_trigger raised for key=#{responsibility.key}: " <>
            Exception.message(error)
        )

        {:error, {:fire_raised, Exception.message(error)}}
    catch
      :exit, reason ->
        Logger.warning(
          "[ResponsibilityRouter] fire_trigger caught exit for key=#{responsibility.key}: " <>
            inspect(reason)
        )

        {:error, {:fire_exited, reason}}
    end
  end

  # ── Shared dispatch preamble ──────────────────────────────────────────────

  # Both external and federated/native assignees are *sent a prompt*. An
  # external agent is an API endpoint that returns a response; a
  # federated/native agent is a runtime that receives a prompt payload and
  # acts on it. Nothing about gathering context or rendering the prompt is
  # HTTP-specific, so both happen here — above the external/native branch —
  # and the two paths differ only in envelope: an HTTP body for external,
  # a signal payload for federated.
  #
  # Before this, `gather_context_via_provider/3` and
  # `build_prompt_via_provider/2` lived inside `dispatch_external/3` only,
  # so a native assignee (e.g. the federated architect runtime) received a
  # bare system_event with no rendered prompt and no context.
  defp dispatch_assignee(%Responsibility{} = responsibility, agent, trigger_meta, kind) do
    provider_module = provider_module_for(responsibility.feature)

    case gather_context_via_provider(provider_module, responsibility, trigger_meta) do
      # A provider that exists and refused to produce context. Stop here,
      # BEFORE `build_prompt_via_provider/2` — rendering a prompt over
      # substituted generic context is precisely the wrong-context
      # dispatch this arm exists to prevent. Mirrors the
      # `{:build_prompt_refused, _}` arm in `dispatch_external/3`.
      #
      # Placement note (task 019f9b28-6ca7 stage 2): the stage was written
      # against a tree where gathering lived inside `dispatch_external/3`,
      # so it specified the arm there. `fix/render-prompt-for-federated-dispatch`
      # has since hoisted gathering into this shared preamble, and a native
      # assignee now receives the provider's rendered prompt too. Honouring
      # the refusal here — above the external/native branch — is the only
      # placement that is still "before build_prompt" for both paths.
      {:refused, reason} ->
        refuse_dispatch(responsibility, agent, kind, reason, trigger_meta)

      {:ok, ctx} ->
        context = Map.put(ctx, :__responsibility__, responsibility)
        rendered = build_prompt_via_provider(provider_module, context)

        case kind do
          "external" -> dispatch_external(responsibility, agent, trigger_meta, context, rendered)
          _ -> dispatch_native(responsibility, agent, trigger_meta, kind, context, rendered)
        end
    end
  end

  defp refuse_dispatch(%Responsibility{} = responsibility, agent, kind, reason, trigger_meta) do
    dispatch_kind = if kind == "external", do: :external, else: :native

    Logger.warning(
      "[ResponsibilityRouter] provider gather_context refused dispatch " <>
        "key=#{responsibility.key} agent=#{agent_slug(agent)} reason=#{inspect(reason)}"
    )

    emit_failed_telemetry(
      responsibility,
      agent,
      dispatch_kind,
      {:context_gather_refused, reason}
    )

    invoke_handle_refusal(responsibility, {:context_gather_refused, reason}, trigger_meta)

    {:error, {:context_gather_refused, reason}}
  end

  # ── External dispatch ─────────────────────────────────────────────────────

  defp dispatch_external(
         %Responsibility{} = responsibility,
         agent,
         trigger_meta,
         context,
         rendered
       ) do
    case rendered do
      {:error, reason} ->
        Logger.warning(
          "[ResponsibilityRouter] provider build_prompt refused dispatch " <>
            "key=#{responsibility.key} agent=#{agent_slug(agent)} reason=#{inspect(reason)}"
        )

        emit_failed_telemetry(responsibility, agent, :external, {:build_prompt_refused, reason})

        # The refusal is correct and stays correct — no model call, no
        # side effect. But it used to be the ONE dispatch outcome the
        # provider could not observe: `invoke_handle_output/3` is
        # reachable only from `run_external_dispatch/5`, i.e. only when
        # a model answered. A provider holding per-dispatch state had
        # nowhere to release it, and for `meetings.action_items` that
        # state is a queue row pinning the meeting's SERIAL cursor, so
        # one blank utterance stalled every intent behind it for the
        # full 90s ack window (task 019fb90f-36e3 e2e finding).
        invoke_handle_refusal(responsibility, {:build_prompt_refused, reason}, trigger_meta)

        {:error, {:build_prompt_refused, reason}}

      {:messages, messages} ->
        run_external_dispatch(responsibility, agent, trigger_meta, context, messages: messages)

      :legacy ->
        run_external_dispatch(responsibility, agent, trigger_meta, context, [])
    end
  end

  defp run_external_dispatch(
         %Responsibility{} = responsibility,
         agent,
         trigger_meta,
         context,
         opts
       ) do
    case safe_dispatch(responsibility, agent, context, opts) do
      {:ok, parsed} ->
        Logger.info(
          "[ResponsibilityRouter] external dispatch ok key=#{responsibility.key} " <>
            "agent=#{agent_slug(agent)}"
        )

        invoke_handle_output(responsibility, parsed, trigger_meta)

        safe_stamp_last_fire(agent, Map.get(trigger_meta, :fired_at) || DateTime.utc_now())

        emit_fired_telemetry(responsibility, agent, :external)
        {:ok, :dispatched}

      # THE DISPATCH DIED BEFORE THE ENDPOINT (task 019fba51 stage 4). These
      # three are the prompt-absence taxonomy `ExternalDispatcher` returns
      # from `resolve_messages/3` — its FIRST clause, so `post/2` was never
      # entered and no HTTP request left the box. They are matched ahead of
      # the generic failure arm below because the generic arm's three
      # behaviours are all wrong for them: it calls the outcome a
      # `:dispatch_failed` round trip that never happened, it logs a line an
      # operator reads as an endpoint problem, and — the reason this arm
      # exists — it leaves the provider unaware that the dispatch it gathered
      # context for is over.
      {:error, {:template_missing, _slug} = reason} ->
        abort_prompt_absent(responsibility, agent, trigger_meta, reason)

      {:error, {:template_blank, _slug} = reason} ->
        abort_prompt_absent(responsibility, agent, trigger_meta, reason)

      {:error, :no_prompt_template = reason} ->
        abort_prompt_absent(responsibility, agent, trigger_meta, reason)

      {:error, reason} ->
        Logger.warning(
          "[ResponsibilityRouter] external dispatch failed key=#{responsibility.key} " <>
            "agent=#{agent_slug(agent)} reason=#{inspect(reason)}"
        )

        emit_failed_telemetry(responsibility, agent, :external, reason)
        {:error, {:dispatch_failed, reason}}
    end
  end

  # THE ASYMMETRY WITH `dispatch_native/6` IS DELIBERATE — DO NOT UNIFY.
  #
  # Given the same responsibility row, the same missing `prompt_templates`
  # slug and the same context, this arm ABORTS and `dispatch_native/6`
  # PROCEEDS: it resolves `{:absent, :legacy}` through
  # `render_default_template/2`, gets `{:absent, {:template_missing, slug}}`
  # back, and ships a bare envelope carrying `prompt_status: :render_gap`
  # and `prompt_absence_reason: "template_missing:<slug>"`. That is not
  # drift between two paths that forgot about each other. A native runtime
  # receiving a bare signal can act on it — read the reason, ask, log, wake
  # a human — and the handoff is free. An OpenAI-compat endpoint receiving
  # an empty user turn can only return garbage, and the round trip is
  # billed. Hoisting either behaviour onto the other path would break the
  # half that is correct for its transport.
  #
  # Mirrors the `{:build_prompt_refused, _}` arm of `dispatch_external/5`
  # rather than inventing a second refusal protocol: same telemetry event,
  # same `invoke_handle_refusal/3` seam, same reason-carries-the-cause rule.
  defp abort_prompt_absent(%Responsibility{} = responsibility, agent, trigger_meta, reason) do
    # Phrased off the external-dispatch-failed line above so the two sort
    # together in a grep, and worded so they are never confused: "aborted
    # before the model call" is a fact about OUR side, where "failed" is a
    # fact about theirs. `inspect(reason)` carries the slug for the two
    # template causes, which is the whole point — it names the row to seed.
    Logger.warning(
      "[ResponsibilityRouter] external dispatch aborted before the model call " <>
        "key=#{responsibility.key} agent=#{agent_slug(agent)} reason=#{inspect(reason)}"
    )

    emit_failed_telemetry(responsibility, agent, :external, reason)

    # The half the generic arm cannot do. `invoke_handle_output/3` is
    # reachable only from the `{:ok, parsed}` branch above, i.e. only when a
    # model answered, so a provider holding per-dispatch state had nowhere
    # to release it — the failure mode `{:build_prompt_refused, _}` was
    # given this seam for after `meetings.action_items` stalled a meeting's
    # serial cursor for a full 90s ack window on one blank utterance (task
    # 019fb90f-36e3 e2e finding).
    #
    # MEASURED, NOT ASSUMED (task 019fba51 stage 4): no provider that can
    # reach this arm holds such state TODAY. The arm is reachable only for
    # the eleven builder-less keys, whose providers (`Providers.Tasks`,
    # `Providers.Memory`, `Providers.Design`, and `Handlers.IntentClassify`,
    # whose `gather_context/2` returns a static `missing?: true` placeholder)
    # export no `handle_refusal/3` and acquire nothing during a gather. The
    # one implementation that does — `Handlers.MeetingActionItems` — owns a
    # key with its own `build_prompt/1`, so it never takes the legacy
    # template render and cannot arrive here. This is therefore plumbing for
    # the next provider that holds state, not a fix for a stall happening
    # now, and saying otherwise would be dressing a speculative benefit up
    # as a closed bug.
    invoke_handle_refusal(responsibility, {:prompt_template_absent, reason}, trigger_meta)

    # NOT wrapped in `{:dispatch_failed, _}`. Nothing was dispatched, and
    # the wrapper would cost the caller the taxonomy: `{:template_missing,
    # slug}` says which row to seed, `{:template_blank, slug}` says which
    # row to refill, and `:no_prompt_template` says the key never named one.
    # `Responsibilities.outcome/1` maps every `{:error, _}` to `:failed`, so
    # the ADR-0046 step vocabulary is unchanged by carrying the cause up.
    {:error, reason}
  end

  defp safe_dispatch(responsibility, agent, context, opts) do
    ExternalDispatcher.dispatch(responsibility, agent, context, opts)
  rescue
    error ->
      {:error, {:dispatch_raised, Exception.message(error)}}
  catch
    :exit, reason ->
      {:error, {:dispatch_exited, reason}}
  end

  # Route via provider's `gather_context/2` when it's declared —
  # provider-specific context slots (e.g. `meeting_transcript` in
  # `Handlers.MeetingSummarize`) need the provider's own resolvers
  # because `ContextGatherer.resolve(:meeting_transcript, ...)` reads a
  # flat `meta[:transcript_id]` but the router publishes it nested
  # under `meta[:payload][:transcript_id]`.
  #
  # ONE RULE: **if a provider exists and did not return `{:ok, map}`, do
  # not dispatch.**
  #
  # This used to be a single `else -> gather_context(...)` arm collapsing
  # four distinct situations into one. Two of them mean "nothing to say"
  # and the cross-cutting fallback is right; two of them mean "this
  # dispatch is wrong" and the fallback silently converts a refusal into a
  # generic success — the LLM is then called, and billed, with context
  # that answers a different question. Same defect family as
  # `Code.ensure_loaded?` making "module never written" and "feature
  # deliberately has no provider" the same value (see
  # `Platform.Responsibilities.Providers`).
  #
  #   * `{:ok, ctx}`      — the provider returned `{:ok, map}`.
  #   * `{:ok, fallback}` — there is no provider module, or it does not
  #                         export `gather_context/2`. Nothing to say;
  #                         `ContextGatherer` is the correct answer and
  #                         this path is unchanged.
  #   * `{:refused, r}`   — a provider that DOES exist returned anything
  #                         other than `{:ok, map}`, including a raise.
  #
  # A raise is deliberately folded into `:refused` rather than into the
  # fallback: a broken gatherer producing generic context is the same
  # wrong-context failure as a deliberate refusal. The two are
  # distinguished only by log level — `Logger.error` for the raise in
  # `safe_provider_gather/3`, `Logger.warning` for the refusal in
  # `refuse_dispatch/4`.
  defp gather_context_via_provider(provider_module, %Responsibility{} = responsibility, meta) do
    if is_atom(provider_module) and Code.ensure_loaded?(provider_module) and
         function_exported?(provider_module, :gather_context, 2) do
      case safe_provider_gather(provider_module, responsibility, meta) do
        {:ok, ctx} when is_map(ctx) -> {:ok, ctx}
        {:error, reason} -> {:refused, reason}
        other -> {:refused, {:unexpected_gather_shape, other}}
      end
    else
      {:ok, gather_context(responsibility, meta)}
    end
  end

  defp safe_provider_gather(provider_module, responsibility, meta) do
    provider_module.gather_context(responsibility, meta)
  rescue
    error ->
      # `:error`, not `:warning` — this is the log-level half of the
      # raise-vs-refusal distinction documented above. A provider that
      # blew up is a defect; a provider that said no is a decision.
      Logger.error(
        "[ResponsibilityRouter] provider gather_context raised " <>
          "module=#{inspect(provider_module)} error=#{Exception.message(error)}"
      )

      {:error, {:provider_gather_raised, Exception.message(error)}}
  end

  # Task 019f2570 bug 1 fix: probe for `build_prompt/1` on the provider.
  # When present the returned `%{system:, user:}` map is turned into a
  # pre-built messages list and passed to `Dispatcher.dispatch/4` as
  # `messages: [...]`, sidestepping the un-seeded template-render path.
  # `{:error, reason}` short-circuits the dispatch entirely.
  defp build_prompt_via_provider(provider_module, context) do
    cond do
      is_atom(provider_module) and
        Code.ensure_loaded?(provider_module) and
          function_exported?(provider_module, :build_prompt, 1) ->
        try do
          case provider_module.build_prompt(context) do
            {:ok, %{system: sys, user: user}}
            when is_binary(sys) and is_binary(user) ->
              {:messages, prompt_map_to_messages(sys, user)}

            {:ok, %{user: user}} when is_binary(user) ->
              {:messages, [%{role: "user", content: user}]}

            # Provider explicitly asked for the legacy template render
            # path (e.g. a multi-key provider shim whose current key
            # doesn't own its own prompt yet). NOT a hard error.
            {:error, :no_build_prompt} ->
              :legacy

            {:error, _} = err ->
              err

            other ->
              Logger.warning(
                "[ResponsibilityRouter] provider build_prompt returned unexpected shape " <>
                  "module=#{inspect(provider_module)} result=#{inspect(other)}"
              )

              :legacy
          end
        rescue
          error ->
            Logger.warning(
              "[ResponsibilityRouter] provider build_prompt raised " <>
                "module=#{inspect(provider_module)} error=#{Exception.message(error)}"
            )

            :legacy
        end

      true ->
        :legacy
    end
  end

  defp prompt_map_to_messages("", user), do: [%{role: "user", content: user}]

  defp prompt_map_to_messages(sys, user),
    do: [%{role: "system", content: sys}, %{role: "user", content: user}]

  defp gather_context(%Responsibility{context_provided: names}, trigger_meta)
       when is_list(names) do
    ContextGatherer.gather(names, trigger_meta)
  rescue
    error ->
      Logger.warning(
        "[ResponsibilityRouter] context gather raised: #{Exception.message(error)} — " <>
          "dispatching with empty context"
      )

      %{}
  end

  defp gather_context(_responsibility, _trigger_meta), do: %{}

  # Resolve the provider module from the responsibility's `feature`
  # field (`"meetings"` → `Platform.Responsibilities.Providers.Meetings`).
  # Probe for `handle_output/3` first (stage 6 evolved arity); fall back
  # to a missing-handler log so providers that haven't been ported yet
  # don't crash the dispatch pipeline.
  defp invoke_handle_output(%Responsibility{feature: feature} = responsibility, parsed, meta)
       when is_binary(feature) do
    provider_module = provider_module_for(feature)

    cond do
      is_atom(provider_module) and
        Code.ensure_loaded?(provider_module) and
          function_exported?(provider_module, :handle_output, 3) ->
        try do
          case provider_module.handle_output(responsibility, parsed, meta) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[ResponsibilityRouter] handle_output returned error key=#{responsibility.key} " <>
                  "reason=#{inspect(reason)}"
              )

              :ok

            other ->
              Logger.warning(
                "[ResponsibilityRouter] handle_output returned unexpected shape key=#{responsibility.key} " <>
                  "result=#{inspect(other)}"
              )

              :ok
          end
        rescue
          error ->
            Logger.warning(
              "[ResponsibilityRouter] handle_output raised key=#{responsibility.key} " <>
                "error=#{Exception.message(error)}"
            )

            :ok
        end

      true ->
        log_missing_output_handler(responsibility)
    end
  end

  defp invoke_handle_output(%Responsibility{} = responsibility, _parsed, _meta) do
    log_missing_output_handler(responsibility)
  end

  # The refusal counterpart of `invoke_handle_output/3` — same probe,
  # same swallow-and-log discipline, one deliberate difference: a
  # provider that does not export `handle_refusal/3` is SILENT here,
  # where a missing output handler warns.
  #
  # The asymmetry is the point. A dispatch that produced a model
  # response and found no handler has lost work, and that deserves a
  # line. A refusal has produced nothing to lose; the callback exists
  # only for providers holding per-dispatch state, which is the
  # minority. Warning on every refusal for every provider would put a
  # line in the log for the ordinary case and train people to skip it —
  # the same rot `log_missing_output_handler/1` documents.
  #
  # Nothing here can change the Router's return value. The refusal has
  # already been decided and already been reported by the caller; this
  # is a side-effect seam, not a veto.
  defp invoke_handle_refusal(%Responsibility{feature: feature} = responsibility, refusal, meta)
       when is_binary(feature) and is_map(meta) do
    provider_module = provider_module_for(feature)

    if is_atom(provider_module) and Code.ensure_loaded?(provider_module) and
         function_exported?(provider_module, :handle_refusal, 3) do
      try do
        case provider_module.handle_refusal(responsibility, refusal, meta) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[ResponsibilityRouter] handle_refusal returned error key=#{responsibility.key} " <>
                "refusal=#{inspect(refusal)} reason=#{inspect(reason)}"
            )

            :ok

          other ->
            Logger.warning(
              "[ResponsibilityRouter] handle_refusal returned unexpected shape " <>
                "key=#{responsibility.key} result=#{inspect(other)}"
            )

            :ok
        end
      rescue
        error ->
          Logger.warning(
            "[ResponsibilityRouter] handle_refusal raised key=#{responsibility.key} " <>
              "error=#{Exception.message(error)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp invoke_handle_refusal(%Responsibility{}, _refusal, _meta), do: :ok

  # One log line, three causes — told apart. Before task 019f9b28 stage 2
  # this was a bare `Logger.info`, so a provider module that was never
  # written (`architecture.*`, for months) and a feature that deliberately
  # has none (`security.*`) produced byte-identical output.
  #
  # Deliberately `:warning` and not `:error` for the unregistered case:
  # `router_test.exs` seeds ad-hoc `feature: "test_feature_<n>"` rows and
  # operators can `upsert_by_key/1` arbitrary ones. Screaming at error
  # level for every ad-hoc feature trains people to ignore the line —
  # exactly the rot this change exists to prevent. Loud drift detection
  # belongs where the population is closed: Registry boot and CI.
  defp log_missing_output_handler(%Responsibility{key: key, feature: feature}) do
    case Providers.feature_provider(feature) do
      {:retired, reason} ->
        Logger.debug(
          "[ResponsibilityRouter] no output handler for #{key} — feature=#{inspect(feature)} " <>
            "is retired by design: #{reason}"
        )

      :error ->
        Logger.warning(
          "[ResponsibilityRouter] no output handler for #{key} — feature=#{inspect(feature)} " <>
            "has no provider registered. Fix: add it to " <>
            "Platform.Responsibilities.Providers @feature_providers, or to @retired with a reason."
        )

      {:ok, module} ->
        Logger.error(
          "[ResponsibilityRouter] no output handler for #{key} — provider #{inspect(module)} " <>
            "is registered for feature=#{inspect(feature)} but failed the handle_output/3 " <>
            "probe (loaded?=#{Code.ensure_loaded?(module)}). This is a contract break in a " <>
            "module we ship, not a routing gap."
        )
    end

    :ok
  end

  # Resolve the provider module through the explicit registry in
  # `Platform.Responsibilities.Providers` (task 019f9b28 stage 2). This
  # used to camelcase `feature` and prepend the Providers namespace,
  # which made "module never written" and "feature deliberately has no
  # provider" the same value at every consumption point — see that
  # module's moduledoc for the argument.
  #
  # Both non-`{:ok, _}` outcomes still collapse to `nil` HERE, because
  # each caller only needs a module-or-nothing to decide whether to
  # invoke a callback. The distinction is made where it is actionable:
  # `log_missing_output_handler/1` and `log_native_prompt_fidelity/3`.
  defp provider_module_for(feature) do
    case Providers.feature_provider(feature) do
      {:ok, module} -> module
      {:retired, _reason} -> nil
      :error -> nil
    end
  end

  # ── Native / federated dispatch ───────────────────────────────────────────

  defp dispatch_native(
         %Responsibility{} = responsibility,
         agent,
         trigger_meta,
         kind,
         context,
         rendered
       ) do
    # Classified ONCE, here, and handed to both consumers. Previously each
    # of them re-derived the outcome from `rendered` independently, which is
    # how the logger and the envelope could disagree about what happened.
    #
    # `{:absent, :legacy}` is the ONE outcome that is not final at this
    # point: it means "no provider spoke for this key", which is exactly
    # the case the responsibility's own `default_prompt_template` exists
    # to answer. Resolving it here — after classification, before the
    # signal is built — keeps the whole prompt decision in one place for
    # the logger and the envelope to read.
    outcome =
      case classify_prompt_outcome(rendered) do
        {:absent, :legacy} -> render_default_template(responsibility, context)
        other -> other
      end

    case outcome do
      # `:no_measurement` is not a render gap and not deliberate silence —
      # it is "there is nothing to do." Every other `{:absent, _}` still
      # means a runtime SHOULD wake (to say so, or because the gap itself
      # is actionable); this is the one case where waking accomplishes
      # nothing, so the whole native hand-off — signal, responder call,
      # runtime-topic broadcast — is skipped rather than sent bare. See
      # `AgentsGoalHeartbeat`'s moduledoc, "## Two states refuse, and the
      # Router now skips the hand-off entirely",
      # for the two slots that produce this reason. Deliberately narrower
      # than `@no_work_refusals`: that whitelist still dispatches a
      # `:no_work` envelope; this skips dispatch entirely, which is why it
      # is matched here rather than added to that list.
      {:absent, {:refused, {:no_measurement, reason}}} ->
        Logger.debug(
          "[ResponsibilityRouter] #{kind} dispatch skipped (nothing to do) " <>
            "key=#{responsibility.key} agent=#{agent_slug(agent)} " <>
            "reason=#{inspect(reason)}"
        )

        {:ok, :no_measurement}

      _ ->
        log_native_prompt_fidelity(responsibility, agent, outcome)
        emit_prompt_absent_telemetry(responsibility, outcome)

        signal = build_native_signal(responsibility, agent, trigger_meta, outcome, context)

        Logger.info(
          "[ResponsibilityRouter] #{kind} dispatch key=#{responsibility.key} " <>
            "agent=#{agent_slug(agent)} signal=#{inspect(Map.take(signal, [:reason, :space_id]))}"
        )

        # The stamp + `fired` telemetry are conditional on the handoff being
        # accepted. They used to fire unconditionally, which reported a
        # successful dispatch even when the native dispatcher was missing or
        # raised.
        case call_agent_responder(signal) do
          {:ok, :dispatched} ->
            safe_stamp_last_fire(agent, Map.get(trigger_meta, :fired_at) || DateTime.utc_now())

            emit_fired_telemetry(responsibility, agent, :native)
            {:ok, :dispatched}

          {:error, reason} ->
            Logger.warning(
              "[ResponsibilityRouter] #{kind} dispatch failed key=#{responsibility.key} " <>
                "agent=#{agent_slug(agent)} reason=#{inspect(reason)}"
            )

            emit_failed_telemetry(responsibility, agent, :native, reason)
            {:error, reason}
        end
    end
  end

  # Builds an AgentResponder-shaped signal so the Router is a drop-in
  # replacement for SystemEventScheduler's hand-off. We omit `message_id`
  # when there isn't one (e.g. cron-fired native responsibilities) — the
  # AgentResponder treats nil ids as "synthesize a system instruction"
  # and the historian path is the precedent.
  #
  # Takes the CLASSIFIED outcome, not the raw provider return. `prompt` is
  # still emitted only for `{:rendered, text}` and the key is still omitted
  # for every `{:absent, _}` — stage 3 ADDS `prompt_status` beside it rather
  # than replacing the omission with an empty string. See
  # `prompt_disposition/1` for why an empty body must never become an empty
  # `prompt`.
  #
  # Takes the gathered CONTEXT as well, for one reason only: a provider
  # may name the space this dispatch writes into, and that space has to
  # reach the invite. See `put_dispatch_space/2` — it lands in
  # `metadata.space_id`, never at the top level of the signal.
  defp build_native_signal(
         %Responsibility{} = responsibility,
         agent,
         trigger_meta,
         outcome,
         context
       ) do
    reason = native_reason_for(Map.get(trigger_meta, :kind))

    metadata =
      %{
        responsibility_key: responsibility.key,
        feature: responsibility.feature,
        trigger_kind: native_trigger_kind(responsibility, trigger_meta),
        agent_id: Map.get(agent, :id) || Map.get(agent, "id"),
        agent_slug: agent_slug(agent)
      }
      |> put_trigger_scalars(trigger_meta)
      |> put_dispatch_space(context)
      |> maybe_put(:prompt, prompt_body(outcome))
      |> put_prompt_status(outcome)

    %{reason: reason, metadata: metadata}
    |> maybe_put(:message_id, Map.get(trigger_meta, :message_id))
    |> maybe_put(:space_id, Map.get(trigger_meta, :space_id))
    |> maybe_put(:participant_id, Map.get(trigger_meta, :participant_id))
    |> maybe_put(:meeting_id, Map.get(trigger_meta, :meeting_id))
  end

  # THE `trigger_kind` FALLBACK (task 019fa56b-ca2d).
  #
  # `trigger_meta[:kind]` is supplied by exactly ONE producer in the tree:
  # `maybe_fire_cron/4`, which passes `%{kind: :cron, fired_at: now}`. Every
  # `event_topic` producer calls `Responsibilities.fire/2` with a
  # subject-shaped map and no `:kind` at all —
  # `PlanEngine.after_stage_completed/1` passes
  # `%{stage_id:, plan_id:, task_id:, stage:, plan:, task:}` and
  # `Tasks.fire_architecture_review_plan/1` passes
  # `%{plan_id:, task_id:, plan:}`. So this field was `nil` on every real
  # `architecture.*` fire, `AgentResponder` recorded that `nil` onto the
  # dead-letter row, and `DeadLetterPolicy.classify/1` normalised it to
  # `{:drop, :unclassified}` — the whole ledger recorded and then dropped
  # 34 fires it was built to replay.
  #
  # The row is the authority. `responsibilities.trigger_kind` is NOT NULL
  # and `validate_inclusion`-guarded against `Responsibility.trigger_kinds/0`,
  # so it always carries the same closed vocabulary the policy rules on. A
  # producer that forgets to say how it was triggered is not evidence that
  # the responsibility has no trigger kind.
  #
  # Fixing it HERE rather than at the two call sites is deliberate: the call
  # sites are a list that grows, and the next producer would re-open this
  # bug silently. This is the single place every native fire passes through.
  # Backfilling in `DeadLetters.record/1` was also rejected — it would repair
  # the ledger while leaving the live signal on the wire still missing
  # `trigger_kind`, so an ONLINE runtime would keep receiving an unlabelled
  # fire.
  #
  # `trigger_meta[:kind]` still WINS when present. The cron path must keep
  # recording `cron` even on a row whose `trigger_kind` says otherwise —
  # reclassifying a cron fire as `event_topic` would replay wall-clock-stale
  # work that the Router's own tick is already going to redo.
  #
  # Type note: the override is an atom (`:cron`), the fallback a string
  # (`"event_topic"`). Both are accepted downstream —
  # `DeadLetters.record/1` stringifies via `stringify/1`, `to_envelope/1`
  # restores the atom against `@trigger_kind_value_strings`, and
  # `DeadLetterPolicy.normalize_kind/1` handles either. Coercing here would
  # change what the ONLINE runtime sees on the cron path, which is out of
  # scope for this fix.
  defp native_trigger_kind(%Responsibility{} = responsibility, trigger_meta) do
    Map.get(trigger_meta, :kind) || responsibility.trigger_kind
  end

  # Scalar correlation ids the receiving runtime needs to act on the fire.
  #
  # Deliberately a WHITELIST, never `Map.merge(trigger_meta)`: the
  # plan-submit hook (`Platform.Tasks.fire_architecture_review_plan/1`)
  # publishes a full `%Plan{}` struct under `:plan`, and the chat path
  # carries a frozen history snapshot under `:metadata`. Forwarding either
  # would push an unbounded payload onto a websocket — see commit
  # `babba0bf` for the same reasoning on the chat side.
  # `:intent_id` added 2026-07-31 — see the matching comment on
  # `AgentResponder.@correlation_id_keys`. Without it a meeting intent
  # dispatched to a NATIVE assignee had no handle to `intent_ack` with,
  # so the row could only leave `:dispatched` via the 90s timeout while
  # holding the meeting's serial cursor for the whole window.
  @native_trigger_scalar_keys [:task_id, :plan_id, :stage_id, :project_id, :intent_id]

  @doc false
  # Exposed so `AgentResponder`'s system_event envelope can be pinned against
  # this whitelist by a test instead of restating it. The two lists diverging
  # is how a correlation id ends up reaching a runtime on the chat path and not
  # on the responsibility path — the asymmetry that made two clients wrong.
  def native_trigger_scalar_keys, do: @native_trigger_scalar_keys

  defp put_trigger_scalars(metadata, trigger_meta) do
    Enum.reduce(@native_trigger_scalar_keys, metadata, fn key, acc ->
      case Map.get(trigger_meta, key) do
        value when is_binary(value) -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  # THE SPACE A DISPATCH NAMES — read from the PROVIDER'S GATHERED
  # CONTEXT, written to `metadata.space_id`, and deliberately never to
  # the top level of the signal.
  #
  # `Platform.Chat.AgentResponder.broadcast_system_event/3` passes
  # `metadata[:space_id]` to `Federation.AttentionDispatch.broadcast/3`
  # as the `space_id:` OPTION, and that option is the only input
  # `Platform.Chat.DispatchMembership.ensure_writable/3` has. Without a
  # space there, the invite is a clean `:no_space_named` skip and the
  # dispatched agent is not a participant of the space it was just told
  # to write into — which is dead on arrival for anything holding
  # `canvas_create` / `canvas_patch`. Measured on the 2026-08-01
  # production meeting `019fb8ec-8644-75a4-b764-cc859d082dce`: six
  # meeting intents dispatched to a native assignee, zero invites.
  #
  # OPTION IS NOT WIRE. The option feeds the invite and nothing else;
  # the wire payload is a separate argument it never touches. So the
  # space can invite the agent WITHOUT the signal claiming the
  # top-level `space_id` slot, which `claude-code-suite-channel`'s
  # `attention.ts` reserves for pinning where a pending permission
  # prompt is answered. That is why this writes `metadata.space_id` and
  # why `space_id` is still absent from
  # `AgentResponder.@correlation_id_keys`. Read the paragraph above
  # that list before changing either half.
  #
  # OPT-IN, NOT AMBIENT. The key is the provider's `:dispatch_space_id`
  # — a context key a gatherer sets deliberately (today: the six
  # `meetings.*` intent handlers, from
  # `Platform.Meetings.IntentContext.space_id/1`). It is deliberately
  # NOT sniffed from `trigger_meta`, and deliberately not a plain
  # `:space_id` context key: a cron sweep or a webhook fire whose
  # context happens to mention a space must keep taking the
  # `:no_space_named` skip rather than quietly inviting its agent into
  # somewhere. A responsibility starts inviting only when its provider
  # says so.
  defp put_dispatch_space(metadata, context) when is_map(context) do
    case Map.get(context, :dispatch_space_id) do
      space_id when is_binary(space_id) and space_id != "" ->
        Map.put(metadata, :space_id, space_id)

      _ ->
        metadata
    end
  end

  defp put_dispatch_space(metadata, _context), do: metadata

  @typedoc """
  The named outcome of asking a provider for a prompt body.

  `{:absent, _}` carries the CAUSE, not merely the fact of absence — see
  `classify_prompt_outcome/1`.
  """
  @type prompt_outcome ::
          {:rendered, String.t()}
          | {:absent, :legacy}
          | {:absent, :empty_render}
          | {:absent, {:refused, term()}}
          | {:absent, {:unexpected_shape, term()}}
          | {:absent, {:template_missing, String.t()}}
          | {:absent, {:template_blank, String.t()}}

  @doc false
  # THE FOURTH COLLAPSE POINT (found while auditing task 019f9b28), closed
  # here by task 019fb8ed stage 1.
  #
  # This function used to be `rendered_prompt_text/1`, and it mapped FOUR
  # distinct inputs onto `nil` — `:legacy` (no provider at all, or a
  # provider that ships no `build_prompt/1`), `{:error, reason}` (a
  # provider that explicitly refused), a `{:messages, _}` whose contents
  # join to `""`, and any unexpected shape. `maybe_put/3` then dropped the
  # key, so a federated runtime received a byte-identical bare signal
  # whether the architect refused to speak, was never asked, or answered
  # with nothing. That is the same indistinguishability
  # `Platform.Responsibilities.Providers` exists to kill, one layer
  # further down, and it is why three responsibility keys could fire
  # empty every time for weeks while looking exactly like the one
  # legitimate no-work case.
  #
  # So the outcome is now NAMED. Each cause gets its own value, and the
  # values are pairwise distinct — that distinctness is the property the
  # stage exists to create and is asserted directly (as a `uniq` count,
  # not as five independent equality assertions, which would all stay
  # green if two causes were re-collapsed onto one value).
  #
  # `{:absent, {:refused, reason}}` deliberately carries the provider's
  # OWN reason through rather than flattening to a bare atom: downstream,
  # `:no_transcript_text` (a legitimate refusal to spend a model
  # round-trip on an empty transcript — see
  # `Handlers.MeetingSummarize.build_prompt/1`) and `:no_build_prompt`
  # (a wiring gap) have to reach different conclusions. Flattening here
  # would recreate the collapse one layer up.
  #
  # The shapes stay enumerated rather than caught wholesale so a new
  # return from `build_prompt_via_provider/2` has to be considered here
  # instead of silently becoming an absence; the trailing catch-all
  # remains because an absent prompt beats a FunctionClauseError inside a
  # plan-submit transaction — but it now RECORDS the shape it could not
  # read instead of discarding it.
  #
  # Exposed as a `@doc false` public function for the same reason
  # `native_trigger_scalar_keys/0` is: driving all five shapes through the
  # full dispatch path would need five throwaway providers, and a test
  # that can only reach four of them is not a distinctness test. The
  # end-to-end wiring is pinned separately, so this seam cannot be
  # green while nothing calls it.
  #
  # REACHABILITY — measured, and narrower than the enumeration suggests.
  # `build_prompt_via_provider/2` collapses two of these five BEFORE this
  # function is reached: it maps `{:error, :no_build_prompt}` to `:legacy`
  # (deliberately — that error means "this key does not own its own prompt,
  # use the legacy template render", not "fail") and it maps an unexpected
  # return and a raise to `:legacy` too. So `{:absent, {:refused,
  # :no_build_prompt}}` and `{:absent, {:unexpected_shape, _}}` cannot come
  # from live traffic today; they are reachable only by a direct call.
  #
  # They stay enumerated because that is where the un-collapsed values will
  # land, but do NOT read the list as a description of what arrives. That
  # un-collapsing is wire-visible on the OTHER path — `dispatch_external/5`
  # aborts on `{:error, _}` with failed telemetry, so letting
  # `:no_build_prompt` through as an error would stop every external agent
  # whose provider asks for the legacy render from dispatching at all — so
  # it needs its own change with its own external-path coverage. The
  # current pre-collapse is pinned by test in `prompt_outcome_test.exs`,
  # under "the provider layer pre-collapses two of the five outcomes", to
  # give that change a red line to flip.
  @spec classify_prompt_outcome(term()) :: prompt_outcome()
  def classify_prompt_outcome({:messages, messages}) when is_list(messages) do
    text =
      messages
      |> Enum.map(&Map.get(&1, :content))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n\n")

    if text == "", do: {:absent, :empty_render}, else: {:rendered, text}
  end

  def classify_prompt_outcome(:legacy), do: {:absent, :legacy}
  def classify_prompt_outcome({:error, reason}), do: {:absent, {:refused, reason}}
  def classify_prompt_outcome(other), do: {:absent, {:unexpected_shape, other}}

  # The body a `{:rendered, _}` outcome carries, or `nil` for every
  # absence — `maybe_put/3` turns the nil into an omitted key. Kept as a
  # named function so the "absent means NO key, never an empty string"
  # decision (argued at `agent_responder.ex:477-499`) has one home.
  defp prompt_body({:rendered, text}) when is_binary(text), do: text
  defp prompt_body({:absent, _cause}), do: nil

  # THE WIRE STATUS (task 019fb8ed stage 3).
  #
  # Stages 1 and 2 named the causes SERVER-SIDE. A federated runtime still
  # received the same bare envelope for all of them, so the one question a
  # receiving agent actually has to answer — "is this silence deliberate, or
  # is something broken?" — was unanswerable on the wire.
  #
  # AN EMPTY PROMPT IS SOMETIMES LEGITIMATE.
  # `Handlers.MeetingSummarize.build_prompt/1` returns
  # `{:error, :no_transcript_text}` ON PURPOSE when the transcript has no
  # text: a model round-trip over no content is spend with no possible
  # output. `gather_transcript(nil)` yields `formatted_text: ""` too, so a
  # fire with no resolvable `transcript_id` lands there as well. That is
  # content-dependent, not a regression — and it is exactly why the
  # `meetings.action_items` fire that rendered and the one that did not
  # looked identical in the original report. A wiring gap (no
  # `build_prompt/1`) and a render gap (a `default_prompt_template` slug
  # with no row) are NOT legitimate, and now say so.
  #
  # `:no_intent_text` is the SAME KIND of refusal for the mid-meeting
  # `meetings.action_items` path (task 019fb90f-36e3 stage 3). That key
  # stopped firing once over a finished meeting and now fires per
  # utterance, so the thing it can have nothing to say about moved from
  # the transcript to the chunk: `Handlers.MeetingActionItems.build_prompt/1`
  # refuses `{:error, :no_intent_text}` on a blank excerpt and no longer
  # returns `:no_transcript_text` at all. Both atoms name a provider that
  # CHOSE silence over an empty input, so both are no-work; they stay
  # distinct atoms because they name different empty inputs, which is what
  # tells a human which of the two paths went quiet.
  #
  # WHY A WHITELIST OF NO-WORK REASONS RATHER THAN A BLACKLIST OF GAPS.
  # The asymmetry is deliberate: the default has to be `:render_gap`. A new
  # provider refusal that is wrongly reported as a gap is NOISE — someone
  # reads the reason, sees it is legitimate, and adds one line here. A new
  # gap wrongly reported as `:no_work` is SILENCE, which is the whole defect
  # this task exists to remove. So adding a legitimate refusal is a
  # one-line, reviewable edit and forgetting to make it cannot hide a
  # defect.
  @no_work_refusals [:no_transcript_text, :no_intent_text]

  @typedoc """
  What a receiving runtime is told about the prompt it did (not) get.

    * `:rendered` — a body is present at `signal.prompt`.
    * `:no_work` — the provider deliberately declined; there was nothing to
      say. The agent should still wake and may say so.
    * `:render_gap` — the server meant to say something and could not. A
      defect, with `prompt_absence_reason` naming which one.
  """
  @type prompt_status :: :rendered | :no_work | :render_gap

  @doc false
  # Exposed so a test can pin the list rather than restating it, and can
  # assert what is NOT on it — `:no_build_prompt` in particular, which is a
  # wiring gap wearing a refusal's clothes.
  @spec no_work_refusals() :: [atom()]
  def no_work_refusals, do: @no_work_refusals

  # REACHABILITY, MEASURED — read this before adding a row.
  #
  # `build_prompt_via_provider/2` maps `{:error, :no_build_prompt}`, an
  # unexpected return AND a raise onto `:legacy` before the classifier is
  # reached. So `{:absent, {:refused, :no_build_prompt}}` and
  # `{:absent, {:unexpected_shape, _}}` cannot arrive here from live
  # traffic; a clause keyed on either would never fire, and would rot
  # unnoticed. They are therefore NOT given their own rows: they fall
  # through the same default every other absence takes, which is the
  # answer that stays correct if the pre-collapse is ever undone.
  #
  # Undoing it is deliberately not this stage's change: `dispatch_external/5`
  # ABORTS on `{:error, _}` with failed telemetry, so letting
  # `:no_build_prompt` through as an error would stop every external agent
  # whose provider asks for the legacy render from dispatching at all. The
  # pre-collapse is pinned by test in `prompt_outcome_test.exs` under "the
  # provider layer pre-collapses two of the five outcomes".
  @spec prompt_disposition(prompt_outcome()) :: {prompt_status(), String.t() | nil}
  defp prompt_disposition({:rendered, _text}), do: {:rendered, nil}

  defp prompt_disposition({:absent, {:refused, reason}}) when reason in @no_work_refusals,
    do: {:no_work, absence_reason_text(reason)}

  defp prompt_disposition({:absent, cause}), do: {:render_gap, absence_cause_text(cause)}

  # Short, greppable, and stable enough for a client to branch on. The slug
  # rides along for the two template causes because it names the row to go
  # seed — the reason a runtime can act on, not merely report.
  defp absence_cause_text(:legacy), do: "provider_has_no_build_prompt"
  defp absence_cause_text(:empty_render), do: "empty_render"
  defp absence_cause_text({:refused, reason}), do: absence_reason_text(reason)
  defp absence_cause_text({:template_missing, slug}), do: "template_missing:#{slug}"
  defp absence_cause_text({:template_blank, slug}), do: "template_blank:#{slug}"

  # The offending value is deliberately NOT interpolated: it is an arbitrary
  # provider return of unknown size and shape, and this string goes over the
  # wire to a third-party runtime. `log_native_prompt_fidelity/3` already
  # records it in full, server-side, where it belongs.
  defp absence_cause_text({:unexpected_shape, _other}), do: "unexpected_shape"

  defp absence_reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp absence_reason_text(reason), do: inspect(reason)

  # `prompt_status` is ALWAYS present, including for `:rendered`; a client
  # can therefore treat its absence as "this server predates the field"
  # rather than having to guess. `prompt_absence_reason` is present only
  # when there is one — a status field that is always populated would not be
  # evidence that any branch ran.
  #
  # AND `prompt` STAYS ABSENT WHEN THERE IS NO BODY. This is an addition,
  # not a replacement: an empty `prompt` reads to a client as "the server
  # had something to say and it was nothing" (argued at
  # `agent_responder.ex`, `build_system_event_payload/1`, and pinned by
  # `native_dispatch_envelope_test.exs`).
  defp put_prompt_status(metadata, outcome) do
    {status, reason} = prompt_disposition(outcome)

    metadata
    |> Map.put(:prompt_status, status)
    |> maybe_put(:prompt_absence_reason, reason)
  end

  # THE OBSERVABILITY HALF OF THE NATIVE/EXTERNAL ASYMMETRY.
  #
  # `dispatch_external/5` aborts on a refusal and emits `failed` telemetry;
  # `dispatch_native/6` proceeds silently. Native's dispatch DECISION is
  # deliberately unchanged — an agent that receives a `no_work` envelope
  # should still wake and be able to say so — but the event makes render
  # gaps countable instead of only greppable. Emitted before the hand-off,
  # so it reports what the envelope carried whether or not the runtime
  # accepted it.
  defp emit_prompt_absent_telemetry(%Responsibility{} = responsibility, outcome) do
    case prompt_disposition(outcome) do
      {:rendered, _reason} ->
        :ok

      {status, reason} ->
        :telemetry.execute(
          [:platform, :responsibilities, :prompt_absent],
          %{system_time: System.system_time()},
          %{
            key: responsibility.key,
            feature: responsibility.feature,
            prompt_status: status,
            reason: reason,
            dispatch: :native
          }
        )

        :ok
    end
  rescue
    _ -> :ok
  end

  # THE MISSING HALF OF THE NATIVE PROMPT PATH (task 019fb8ed stage 2).
  #
  # `responsibilities.default_prompt_template` holds a prompt template
  # SLUG — `"tasks.triage.v1"`, `"design.task_direction.v1"` — and the
  # rows those slugs name are real, seeded by migration. Nothing on the
  # native path ever looked one up. So every `tasks.triage`,
  # `tasks.weekly_review` and `tasks.unblock` fire classified
  # `{:absent, :legacy}` (their provider, `Providers.Tasks`, exports no
  # `build_prompt/1` — legal, `@optional_callbacks build_prompt: 1`) and
  # shipped a bare envelope. Not intermittent: those three keys had
  # never once rendered.
  #
  # WHY A DB LOOKUP, AND NOT "DO WHAT THE EXTERNAL PATH DOES". The
  # external legacy path is itself broken and mirroring it would ship
  # garbage. `ExternalAgents.Dispatcher.legacy_messages/2` passes this
  # same slug STRING straight into an `EEx.eval_string/2` and falls back
  # to the literal on failure, so an external agent receives the message
  # `[%{role: "user", content: "meetings.action_items.v1"}]` — the
  # literal slug as its prompt. That module contains no reference to
  # `PromptTemplates` at all. The defect is general, not
  # meetings-specific, and it is deliberately NOT fixed here: switching
  # the external path to a DB lookup changes the prompt every external
  # agent receives, which is a far larger blast radius than this change
  # owns. Its current behaviour is pinned by a characterisation test in
  # `external_agents/dispatcher_test.exs` so this change provably does
  # not alter it and the follow-up has a red line to flip.
  #
  # A MISSING ROW IS NOT A LEGACY FIRE. `{:absent, {:template_missing,
  # slug}}` and `{:absent, {:template_blank, slug}}` are separate
  # outcomes rather than a fall-back to `{:absent, :legacy}` for the
  # reason the whole taxonomy exists: "this key was never wired to a
  # prompt" and "this key names a prompt that isn't there" need different
  # fixes, and collapsing them would make the second invisible. The slug
  # rides along so the reader is told WHICH row to go seed.
  defp render_default_template(%Responsibility{default_prompt_template: slug}, context)
       when is_binary(slug) do
    case String.trim(slug) do
      "" ->
        {:absent, :legacy}

      slug ->
        case PromptTemplates.render_template(slug, template_assigns(context)) do
          {:ok, body} ->
            if String.trim(body) == "",
              do: {:absent, {:template_blank, slug}},
              else: {:rendered, body}

          {:error, :not_found} ->
            {:absent, {:template_missing, slug}}
        end
    end
  end

  defp render_default_template(_responsibility, _context), do: {:absent, :legacy}

  # `PromptTemplates.render_template/2` interpolates `{{name}}` by calling
  # `to_string/1` on the assign — and it wraps the whole render in a
  # `rescue -> {:error, :not_found}`. So a context value that doesn't
  # implement `String.Chars` would be reported as a MISSING TEMPLATE, which
  # is a lie about a row that is sitting right there. Gather-provided
  # context is routinely nested (`Providers.Tasks` returns
  # `%{org_identity: %{missing?: true, ...}}`), so this is not
  # hypothetical the moment a template grows its first placeholder.
  #
  # `:__responsibility__` is dropped rather than inspected: it is a
  # `%Responsibility{}` the Router stamped on for its own use, not
  # something a prompt author asked for.
  defp template_assigns(context) when is_map(context) do
    context
    |> Map.delete(:__responsibility__)
    |> Map.new(fn {key, value} -> {key, printable_assign(value)} end)
  end

  defp template_assigns(_context), do: %{}

  defp printable_assign(value) when is_binary(value), do: value
  defp printable_assign(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp printable_assign(value), do: inspect(value)

  defp log_native_prompt_fidelity(_responsibility, _agent, {:rendered, _text}), do: :ok

  defp log_native_prompt_fidelity(
         %Responsibility{} = responsibility,
         agent,
         {:absent, {:refused, reason}}
       ) do
    Logger.warning(
      "[ResponsibilityRouter] provider build_prompt refused but native dispatch proceeds " <>
        "with no prompt key=#{responsibility.key} agent=#{agent_slug(agent)} " <>
        "reason=#{inspect(reason)} — the external path would have aborted here"
    )

    :ok
  end

  # A provider that answered, with nothing. Distinct from a refusal: the
  # callback ran to completion and produced messages whose contents were
  # all blank or non-binary, which is a defect in the provider rather than
  # a decision by it. Silent before this stage, because the old
  # `{:messages, _}` clause matched it and returned `:ok`.
  defp log_native_prompt_fidelity(
         %Responsibility{} = responsibility,
         agent,
         {:absent, :empty_render}
       ) do
    Logger.warning(
      "[ResponsibilityRouter] provider build_prompt returned messages that render to an " <>
        "empty body key=#{responsibility.key} agent=#{agent_slug(agent)} — native dispatch " <>
        "proceeds with no prompt"
    )

    :ok
  end

  defp log_native_prompt_fidelity(
         %Responsibility{} = responsibility,
         agent,
         {:absent, {:unexpected_shape, other}}
       ) do
    Logger.warning(
      "[ResponsibilityRouter] prompt outcome has an unrecognised shape " <>
        "key=#{responsibility.key} agent=#{agent_slug(agent)} result=#{inspect(other)} — " <>
        "add a clause to classify_prompt_outcome/1 rather than leaving it in the catch-all"
    )

    :ok
  end

  # The responsibility named a prompt template and the row is not there.
  # `:warning`, not `:debug` — unlike `{:absent, :legacy}` (a key that
  # never claimed to own a prompt) this is a broken promise, and the fix
  # is a one-line seed migration for the named slug.
  defp log_native_prompt_fidelity(
         %Responsibility{} = responsibility,
         agent,
         {:absent, {:template_missing, slug}}
       ) do
    Logger.warning(
      "[ResponsibilityRouter] default_prompt_template names a slug with no prompt_templates " <>
        "row key=#{responsibility.key} agent=#{agent_slug(agent)} slug=#{inspect(slug)} — " <>
        "native dispatch proceeds with no prompt. Fix: seed the row (see " <>
        "priv/repo/migrations for the pattern), do not edit the hardcoded default list — " <>
        "PromptTemplates.seed_defaults/0 is INSERT-only and skips migrated environments."
    )

    :ok
  end

  # The row exists and is empty. Distinct from a missing row because the
  # remedy is different: someone edited the content to nothing (templates
  # are editable live via `prompt_template_update`), so there is no
  # migration to write.
  defp log_native_prompt_fidelity(
         %Responsibility{} = responsibility,
         agent,
         {:absent, {:template_blank, slug}}
       ) do
    Logger.warning(
      "[ResponsibilityRouter] default_prompt_template resolved to a blank body " <>
        "key=#{responsibility.key} agent=#{agent_slug(agent)} slug=#{inspect(slug)} — " <>
        "the row exists but its content is empty; native dispatch proceeds with no prompt"
    )

    :ok
  end

  defp log_native_prompt_fidelity(%Responsibility{} = responsibility, _agent, {:absent, :legacy}) do
    case Providers.feature_provider(responsibility.feature) do
      {:ok, module} ->
        Logger.debug(
          "[ResponsibilityRouter] native signal carries no prompt key=#{responsibility.key} — " <>
            "provider #{inspect(module)} ships no build_prompt/1"
        )

      {:retired, reason} ->
        Logger.debug(
          "[ResponsibilityRouter] native signal carries no prompt key=#{responsibility.key} — " <>
            "feature=#{inspect(responsibility.feature)} is retired by design: #{reason}"
        )

      :error ->
        Logger.warning(
          "[ResponsibilityRouter] native signal carries no prompt key=#{responsibility.key} — " <>
            "feature=#{inspect(responsibility.feature)} has no provider registered. Fix: add " <>
            "it to Platform.Responsibilities.Providers @feature_providers, or to @retired " <>
            "with a reason."
        )
    end

    :ok
  end

  defp native_reason_for(:chat_pattern), do: :mention
  defp native_reason_for(:webhook), do: :system_event
  defp native_reason_for(:event_topic), do: :system_event
  defp native_reason_for(:cron), do: :system_event
  defp native_reason_for(_), do: :system_event

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Test seam — tests can override the native dispatch surface via
  # `Application.put_env(:platform, :responsibility_router_native_dispatcher,
  # {Module, :function})` so unit tests don't have to stand up a real
  # AgentResponder + chat space + sandbox-permitted Task. Production
  # always uses `Platform.Chat.AgentResponder.maybe_dispatch/1`.
  #
  # `{:ok, :dispatched}` here means the HANDOFF was accepted, not that the
  # agent responded — see the honesty-limit section on `fire_trigger/3`.
  @spec call_agent_responder(map()) :: {:ok, :dispatched} | {:error, term()}
  defp call_agent_responder(signal) do
    {mod, fun} =
      Application.get_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {Platform.Chat.AgentResponder, :maybe_dispatch}
      )

    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 1) do
      case apply(mod, fun, [signal]) do
        {:error, reason} -> {:error, {:native_dispatch_failed, reason}}
        _ -> {:ok, :dispatched}
      end
    else
      Logger.info(
        "[ResponsibilityRouter] native dispatcher #{inspect(mod)}.#{fun}/1 not loaded — " <>
          "skipping native dispatch"
      )

      {:error, {:native_dispatcher_unavailable, mod, fun}}
    end
  rescue
    error ->
      Logger.warning(
        "[ResponsibilityRouter] native dispatcher raised: " <>
          Exception.message(error)
      )

      {:error, {:native_dispatch_raised, Exception.message(error)}}
  end

  # ── Telemetry helpers ─────────────────────────────────────────────────────

  defp emit_fired_telemetry(%Responsibility{} = responsibility, agent, dispatch_kind) do
    :telemetry.execute(
      [:platform, :responsibility, :fired],
      %{system_time: System.system_time()},
      %{
        key: responsibility.key,
        feature: responsibility.feature,
        dispatch_kind: dispatch_kind,
        agent_slug: agent_slug(agent)
      }
    )
  rescue
    _ -> :ok
  end

  defp emit_failed_telemetry(%Responsibility{} = responsibility, agent, dispatch_kind, reason) do
    :telemetry.execute(
      [:platform, :responsibility, :failed],
      %{system_time: System.system_time()},
      %{
        key: responsibility.key,
        feature: responsibility.feature,
        dispatch_kind: dispatch_kind,
        agent_slug: agent_slug(agent),
        reason: inspect(reason)
      }
    )
  rescue
    _ -> :ok
  end

  defp agent_slug(%{slug: slug}) when is_binary(slug), do: slug
  defp agent_slug(%{"slug" => slug}) when is_binary(slug), do: slug
  defp agent_slug(_), do: "unknown"

  # Tolerant lookup so the Router doesn't crash if `Platform.Roles` is
  # absent from a stripped build (mirrors the M4-absence guard the
  # M6 planner contracted for).
  #
  # `DBConnection.OwnershipError` is handled explicitly and logged at
  # `:debug` rather than `:warning` because it is expected behaviour
  # when a `Task.Supervisor`-spawned process (which is not part of the
  # DataCase sandbox owner chain) reaches this seam during test runs.
  # We treat it identically to "no assignee" so `responsibility_filled?/1`
  # and `fire_trigger/3` both fall through to their nil-safe branches.
  defp safe_assignee_for(responsibility_key) do
    if Code.ensure_loaded?(Platform.Roles) and
         function_exported?(Platform.Roles, :assignee_for, 1) do
      try do
        Platform.Roles.assignee_for(responsibility_key)
      rescue
        DBConnection.OwnershipError ->
          Logger.debug(
            "[ResponsibilityRouter] sandbox-owned DB call from Task.Supervised " <>
              "— treating as unfilled key=#{responsibility_key}"
          )

          nil

        error ->
          Logger.warning(
            "[ResponsibilityRouter] Roles.assignee_for/1 raised " <>
              "key=#{responsibility_key}: #{Exception.message(error)}"
          )

          nil
      end
    else
      nil
    end
  end

  # Tolerant stamp so we don't crash if the canonical writer hasn't
  # landed yet. The canonical writer DID land, as
  # `Platform.Responsibilities.Registry.stamp_last_successful_fire/2`
  # (registry.ex:143) — so the probe below resolves to that branch on
  # every real call.
  #
  # Task 01a01041 stage 2: this `cond` used to open with a probe for
  # `Platform.ExternalAgents.stamp_last_successful_fire/2`, the OTHER
  # name the M6 planner contracted for. That function was never written
  # on `Platform.ExternalAgents` (which only READS
  # `last_successful_fire_at`, via `fired_within?/3`), so the compiler
  # flagged the call as undefined-or-private for as long as the branch
  # existed. It was never a live `UndefinedFunctionError`: the
  # `function_exported?/3` guard in the same clause is false, so the body
  # was unreachable, and the branch has been removed rather than the
  # function restored. Removing it is behaviour-preserving by
  # construction — nothing could reach it.
  defp safe_stamp_last_fire(agent, fired_at) do
    cond do
      Code.ensure_loaded?(Platform.Responsibilities.Registry) and
          function_exported?(
            Platform.Responsibilities.Registry,
            :stamp_last_successful_fire,
            2
          ) ->
        Platform.Responsibilities.Registry.stamp_last_successful_fire(agent, fired_at)

      true ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[ResponsibilityRouter] stamp_last_successful_fire raised: " <>
          Exception.message(error)
      )

      :ok
  end

  # Gate on Registry being loaded so the Router boots cleanly in
  # stripped builds. The actual list of rows comes from the
  # Responsibilities context, which is the canonical query surface
  # documented in `Platform.Responsibilities.get_by_trigger/1`.
  defp walk_registry do
    if Code.ensure_loaded?(Platform.Responsibilities.Registry) do
      by_trigger =
        Map.new(@trigger_kinds, fn kind ->
          {bucket_key(kind), safe_get_by_trigger(kind)}
        end)

      snapshot =
        @trigger_kinds
        |> Enum.flat_map(fn kind -> Map.fetch!(by_trigger, bucket_key(kind)) end)

      {snapshot, by_trigger}
    else
      Logger.info("[ResponsibilityRouter] registry not loaded, idling")
      {[], empty_buckets()}
    end
  end

  defp safe_get_by_trigger(kind) do
    Responsibilities.get_by_trigger(kind)
  rescue
    error ->
      Logger.warning(
        "[ResponsibilityRouter] get_by_trigger/1 raised for kind=#{inspect(kind)}: " <>
          Exception.message(error)
      )

      []
  end

  # The state's by_trigger map uses plural keys for the three multi-row
  # buckets (event_topics, chat_patterns, webhooks) to match the
  # convention later stages already assume. `cron` stays singular
  # because the cron bucket is one logical "queue" of fire-times rather
  # than a list of independent topics.
  defp bucket_key(:cron), do: :cron
  defp bucket_key(:event_topic), do: :event_topics
  defp bucket_key(:chat_pattern), do: :chat_patterns
  defp bucket_key(:webhook), do: :webhooks

  defp empty_buckets do
    %{cron: [], event_topics: [], chat_patterns: [], webhooks: []}
  end
end

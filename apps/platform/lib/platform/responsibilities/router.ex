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
  resolved by camelcasing the responsibility's `feature` field and
  prepending `Platform.Responsibilities.Providers.` — so
  `feature == "meetings"` resolves to
  `Platform.Responsibilities.Providers.Meetings`. The handler is
  optional: missing modules / missing `handle_output/3` log
  `[ResponsibilityRouter] no output handler for <key>` and return `:ok`
  rather than crashing. This keeps stage 6 a no-op for feature areas
  whose providers haven't grown a handler yet (e.g. M6-only deploys
  before M8 lands `meetings.summarize`).

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
  """

  use GenServer

  require Logger

  alias Platform.Chat.Message
  alias Platform.ExternalAgents.Dispatcher, as: ExternalDispatcher
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.{ContextGatherer, Cron, Responsibility}

  @default_check_interval_ms :timer.seconds(60)

  @trigger_kinds [:cron, :event_topic, :chat_pattern, :webhook]

  @pubsub Platform.PubSub

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
          chat_telemetry_handler_id: binary()
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

    {snapshot, by_trigger} = walk_registry()

    cron_next_fire = compute_initial_cron_schedule(by_trigger.cron, DateTime.utc_now())

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
      chat_telemetry_handler_id: chat_telemetry_handler_id
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
  Unknown keys log + return `{:error, :unknown_responsibility}` rather
  than crashing; the dual-write shim treats this as "router path
  no-op" so legacy dispatch isn't blocked.

  The supplied `trigger_meta` is passed through to `fire_trigger/2`
  verbatim; callers should set `:kind` (e.g. `:cron`, `:webhook`) and
  any feature-specific keys (`:workspace_id`, `:date`, etc.).
  """
  @spec fire(atom() | binary(), map()) :: :ok | {:error, term()}
  def fire(key, trigger_meta \\ %{}) when is_map(trigger_meta) do
    canonical = canonical_key(key)

    case lookup_by_key(canonical) do
      %Responsibility{} = responsibility ->
        fire_trigger(responsibility, trigger_meta)

      nil ->
        Logger.info(
          "[ResponsibilityRouter] fire/2 no row for key=#{inspect(canonical)} — skipping"
        )

        {:error, :unknown_responsibility}
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

  @impl GenServer
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    {new_next, new_last} =
      Enum.reduce(
        state.by_trigger.cron,
        {state.cron_next_fire, state.cron_last_fire},
        fn responsibility, {next_acc, last_acc} ->
          maybe_fire_cron(responsibility, now, next_acc, last_acc)
        end
      )

    schedule_check(state.check_interval_ms)
    {:noreply, %{state | cron_next_fire: new_next, cron_last_fire: new_last}}
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

  # PubSub broadcasts arrive as a 2-tuple `{topic, payload}` from any
  # publisher that uses our convention (see `Platform.Org.Wiki` etc.).
  # Only fan out if the topic was actually subscribed at boot — otherwise
  # the message is for someone else who happens to share our process tree.
  @impl GenServer
  def handle_info({topic, payload}, state)
      when is_binary(topic) do
    if MapSet.member?(state.subscribed_topics, topic) do
      fire_event_topic(topic, payload, state)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({topic, payload}, state) when is_atom(topic) and not is_nil(topic) do
    topic_str = Atom.to_string(topic)

    if MapSet.member?(state.subscribed_topics, topic_str) do
      fire_event_topic(topic_str, payload, state)
    end

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
    matches =
      Enum.filter(state.by_trigger.event_topics, fn responsibility ->
        config_topic(responsibility) == topic
      end)

    Enum.each(matches, fn responsibility ->
      fire_trigger(
        responsibility,
        %{kind: :event_topic, topic: topic, payload: payload},
        state
      )
    end)
  end

  defp config_topic(%Responsibility{trigger_config: config}) do
    Map.get(config, "topic") || Map.get(config, :topic)
  end

  defp config_path(%Responsibility{trigger_config: config}) do
    Map.get(config, "path") || Map.get(config, :path)
  end

  # ── Cron firing ───────────────────────────────────────────────────────────

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
        fire_trigger(responsibility, %{kind: :cron, fired_at: now})

        next_acc =
          case compute_next_fire(responsibility, now) do
            {:ok, dt} -> Map.put(next_acc, id, dt)
            :error -> Map.delete(next_acc, id)
          end

        {next_acc, Map.put(last_acc, id, now)}
    end
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

    if is_binary(expression) do
      with {:ok, spec} <- Cron.parse(expression),
           {:ok, dt} <- Cron.next_fire_after(now, spec) do
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
  # place. The function never raises: an unfilled responsibility
  # emits telemetry + an info log and returns `:ok`. This is the
  # "progressive enhancement" contract from ADR-0041 — an empty Roles
  # table is a perfectly valid system state.

  @doc """
  Fire a trigger through the canonical pipeline.

  Looks up the assignee via `Platform.Roles.assignee_for/1`, then:

    * if no agent is assigned → telemetry
      `[:platform, :responsibility, :unfilled]` + info log, returns `:ok`
    * if the agent is `kind == "external"` → gather context via
      `ContextGatherer.gather/2`, call
      `Platform.ExternalAgents.Dispatcher.dispatch/3`, hand the parsed
      response to the provider's `handle_output/3` (when present),
      stamp `last_successful_fire_at`, emit
      `[:platform, :responsibility, :fired]` telemetry.
    * if the agent is `kind == "native"` (alias: `"local"` /
      `"federated"`) → build the AgentResponder signal shape (mirrors
      `Platform.Agents.HistorianDispatcher`'s) and hand off via
      `Platform.Chat.AgentResponder.maybe_dispatch/1`. The Router
      remains a drop-in dispatch surface for the existing native path —
      `SystemEventScheduler` keeps running alongside until M8 cuts the
      historian event over to a responsibility row.

  Failure modes (HTTP error, contract violation, native context
  resolution) log + emit `[:platform, :responsibility, :failed]` and
  return `:ok` — the Router never crashes the GenServer for a single
  fired trigger.

  Called from `handle_info(:tick, …)` for cron triggers, and from the
  event_topic, chat_pattern, and webhook handlers. Public so tests
  can drive it directly without standing up a fully-populated cron
  schedule.
  """
  @spec fire_trigger(Responsibility.t(), map()) :: :ok
  def fire_trigger(%Responsibility{} = responsibility, trigger_meta) when is_map(trigger_meta) do
    fire_trigger(responsibility, trigger_meta, %{})
  end

  @spec fire_trigger(Responsibility.t(), map(), map()) :: :ok
  def fire_trigger(%Responsibility{} = responsibility, trigger_meta, _state)
      when is_map(trigger_meta) do
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

          :ok

        %{kind: "external"} = agent ->
          dispatch_external(responsibility, agent, trigger_meta)

        %{kind: kind} = agent when kind in ["native", "local", "federated"] ->
          dispatch_native(responsibility, agent, trigger_meta, kind)

        other ->
          Logger.warning(
            "[ResponsibilityRouter] unknown assignee shape key=#{responsibility.key} " <>
              "assignee=#{inspect(other)}"
          )

          :ok
      end
    rescue
      DBConnection.OwnershipError ->
        # A downstream DB touch (dispatch_external → gather_context_via_provider →
        # ContextGatherer.gather, dispatch_native → context resolution, etc.)
        # raised from a Task.Supervised child whose $callers chain doesn't reach
        # the DataCase sandbox owner. Contract: the Router never crashes the
        # GenServer for a single fired trigger — swallow at :debug.
        Logger.debug(
          "[ResponsibilityRouter] fire_trigger swallowed sandbox-owned DB call " <>
            "key=#{responsibility.key}"
        )

        :ok

      error ->
        Logger.warning(
          "[ResponsibilityRouter] fire_trigger raised for key=#{responsibility.key}: " <>
            Exception.message(error)
        )

        :ok
    catch
      :exit, reason ->
        Logger.warning(
          "[ResponsibilityRouter] fire_trigger caught exit for key=#{responsibility.key}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  # ── External dispatch ─────────────────────────────────────────────────────

  defp dispatch_external(%Responsibility{} = responsibility, agent, trigger_meta) do
    provider_module = provider_module_for(responsibility.feature)

    context =
      provider_module
      |> gather_context_via_provider(responsibility, trigger_meta)
      |> Map.put(:__responsibility__, responsibility)

    case build_prompt_via_provider(provider_module, context) do
      {:error, reason} ->
        Logger.warning(
          "[ResponsibilityRouter] provider build_prompt refused dispatch " <>
            "key=#{responsibility.key} agent=#{agent_slug(agent)} reason=#{inspect(reason)}"
        )

        emit_failed_telemetry(responsibility, agent, :external, {:build_prompt_refused, reason})
        :ok

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
        :ok

      {:error, reason} ->
        Logger.warning(
          "[ResponsibilityRouter] external dispatch failed key=#{responsibility.key} " <>
            "agent=#{agent_slug(agent)} reason=#{inspect(reason)}"
        )

        emit_failed_telemetry(responsibility, agent, :external, reason)
        :ok
    end
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
  # under `meta[:payload][:transcript_id]`. Falls back to the
  # cross-cutting `ContextGatherer` path when the provider is absent
  # or returns an error.
  defp gather_context_via_provider(provider_module, %Responsibility{} = responsibility, meta) do
    with true <- is_atom(provider_module),
         true <- Code.ensure_loaded?(provider_module),
         true <- function_exported?(provider_module, :gather_context, 2),
         {:ok, ctx} when is_map(ctx) <-
           safe_provider_gather(provider_module, responsibility, meta) do
      ctx
    else
      _ -> gather_context(responsibility, meta)
    end
  end

  defp safe_provider_gather(provider_module, responsibility, meta) do
    provider_module.gather_context(responsibility, meta)
  rescue
    error ->
      Logger.warning(
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
        Logger.info("[ResponsibilityRouter] no output handler for #{responsibility.key}")
        :ok
    end
  end

  defp invoke_handle_output(%Responsibility{} = responsibility, _parsed, _meta) do
    Logger.info("[ResponsibilityRouter] no output handler for #{responsibility.key}")
    :ok
  end

  # Convention: `<feature>` → `Platform.Responsibilities.Providers.<Camelcased>`.
  # `feature == "meetings"` resolves to
  # `Platform.Responsibilities.Providers.Meetings`. Returns `nil` if the
  # camelcase fails (e.g. an empty / non-binary feature).
  defp provider_module_for(feature) when is_binary(feature) and feature != "" do
    Module.concat([Platform.Responsibilities.Providers, Macro.camelize(feature)])
  end

  defp provider_module_for(_), do: nil

  # ── Native / federated dispatch ───────────────────────────────────────────

  defp dispatch_native(%Responsibility{} = responsibility, agent, trigger_meta, kind) do
    signal = build_native_signal(responsibility, agent, trigger_meta)

    Logger.info(
      "[ResponsibilityRouter] #{kind} dispatch key=#{responsibility.key} " <>
        "agent=#{agent_slug(agent)} signal=#{inspect(Map.take(signal, [:reason, :space_id]))}"
    )

    _ = call_agent_responder(signal)

    safe_stamp_last_fire(agent, Map.get(trigger_meta, :fired_at) || DateTime.utc_now())

    emit_fired_telemetry(responsibility, agent, :native)
    :ok
  end

  # Builds an AgentResponder-shaped signal so the Router is a drop-in
  # replacement for SystemEventScheduler's hand-off. We omit `message_id`
  # when there isn't one (e.g. cron-fired native responsibilities) — the
  # AgentResponder treats nil ids as "synthesize a system instruction"
  # and the historian path is the precedent.
  defp build_native_signal(%Responsibility{} = responsibility, agent, trigger_meta) do
    reason = native_reason_for(Map.get(trigger_meta, :kind))

    base = %{
      reason: reason,
      metadata: %{
        responsibility_key: responsibility.key,
        feature: responsibility.feature,
        trigger_kind: Map.get(trigger_meta, :kind),
        agent_id: Map.get(agent, :id) || Map.get(agent, "id"),
        agent_slug: agent_slug(agent)
      }
    }

    base
    |> maybe_put(:message_id, Map.get(trigger_meta, :message_id))
    |> maybe_put(:space_id, Map.get(trigger_meta, :space_id))
    |> maybe_put(:participant_id, Map.get(trigger_meta, :participant_id))
    |> maybe_put(:meeting_id, Map.get(trigger_meta, :meeting_id))
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
  defp call_agent_responder(signal) do
    {mod, fun} =
      Application.get_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {Platform.Chat.AgentResponder, :maybe_dispatch}
      )

    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 1) do
      apply(mod, fun, [signal])
    else
      Logger.info(
        "[ResponsibilityRouter] native dispatcher #{inspect(mod)}.#{fun}/1 not loaded — " <>
          "skipping native dispatch"
      )

      :ok
    end
  rescue
    error ->
      Logger.warning(
        "[ResponsibilityRouter] native dispatcher raised: " <>
          Exception.message(error)
      )

      :ok
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
  # landed yet. The expected writer surface in later stages is either
  # `Platform.ExternalAgents.stamp_last_successful_fire/2` (extended
  # to cover native agents too) or a dedicated
  # `Platform.Responsibilities.Registry.stamp_last_successful_fire/2`.
  # We probe both names and short-circuit to `:ok` if neither exists,
  # exactly as the M6 planner contracted for.
  defp safe_stamp_last_fire(agent, fired_at) do
    cond do
      Code.ensure_loaded?(Platform.ExternalAgents) and
          function_exported?(Platform.ExternalAgents, :stamp_last_successful_fire, 2) ->
        Platform.ExternalAgents.stamp_last_successful_fire(agent, fired_at)

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

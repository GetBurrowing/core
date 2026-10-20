defmodule Platform.Role.Relay do
  @moduledoc """
  Carries telemetry from a web node to the full node it is clustered with
  (task 01a155a6 stage 3).

  ## Why telemetry needs a bridge

  A web node and its full peer share `Platform.PubSub` over distributed
  Erlang (see `Platform.Role.PeerLink`), so every PubSub-driven background
  consumer on the full node (`TaskRouterWatcher`, `Wiki.Indexer`,
  `MeetingNotifier`, ...) already receives a web node's broadcasts, once,
  because the web node runs none of them. `:telemetry` is different: it is
  node-local. `Platform.Chat.AttentionRouter` routes a message to agents from
  `[:platform, :chat, :message_posted]`, not from PubSub, so without this
  module a message posted on the web node is stored and shown but never
  reaches an agent.

  ## The three parts

    * this module's handler, attached by `Platform.Application.start/2` under
      `:web` only, to every event in `events/0`. It broadcasts
      `{:role_relay, event, measurements, metadata}` on `"platform:role_relay"`;
    * `Platform.Role.RelayReceiver`, a background child (full role only), which
      subscribes and re-executes each one as `twin(event)`, that is
      `[:platform, :role_relay | event]`;
    * the consumers in `consumers/0`, which attach to each event they consume
      AND to its twin, through `attach_many/4`. The twins are attached under
      a separate id with a handler that cannot be detached by a malformed
      relayed event (stage 4; see `attach_many/4`).

  ## Exactly once

  The handlers `Platform.Application.start/2` attaches on both roles (Audit,
  Vault, Chat, Meetings, IntentCorrections, Memory, ExternalAdmission) attach
  to the ORIGINAL events only. A message posted on the web node is therefore
  audited once, on the web node, and routed once, on the full node through the
  twin. A message posted on the full node never touches the relay: the handler
  is not attached there, and is inert if it ever is (`handle_event/4` checks
  the role per event).

  ## `events/0` is derived

  It is the union of `relayed_events/0` over `consumers/0`, and each consumer
  attaches with the same list it reports, so the relay cannot forward an event
  no consumer reads or miss one a consumer reads.
  `test/platform/role/relay_test.exs` checks the live twin attachments
  against it.

  ## Limitation

  Fire-and-forget. While the web node is disconnected from its peer, a
  message posted there is stored but never routed to agents, and nothing
  replays it on reconnect.

  ## Trust

  Clustering with a shared cookie means any code the web node runs can run
  code on the full node. See `Platform.Role`.
  """

  require Logger

  @handler_id "platform-role-relay"
  @topic "platform:role_relay"
  @prefix [:platform, :role_relay]

  # Background children that consume `:telemetry`. Each exports
  # `relayed_events/0` and attaches through `attach_many/4`.
  @consumers [
    Platform.Chat.AttentionRouter,
    Platform.Chat.ContextPlane,
    Platform.Responsibilities.Router,
    Platform.Responsibilities.CutoverMonitor,
    Platform.Files.CatalogEmitter
  ]

  @doc "The PubSub topic relayed events travel on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "This handler's `:telemetry` id."
  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id

  @doc "The background telemetry consumers that attach to relayed twins."
  @spec consumers() :: [module()]
  def consumers, do: @consumers

  @doc "Every event the relay forwards: the union of each consumer's `relayed_events/0`."
  @spec events() :: [:telemetry.event_name()]
  def events do
    @consumers
    |> Enum.flat_map(& &1.relayed_events())
    |> Enum.uniq()
  end

  @doc "The relayed twin of `event`: `[:platform, :role_relay | event]`."
  @spec twin(:telemetry.event_name()) :: :telemetry.event_name()
  def twin(event), do: @prefix ++ event

  @doc "True when `event` is a relayed twin."
  @spec twin?(:telemetry.event_name()) :: boolean()
  def twin?([:platform, :role_relay | _]), do: true
  def twin?(_event), do: false

  @doc """
  Attach a consumer's handler to `events` under `handler_id`, and to each
  one's twin under `twin_handler_id(handler_id)`. The one helper every
  consumer in `consumers/0` uses, so the twin rule is written once.

  ## Why two ids (task 01a155a6 stage 4)

  `:telemetry` detaches a handler that raises or exits, for every event it
  is attached to and for the rest of the VM's life. A twin carries metadata a
  web peer built, possibly on another branch with another shape. Under one
  id, a twin that made the handler raise would detach the ORIGINAL-event
  handler too, and the full node would silently stop routing its own
  messages. So the twins get their own id, and their handler is
  `handle_twin/4`, which calls the consumer's function inside
  `try/rescue/catch`, logs a failure and returns `:ok`: a malformed twin
  costs that one event and nothing else. The original-event attachment is
  the consumer's function, unwrapped, exactly as before.

  Returns `:ok`, or `{:error, :already_exists}` when either id is taken.
  """
  @spec attach_many(
          String.t(),
          [:telemetry.event_name()],
          :telemetry.handler_function(),
          :telemetry.handler_config()
        ) :: :ok | {:error, :already_exists}
  def attach_many(handler_id, events, function, config) when is_binary(handler_id) do
    with :ok <- :telemetry.attach_many(handler_id, events, function, config) do
      :telemetry.attach_many(
        twin_handler_id(handler_id),
        Enum.map(events, &twin/1),
        &__MODULE__.handle_twin/4,
        %{function: function, config: config}
      )
    end
  end

  @doc "Detach both ids `attach_many/4` attached. Idempotent."
  @spec detach_many(String.t()) :: :ok
  def detach_many(handler_id) when is_binary(handler_id) do
    _ = :telemetry.detach(handler_id)
    _ = :telemetry.detach(twin_handler_id(handler_id))
    :ok
  end

  @doc "The id a consumer's twin attachment carries: `handler_id <> \".relay\"`."
  @spec twin_handler_id(String.t()) :: String.t()
  def twin_handler_id(handler_id) when is_binary(handler_id), do: handler_id <> ".relay"

  @doc """
  The handler every twin attachment runs: the consumer's own function, with
  a raise, throw or exit logged and swallowed so `:telemetry` never detaches
  it. See `attach_many/4`.
  """
  @spec handle_twin(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          %{function: :telemetry.handler_function(), config: :telemetry.handler_config()}
        ) :: :ok
  def handle_twin(event, measurements, metadata, %{function: function, config: config}) do
    function.(event, measurements, metadata, config)
    :ok
  rescue
    error ->
      Logger.error(
        "[Role.Relay] relayed #{inspect(event)} raised in #{inspect(function)}: " <>
          Exception.message(error)
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "[Role.Relay] relayed #{inspect(event)} #{kind} in #{inspect(function)}: " <>
          inspect(reason, limit: 10)
      )

      :ok
  end

  @doc """
  Attach the relay handler to `events/0`. Called by
  `Platform.Application.start/2` under `:web`. Idempotent.
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, events(), &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the relay handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc """
  Broadcast one event to the full peer. Inert unless this node's role is
  `:web`, so a stray attach on a full node cannot double-route. Never raises
  or exits: `:telemetry` would detach it, and the web node would silently stop
  routing to agents.
  """
  @spec handle_event(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: :ok
  def handle_event(event, measurements, metadata, _config) do
    if Platform.Role.web?() do
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        @topic,
        {:role_relay, event, measurements, metadata}
      )
    end

    :ok
  rescue
    error ->
      Logger.error(
        "[Role.Relay] broadcast of #{inspect(event)} raised: #{Exception.message(error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.error("[Role.Relay] broadcast of #{inspect(event)} #{kind}: #{inspect(reason)}")
      :ok
  end
end

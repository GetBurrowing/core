defmodule Platform.Federation.DeliveryQueue do
  @moduledoc """
  Chat messages to an external runtime are held until they are delivered,
  instead of being failed the moment a broadcast cannot go out.

  Before this, `Platform.Chat.AgentResponder` had two outcomes for a message
  addressed to an external agent:

    * the runtime was not in presence (a deploy restart drops every runtime
      socket for a few seconds): the message was dead-lettered as
      `chat_payload_not_replayable` and the sender got an instant "couldn't
      reply" notice. The agent never saw it;
    * the broadcast went out: logged as "sent successfully", although a
      broadcast is not a delivery. Nothing noticed when the runtime never got
      it.

  ## What it does

    * `hold/3`: the runtime is offline at dispatch. The message waits here,
      and the sender sees "Waiting for <Agent>". When the runtime joins
      (`runtime_joined/1`, called from `PlatformWeb.RuntimeChannel.join/3`)
      every held message is dispatched again. A message still held after the
      TTL (`ttl_ms/0`) gets the reply-failure notice it would have got
      before, once.
    * `sent/4`: the broadcast went out. For a runtime whose plugin declares
      the `attention_ack` feature, the message waits for an
      `attention_ack` frame naming its `message_id` (`ack/2`); with no ack
      inside `ack_timeout_ms/0`, or when the runtime rejoins first, it is
      dispatched again. A runtime without the feature is not tracked past
      the broadcast: an old plugin would run a duplicate turn on a
      redelivery, and it has no way to say it already got one.

  A redelivery re-runs `AgentResponder.redeliver/2` from the stored signal,
  so the context, history and tools are rebuilt at delivery time rather than
  replayed from a stale snapshot (the reason the dead letter was never
  replayable). It is skipped when the agent has already answered.

  ## Bounds

  One entry per `{runtime_id, message_id}` (a redelivery updates it, never
  adds one), at most `max_attempts/0` dispatches per message, and nothing
  survives `ttl_ms/0` from the first attempt. State is in this process and
  per node: a restart forgets held messages, which costs at most what the
  old behaviour cost.

  Off when `:delivery_queue_enabled` is false (the test env default, so a
  hold armed by one test never redelivers into another).
  """

  use GenServer

  require Logger

  alias Platform.Chat.PubSub, as: ChatPubSub

  @ack_feature "attention_ack"
  @default_ttl_ms 15 * 60_000
  @default_ack_timeout_ms 20_000
  @default_max_attempts 5
  @rejoin_delay_ms 1_000

  @type info :: %{
          required(:agent_id) => binary(),
          required(:message_id) => binary(),
          required(:space_id) => binary(),
          optional(:agent_participant_id) => binary() | nil,
          optional(:agent_name) => String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The `client_info.features` entry a runtime sends when it acks deliveries."
  @spec ack_feature() :: String.t()
  def ack_feature, do: @ack_feature

  @doc "True when the queue is on (`config :platform, :delivery_queue_enabled`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:platform, :delivery_queue_enabled, true) == true

  @doc "How long a held message waits for its runtime, in ms (`DELIVERY_QUEUE_TTL_S`)."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: pos_env(:delivery_queue_ttl_ms, @default_ttl_ms)

  @doc "How long a sent message waits for its `attention_ack`, in ms."
  @spec ack_timeout_ms() :: pos_integer()
  def ack_timeout_ms, do: pos_env(:delivery_queue_ack_timeout_ms, @default_ack_timeout_ms)

  @doc "The most dispatches one message gets, the first included."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: pos_env(:delivery_queue_max_attempts, @default_max_attempts)

  @doc """
  True when `runtime`'s last declared `client_info.features` include
  `attention_ack`. Read off the persisted runtime row.
  """
  @spec acks?(map() | nil) :: boolean()
  def acks?(%{metadata: %{"client_info" => %{"features" => features}}}) when is_list(features),
    do: @ack_feature in features

  def acks?(_runtime), do: false

  @doc """
  Hold `signal` for `runtime_id`, which is offline. Returns `:queued`, or
  `:exhausted` when this message has had its attempts or its TTL (the caller
  then fails it as before), or `:disabled`.
  """
  @spec hold(binary(), map(), info()) :: :queued | :exhausted | :disabled
  def hold(runtime_id, signal, info) when is_binary(runtime_id) do
    call({:hold, runtime_id, slim(signal), info}, :disabled)
  end

  @doc """
  The broadcast of `signal` to `runtime_id` went out. With `acks? == true`
  the message waits for its ack; otherwise it is forgotten. Always `:ok`.
  """
  @spec sent(binary(), map(), info(), boolean()) :: :ok
  def sent(runtime_id, signal, info, acks?) when is_binary(runtime_id) do
    _ = call({:sent, runtime_id, slim(signal), info, acks? == true}, :ok)
    :ok
  end

  @doc "The runtime acked `message_id`. Returns `:ok`, or `:unknown` for nothing pending."
  @spec ack(binary(), binary()) :: :ok | :unknown
  def ack(runtime_id, message_id) when is_binary(runtime_id) and is_binary(message_id) do
    call({:ack, runtime_id, message_id}, :unknown)
  end

  @doc "The runtime (re)joined: redeliver everything held or unacked for it, shortly."
  @spec runtime_joined(binary()) :: :ok
  def runtime_joined(runtime_id) when is_binary(runtime_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> Process.send_after(pid, {:drain, runtime_id}, @rejoin_delay_ms)
      _ -> :ok
    end

    :ok
  end

  @doc """
  The messages held for an offline runtime in `space_id`, as
  `%{agent_participant_id => busy}` in `Platform.Chat.PubSub.broadcast_agent_busy/3`'s
  shape. For a LiveView entering the space.
  """
  @spec held_in_space(binary()) :: %{binary() => map()}
  def held_in_space(space_id) when is_binary(space_id) do
    call({:held_in_space, space_id}, %{})
  end

  @doc "Every entry. For tests and the console."
  @spec entries() :: [map()]
  def entries, do: call(:entries, [])

  # ── Server ─────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:hold, runtime_id, signal, info}, _from, state) do
    if enabled?() do
      key = {runtime_id, info.message_id}
      attempt = attempt(signal)

      case Map.get(state, key) do
        %{} = entry ->
          if attempt > max_attempts() or expired?(entry) do
            {:reply, :exhausted, Map.delete(state, key)}
          else
            if entry.state != :held, do: broadcast_held(entry)
            entry = %{entry | state: :held, signal: signal, attempts: attempt, shown: true}
            maybe_drain_now(runtime_id)
            {:reply, :queued, Map.put(state, key, entry)}
          end

        nil ->
          entry = new_entry(runtime_id, signal, info, :held, attempt)
          Process.send_after(self(), {:expire, key}, ttl_ms())
          broadcast_held(entry)
          maybe_drain_now(runtime_id)
          {:reply, :queued, Map.put(state, key, entry)}
      end
    else
      {:reply, :disabled, state}
    end
  end

  def handle_call({:sent, runtime_id, signal, info, acks?}, _from, state) do
    key = {runtime_id, info.message_id}
    previous = Map.get(state, key)
    if previous, do: clear_held(previous)

    cond do
      not enabled?() or not acks? ->
        {:reply, :ok, Map.delete(state, key)}

      true ->
        attempt = attempt(signal)

        entry =
          case previous do
            %{} = entry ->
              %{entry | state: :awaiting_ack, signal: signal, attempts: attempt, shown: false}

            nil ->
              Process.send_after(self(), {:expire, key}, ttl_ms())
              new_entry(runtime_id, signal, info, :awaiting_ack, attempt)
          end

        Process.send_after(self(), {:ack_timeout, key, attempt}, ack_timeout_ms())
        {:reply, :ok, Map.put(state, key, entry)}
    end
  end

  def handle_call({:ack, runtime_id, message_id}, _from, state) do
    key = {runtime_id, message_id}

    case Map.pop(state, key) do
      {nil, state} ->
        {:reply, :unknown, state}

      {entry, state} ->
        clear_held(entry)
        {:reply, :ok, state}
    end
  end

  def handle_call({:held_in_space, space_id}, _from, state) do
    held =
      for {_key, %{state: :held, space_id: ^space_id} = entry} <- state,
          is_binary(entry.agent_participant_id),
          into: %{},
          do: {entry.agent_participant_id, held_busy(entry)}

    {:reply, held, state}
  end

  def handle_call(:entries, _from, state), do: {:reply, Map.values(state), state}

  @impl true
  def handle_info({:drain, runtime_id}, state) do
    {due, rest} = Enum.split_with(state, fn {{rid, _}, _} -> rid == runtime_id end)
    # Each redelivery re-registers through hold/3 or sent/4 with its new
    # attempt number; keeping the entries meanwhile keeps the TTL anchored
    # to the first attempt. `:redelivering` keeps a stale ack timeout or a
    # second drain from dispatching the same message twice.
    due =
      Map.new(due, fn
        {key, %{state: :redelivering} = entry} ->
          {key, entry}

        {key, entry} ->
          redeliver(entry)
          {key, %{entry | state: :redelivering}}
      end)

    {:noreply, Map.merge(Map.new(rest), due)}
  end

  def handle_info({:ack_timeout, key, attempt}, state) do
    case Map.get(state, key) do
      %{state: :awaiting_ack, attempts: ^attempt} = entry ->
        if attempt < max_attempts() and not expired?(entry) do
          Logger.warning(
            "[DeliveryQueue] no attention_ack from runtime=#{entry.runtime_id} for message=#{entry.message_id} (attempt #{attempt}); redelivering"
          )

          redeliver(entry)
          {:noreply, Map.put(state, key, %{entry | state: :redelivering})}
        else
          Logger.warning(
            "[DeliveryQueue] giving up on ack from runtime=#{entry.runtime_id} for message=#{entry.message_id} after #{attempt} attempts"
          )

          {:noreply, Map.delete(state, key)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:expire, key}, state) do
    case Map.get(state, key) do
      %{state: entry_state} = entry when entry_state in [:held, :redelivering] ->
        if expired?(entry) do
          Logger.warning(
            "[DeliveryQueue] runtime=#{entry.runtime_id} did not come back for message=#{entry.message_id}; failing it"
          )

          clear_held(entry)
          undelivered(entry)
          {:noreply, Map.delete(state, key)}
        else
          Process.send_after(self(), {:expire, key}, remaining_ms(entry))
          {:noreply, state}
        end

      %{} = entry ->
        if expired?(entry) do
          {:noreply, Map.delete(state, key)}
        else
          Process.send_after(self(), {:expire, key}, remaining_ms(entry))
          {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ────────────────────────────────────────────────────────

  defp call(msg, default) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, msg)
      _ -> default
    end
  catch
    :exit, _ -> default
  end

  defp new_entry(runtime_id, signal, info, entry_state, attempt) do
    %{
      runtime_id: runtime_id,
      message_id: info.message_id,
      agent_id: info.agent_id,
      space_id: info.space_id,
      agent_participant_id: Map.get(info, :agent_participant_id),
      agent_name: Map.get(info, :agent_name),
      signal: signal,
      state: entry_state,
      attempts: attempt,
      # Whether the space was told "waiting" for this message, so the clear
      # never wipes a busy line the watchdog put up for the same agent.
      shown: entry_state == :held,
      first_at: now(),
      since: DateTime.utc_now()
    }
  end

  defp attempt(signal), do: Map.get(signal, :delivery_attempt, 1)

  # The frozen history snapshot of a parallel dispatch can be large, and a
  # redelivery rebuilds history at delivery time anyway.
  defp slim(signal) do
    case Map.get(signal, :metadata) do
      %{} = meta -> Map.put(signal, :metadata, Map.delete(meta, :frozen_history))
      _ -> signal
    end
  end

  defp expired?(entry), do: now() - entry.first_at >= ttl_ms()
  defp remaining_ms(entry), do: max(1, entry.first_at + ttl_ms() - now())

  defp maybe_drain_now(runtime_id) do
    # The runtime may have joined between the dispatcher's presence check
    # and this hold; its join drain then ran before the entry existed.
    if Platform.Federation.RuntimePresence.online?(runtime_id),
      do: Process.send_after(self(), {:drain, runtime_id}, @rejoin_delay_ms)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp redeliver(entry) do
    attempt = entry.attempts + 1

    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      try do
        if Platform.Chat.ReplyFailure.unanswered?(entry.agent_id, entry.message_id) do
          Platform.Chat.AgentResponder.redeliver(entry.signal, attempt)
        else
          _ = ack(entry.runtime_id, entry.message_id)
        end
      rescue
        DBConnection.OwnershipError -> :ok
      end
    end)
  end

  defp undelivered(entry) do
    :telemetry.execute(
      [:platform, :federation, :delivery_failed],
      %{system_time: System.system_time()},
      %{runtime_id: entry.runtime_id, agent_id: entry.agent_id, reason: :queue_ttl}
    )

    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      try do
        Platform.Chat.ReplyFailure.undelivered(entry)
      rescue
        DBConnection.OwnershipError -> :ok
      end
    end)
  end

  defp held_busy(entry) do
    %{state: "queued", activity: nil, since: entry.since, agent_name: entry.agent_name}
  end

  defp broadcast_held(%{agent_participant_id: pid} = entry) when is_binary(pid) do
    ChatPubSub.broadcast_agent_busy(entry.space_id, pid, held_busy(entry))
  end

  defp broadcast_held(_entry), do: :ok

  defp clear_held(%{agent_participant_id: pid, shown: true} = entry) when is_binary(pid) do
    ChatPubSub.broadcast_agent_busy(entry.space_id, pid, nil)
  end

  defp clear_held(_entry), do: :ok

  defp pos_env(key, default) do
    case Application.get_env(:platform, key, default) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> default
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end

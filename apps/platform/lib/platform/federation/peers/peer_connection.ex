defmodule Platform.Federation.Peers.PeerConnection do
  @moduledoc """
  The outbound side of ONE active peer relationship (task 01a0d90f stage 4,
  ADR 0054 section 4). One process per active peer, registered in
  `Platform.Federation.Peers.Registry` under `{:peer, peer_id}` and
  supervised by its own wrapper (`Platform.Federation.Peers.Supervisor`).

  ## What it holds

    * a bounded outbound `:queue` of `%{id, type, payload}` items. The cap
      is 1000 by default (`:queue_cap`). On overflow the OLDEST item is
      dropped and `resync_needed` is set. There is deliberately no outbox
      table: the chat table is the durable source, and the shared-space relay
      (stage 5) replays from its cursor when `resync_needed` is set and when
      a connection starts. A restart therefore loses only what the cursor
      replay re-sends;
    * exponential backoff with jitter between failed attempts, base 1 s and
      max 60 s (`:base_backoff_ms`, `:max_backoff_ms`), in the shape of
      `Platform.Federation.NodeClient`;
    * a circuit breaker. `:closed` sends normally. After 5 consecutive
      failures (`:failure_threshold`) it is `:open` and sends nothing until
      the backoff elapses; then it is `:half_open` and sends ONE probe. A
      successful probe closes it, a failed one re-opens it with a longer
      backoff.

  ## Nothing here raises on peer behaviour

  Every send goes through `Platform.Federation.Peers.Client.send_envelope/3`,
  the only outbound path, which returns values. The send runs in a short
  linked process of its own, so this GenServer stays responsive (to
  `enqueue/2` and `status/1`) while a slow peer holds a request open for up
  to the client's receive deadline. That sender is killed with this process
  (revoke, crash), and if it dies abnormally the attempt counts as a failure,
  as a value. Peer garbage, timeouts and non-2xx answers are failures, never
  exceptions.

  A slow peer blocks only its OWN sender: the queue for another peer lives
  in another process with another sender.

  The item's `id` is generated at enqueue and reused on every retry, so a
  retried envelope carries the same idempotency key; `ts` and `nonce` are
  fresh per attempt, so a retry is never refused as a replay or as stale.

  ## No payloads leave this process

  `status/1` reports breaker state, queue length and a SUMMARY of the last
  error (`error_class/1`), never an item. Telemetry carries `peer_id` and
  `outcome` only. `format_status/1` replaces the state, the last message and
  the mailbox in crash reports, because a crash report would otherwise print
  every queued payload.

  ## Shared-space relay (stage 5)

  The connection subscribes to the `Platform.Chat.PubSub` topic of each of
  the peer's ACTIVE shared spaces (`Platform.Federation.Peers.SharedSpaces`)
  and turns every relayable `{:new_message, msg}` into a queue item through
  `Platform.Federation.Peers.Relay` (owner: `message.replicate`, replica:
  `message.submit`; a `federation_inbound` message is never sent back). So
  `Chat.post_message/2` needs no hook of its own.

  A relay item carries the message id. The shared space's cursor
  (`outbound_cursor_message_id`) advances ONLY from the sender's result
  message, on a 2xx, never when the item is queued or sent.

  Replay from the cursor, bounded by the free queue space:

    * on EVERY start, whatever the cause. A crash or a kill loses the
      in-memory queue and does NOT set `resync_needed` (that is state of the
      process that died), so the cursor is the only record of what the peer
      has; replaying on every start covers it. A duplicate the peer already
      stored is harmless: its ingest is idempotent on the message id;
    * before the next send after an overflow (`resync_needed`): queued relay
      items are dropped and re-read from the chat table after the cursor, in
      order. No relay item is sent while `resync_needed` is set, so the
      cursor never passes a dropped message. With no shared space there is
      nothing to replay and `resync_needed` stays set;
    * again when the relay part of the queue has drained, if the last replay
      filled the queue (`replay_more`);
    * for a newly shared space, when `refresh/1` picks up its row. Every
      path that creates a shared-space row calls `refresh/1` after its write
      has committed (`Peers.share_space/3` on the owner,
      `SharedSpaces.accept_share/2` on the replica), and each Boot re-scan
      refreshes every running connection as a safety net (task 01a0d90f
      stage 6).

  An item counts as delivered only when the peer answers 2xx with a JSON
  object carrying `"ok": true`, which is what every inbox success returns. A
  2xx with any other body is a failure (`:invalid_answer`): counted by the
  breaker, retried, and the cursor stays where it was.

  A message id already queued or in flight is not queued twice.

  ## Telemetry

    * `[:platform, :federation, :peer, :send]`, measurements
      `%{duration: native}`, metadata `%{peer_id, outcome: :ok | :error}`;
    * `[:platform, :federation, :peer, :breaker]`, measurements
      `%{count: 1}`, metadata `%{peer_id, outcome: :open | :half_open |
      :closed}`.
  """

  use GenServer

  require Logger

  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.Envelope
  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.Relay
  alias Platform.Federation.Peers.SharedSpaces

  @registry Platform.Federation.Peers.Registry

  @defaults [
    queue_cap: 1_000,
    base_backoff_ms: 1_000,
    max_backoff_ms: 60_000,
    failure_threshold: 5
  ]

  @type item :: %{id: String.t(), type: String.t(), payload: map()}

  @doc "Defaults, merged under `config :platform, :peer_federation_connection` and start opts."
  def defaults, do: @defaults

  @doc false
  def child_spec({%Peer{} = peer, opts}) do
    %{
      id: {__MODULE__, peer.id},
      start: {__MODULE__, :start_link, [{peer, opts}]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec start_link({Peer.t(), keyword()}) :: GenServer.on_start()
  def start_link({%Peer{} = peer, opts}) do
    GenServer.start_link(__MODULE__, {peer, opts}, name: via(peer.id))
  end

  @doc "The registered name of a peer's connection."
  def via(peer_id), do: {:via, Registry, {@registry, {:peer, peer_id}}}

  @doc """
  The pid of a peer's live connection, or nil. Registry cleanup after an
  exit is asynchronous, so a dead pid that is still registered reads as nil.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(peer_id) do
    case Registry.lookup(@registry, {:peer, peer_id}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc """
  Queues `{type, payload}` for the peer and returns immediately. Returns
  `{:error, :not_running}` when the peer has no connection (inactive,
  revoked, federation off, or its wrapper gave up until the next re-scan).
  """
  @spec enqueue(String.t(), {String.t(), map()}) :: :ok | {:error, :not_running}
  def enqueue(peer_id, {type, payload}) when is_binary(type) and is_map(payload) do
    case whereis(peer_id) do
      nil ->
        {:error, :not_running}

      pid ->
        item = %{id: Platform.Types.UUIDv7.generate(), type: type, payload: payload}
        GenServer.cast(pid, {:enqueue, item})
    end
  end

  @doc """
  Re-reads the peer's shared spaces: subscribes to new ones (replaying their
  messages after the cursor) and unsubscribes from ones no longer active.
  A no-op when the peer has no connection; the next start reads them.
  """
  @spec refresh(String.t()) :: :ok
  def refresh(peer_id) do
    case whereis(peer_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :refresh_shared_spaces)
    end
  end

  @doc """
  Breaker state, queue length and the last error's summary. Never an item.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_running}
  def status(peer_id) do
    case whereis(peer_id) do
      nil ->
        {:error, :not_running}

      pid ->
        try do
          {:ok, GenServer.call(pid, :status)}
        catch
          :exit, _ -> {:error, :not_running}
        end
    end
  end

  @doc """
  Reduces a send error to a summary safe to report: HTTP status, transport
  reason atom or the client's reason atom. A peer-supplied string is never
  kept.
  """
  @spec error_class(term()) :: term()
  def error_class({:http_status, status, _peer_reason}) when is_integer(status),
    do: {:http_status, status}

  def error_class({:transport, %{reason: reason}}) when is_atom(reason), do: {:transport, reason}
  def error_class({:transport, reason}) when is_atom(reason), do: {:transport, reason}
  def error_class(:transport), do: :transport
  def error_class({:forbidden_address, _ip}), do: :forbidden_address
  def error_class(reason) when is_atom(reason), do: reason
  def error_class(_), do: :other

  # ── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init({%Peer{} = peer, opts}) do
    # The sender is linked; trapping exits turns its death into a message and
    # keeps a crashing sender from taking this process with it.
    Process.flag(:trap_exit, true)

    config =
      @defaults
      |> Keyword.merge(Application.get_env(:platform, :peer_federation_connection, []))
      |> Keyword.merge(opts)

    {:ok,
     %{
       shared: %{},
       pending: MapSet.new(),
       replay_more: false,
       peer: peer,
       peer_id: peer.id,
       queue: :queue.new(),
       queue_len: 0,
       queue_cap: config[:queue_cap],
       resync_needed: false,
       breaker: :closed,
       failures: 0,
       failure_threshold: config[:failure_threshold],
       base_backoff_ms: config[:base_backoff_ms],
       max_backoff_ms: config[:max_backoff_ms],
       backoff_ms: config[:base_backoff_ms],
       retry_timer: nil,
       in_flight: nil,
       last_error: nil,
       sent: 0,
       failed: 0
     }, {:continue, :relay_start}}
  end

  # Stage 5: every start replays from the cursor (see the moduledoc).
  @impl true
  def handle_continue(:relay_start, state) do
    {state, ids} = load_shared(state)
    {:noreply, state |> replay(ids) |> maybe_send()}
  end

  @impl true
  def handle_cast({:enqueue, item}, state) do
    state =
      %{state | queue: :queue.in(item, state.queue), queue_len: state.queue_len + 1}
      |> trim()

    {:noreply, maybe_send(state)}
  end

  def handle_cast(:refresh_shared_spaces, state) do
    {state, new_ids} = load_shared(state)
    {:noreply, state |> replay(new_ids) |> maybe_send()}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, summary(state), state}
  end

  # A catch-all, so an unknown call is an error value and not a
  # FunctionClauseError, whose crash report would print the state argument.
  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_info({:send_result, pid, result}, %{in_flight: %{pid: pid}} = state) do
    {:noreply, state |> finish_attempt(result) |> maybe_send()}
  end

  def handle_info({:EXIT, pid, reason}, %{in_flight: %{pid: pid}} = state)
      when reason != :normal do
    {:noreply, state |> finish_attempt({:error, :send_crashed}) |> maybe_send()}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:retry, state) do
    state = %{state | retry_timer: nil}

    state =
      if state.breaker == :open do
        breaker_event(state.peer_id, :half_open)
        %{state | breaker: :half_open}
      else
        state
      end

    {:noreply, maybe_send(state)}
  end

  def handle_info({:new_message, %Platform.Chat.Message{} = msg}, state) do
    with %{} = shared <- Map.get(state.shared, msg.space_id),
         false <- MapSet.member?(state.pending, msg.id),
         %{} = item <- Relay.item_for(shared, msg) do
      {:noreply, state |> push(item) |> trim() |> maybe_send()}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    status
    |> redact(:state, fn
      %{peer_id: _} = state -> summary(state)
      _ -> :redacted
    end)
    |> redact(:message, fn _ -> :redacted end)
    |> redact(:queue, fn _ -> [] end)
    |> redact(:log, fn _ -> [] end)
  end

  defp redact(status, key, fun) do
    if Map.has_key?(status, key), do: Map.update!(status, key, fun), else: status
  end

  # ── private ────────────────────────────────────────────────────────────

  defp summary(state) do
    %{
      peer_id: state.peer_id,
      breaker: state.breaker,
      queue_len: state.queue_len,
      queue_cap: state.queue_cap,
      in_flight: state.in_flight != nil,
      resync_needed: state.resync_needed,
      replay_more: state.replay_more,
      shared_spaces: map_size(state.shared),
      consecutive_failures: state.failures,
      backoff_ms: state.backoff_ms,
      last_error: state.last_error,
      sent: state.sent,
      failed: state.failed
    }
  end

  # Drops the oldest items past the cap. Called after an enqueue and after a
  # failed item is put back at the head, which is itself the oldest.
  defp trim(%{queue_len: len, queue_cap: cap} = state) when len > cap do
    {{:value, dropped}, queue} = :queue.out(state.queue)
    state = forget(state, dropped)

    unless state.resync_needed do
      Logger.warning(
        "[federation] peer queue overflow peer_id=#{state.peer_id} cap=#{cap}; " <>
          "oldest dropped, resync needed"
      )
    end

    trim(%{state | queue: queue, queue_len: len - 1, resync_needed: true})
  end

  defp trim(state), do: state

  defp maybe_send(%{in_flight: nil, retry_timer: nil, breaker: breaker} = state)
       when breaker in [:closed, :half_open] do
    state = prepare_relay(state)

    case :queue.out(state.queue) do
      {{:value, item}, queue} ->
        %{
          state
          | queue: queue,
            queue_len: state.queue_len - 1,
            in_flight: start_sender(state, item)
        }

      {:empty, _} ->
        state
    end
  end

  defp maybe_send(state), do: state

  defp start_sender(state, item) do
    parent = self()
    peer = state.peer
    # Carry this process's callers so test ownership (Req.Test, the Ecto
    # sandbox) resolves through it, as it would for a Task.
    callers = [parent | Process.get(:"$callers", [])]

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", callers)
        send(parent, {:send_result, self(), attempt(peer, item)})
      end)

    %{pid: pid, item: item, started: System.monotonic_time()}
  end

  defp attempt(peer, item) do
    with {:ok, {raw, headers}} <- Envelope.build(item.type, item.payload, peer, id: item.id),
         {:ok, response} <- Client.send_envelope(peer, raw, headers) do
      acknowledgement(Map.get(response, :body))
    end
  rescue
    _ -> {:error, :send_crashed}
  catch
    _, _ -> {:error, :send_crashed}
  end

  # A peer inbox answers every accepted envelope with a JSON object carrying
  # `"ok": true` (`PlatformWeb.FederationInboxController`). A 2xx whose body
  # is anything else (unparseable, HTML from a proxy, a JSON array) is not an
  # acknowledgement: it is a failure, so the breaker counts it and the relay
  # cursor does not move past the item (task 01a0d90f stage 6).
  defp acknowledgement(%{"ok" => true} = body), do: {:ok, body}
  defp acknowledgement(_body), do: {:error, :invalid_answer}

  defp finish_attempt(%{in_flight: in_flight} = state, result) do
    duration = System.monotonic_time() - in_flight.started
    state = %{state | in_flight: nil}

    case result do
      {:ok, body} ->
        send_event(state.peer_id, :ok, duration)
        state = acknowledged(state, in_flight.item, body)

        if state.breaker != :closed, do: breaker_event(state.peer_id, :closed)

        %{
          state
          | breaker: :closed,
            failures: 0,
            backoff_ms: state.base_backoff_ms,
            sent: state.sent + 1
        }

      {:error, reason} ->
        send_event(state.peer_id, :error, duration)
        failures = state.failures + 1

        breaker =
          cond do
            state.breaker == :half_open -> :open
            failures >= state.failure_threshold -> :open
            true -> state.breaker
          end

        if breaker == :open and state.breaker != :open,
          do: breaker_event(state.peer_id, :open)

        delay = jitter(state.backoff_ms)

        %{
          state
          | queue: :queue.in_r(in_flight.item, state.queue),
            queue_len: state.queue_len + 1,
            failures: failures,
            breaker: breaker,
            last_error: error_class(reason),
            failed: state.failed + 1,
            backoff_ms: min(state.backoff_ms * 2, state.max_backoff_ms),
            retry_timer: Process.send_after(self(), :retry, delay)
        }
        |> trim()
    end
  end

  # ── shared-space relay (stage 5) ───────────────────────────────────────

  defp push(state, item) do
    state = %{state | queue: :queue.in(item, state.queue), queue_len: state.queue_len + 1}

    case item do
      %{relay: %{message_id: id}} -> %{state | pending: MapSet.put(state.pending, id)}
      _ -> state
    end
  end

  defp forget(state, %{relay: %{message_id: id}}),
    do: %{state | pending: MapSet.delete(state.pending, id)}

  defp forget(state, _item), do: state

  # The cursor moves only here: the sender reported a 2xx for this item.
  defp acknowledged(state, %{relay: relay} = item, body) do
    safe(fn -> SharedSpaces.advance_cursor(relay.shared_id, relay.message_id) end, :ok)

    case body do
      %{"data" => %{"message_id" => remote_id}} when is_binary(remote_id) ->
        if Platform.UUID.valid?(remote_id) do
          safe(
            fn -> SharedSpaces.record_outbound(state.peer_id, relay.message_id, remote_id) end,
            :ok
          )
        end

      _ ->
        :ok
    end

    shared =
      case Map.fetch(state.shared, relay.space_id) do
        {:ok, entry} ->
          Map.put(state.shared, relay.space_id, %{
            entry
            | cursor: max_id(entry.cursor, relay.message_id)
          })

        :error ->
          state.shared
      end

    forget(%{state | shared: shared}, item)
  end

  defp acknowledged(state, _item, _body), do: state

  defp max_id(nil, id), do: id
  defp max_id(a, b), do: if(a >= b, do: a, else: b)

  # Called only when a send is about to start (nothing in flight, no retry
  # timer, breaker admits a send), so a replay never races an outstanding
  # relay item and never churns while the peer is down.
  defp prepare_relay(%{shared: shared} = state) when map_size(shared) == 0, do: state

  defp prepare_relay(%{resync_needed: true} = state) do
    {queue, dropped} =
      state.queue |> :queue.to_list() |> Enum.split_with(&(not Map.has_key?(&1, :relay)))

    state = %{
      state
      | queue: :queue.from_list(queue),
        queue_len: length(queue),
        pending: MapSet.new(),
        resync_needed: false
    }

    Logger.info(
      "[federation] peer relay resync peer_id=#{state.peer_id} dropped_relay_items=" <>
        "#{length(dropped)}; replaying from the cursor"
    )

    replay(state, Map.keys(state.shared))
  end

  defp prepare_relay(%{replay_more: true} = state) do
    if Enum.any?(:queue.to_list(state.queue), &Map.has_key?(&1, :relay)),
      do: state,
      else: replay(%{state | replay_more: false}, Map.keys(state.shared))
  end

  defp prepare_relay(state), do: state

  # Reads the peer's active shared spaces, subscribes to the new ones and
  # unsubscribes from the ones gone. Returns the new local space ids.
  defp load_shared(state) do
    rows = safe(fn -> SharedSpaces.list_active(state.peer_id) end, nil)

    if rows == nil do
      {state, []}
    else
      fresh = Map.new(rows, &{&1.local_space_id, &1})
      new_ids = Map.keys(fresh) -- Map.keys(state.shared)
      gone_ids = Map.keys(state.shared) -- Map.keys(fresh)

      Enum.each(new_ids, &Platform.Chat.PubSub.subscribe/1)
      Enum.each(gone_ids, &Platform.Chat.PubSub.unsubscribe/1)

      shared =
        state.shared
        |> Map.drop(gone_ids)
        |> Map.merge(
          Map.new(new_ids, fn id ->
            row = fresh[id]

            {id,
             %{
               id: row.id,
               role: row.role,
               remote_space_id: row.remote_space_id,
               cursor: row.outbound_cursor_message_id
             }}
          end)
        )

      {%{state | shared: shared}, new_ids}
    end
  end

  # Queues the relayable messages after each space's cursor, oldest first,
  # up to the free queue space. Filling it sets `replay_more`.
  defp replay(state, space_ids) do
    Enum.reduce(space_ids, state, fn space_id, acc ->
      budget = acc.queue_cap - acc.queue_len

      case Map.get(acc.shared, space_id) do
        %{} = entry when budget > 0 ->
          messages =
            safe(fn -> SharedSpaces.replay_messages(space_id, entry.cursor, budget) end, [])

          acc =
            messages
            |> Enum.reject(&MapSet.member?(acc.pending, &1.id))
            |> Enum.reduce(acc, fn msg, st ->
              case Relay.item_for(entry, msg) do
                nil -> st
                item -> push(st, item)
              end
            end)

          if length(messages) >= budget, do: %{acc | replay_more: true}, else: acc

        %{} ->
          %{acc | replay_more: true}

        nil ->
          acc
      end
    end)
  end

  # A relay DB call must not crash the connection into a restart loop: a
  # failure is logged (no payload) and treated as "nothing to do now".
  defp safe(fun, default) do
    fun.()
  rescue
    error ->
      Logger.warning("[federation] peer relay store call failed: #{inspect(error.__struct__)}")
      default
  catch
    :exit, _ -> default
  end

  # Equal jitter: half the backoff fixed, half random, so retries of many
  # peers failing together spread out.
  defp jitter(backoff_ms) do
    half = div(backoff_ms, 2)
    half + :rand.uniform(max(backoff_ms - half, 1)) - 1
  end

  defp send_event(peer_id, outcome, duration) do
    :telemetry.execute(
      [:platform, :federation, :peer, :send],
      %{duration: duration},
      %{peer_id: peer_id, outcome: outcome}
    )
  end

  defp breaker_event(peer_id, outcome) do
    :telemetry.execute(
      [:platform, :federation, :peer, :breaker],
      %{count: 1},
      %{peer_id: peer_id, outcome: outcome}
    )
  end
end

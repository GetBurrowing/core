defmodule Platform.Chat.CanvasRoom do
  @moduledoc """
  A canvas room: the shared, durable state behind one interactive canvas
  node, multiplayer by default (task 01a1316b-84fa stage 1).

  One room per `(canvas_id, node_id)`, registered in `Platform.Chat.Registry`
  as `{:canvas_room, canvas_id, node_id}` and started on demand under
  `Platform.Chat.CanvasSupervisor` — the same Registry and supervisor as
  `Platform.Chat.Canvas.Server`, which keeps owning the canvas DOCUMENT. The
  room is a separate process type because its key is per node, not per
  canvas; its lifecycle differs (it stops when idle and flushes on
  terminate); and cursor traffic must not queue behind document rebases.
  `restart: :temporary`: a crashed room is started again by the next caller
  and reloads from its last flush.

  ## Ops run one at a time

  Every durable write is a `GenServer.call` (`apply_op/4`), so two viewers
  incrementing the same key at the same instant both land: the room reads
  and writes its own state between messages, and no caller ever does a
  read-modify-write of its own. `Platform.Chat.CanvasRoom.Ops` is the fixed
  op set, as a pure function.

  Each accepted op gets `seq + 1`, is appended to an unflushed buffer, and
  is broadcast as `{:canvas_room_diff, canvas_id, node_id, seq, diff,
  actor_id}` on `Platform.Chat.PubSub.canvas_room_topic/2` (NOT the canvas
  topic, which every LiveView with the space open subscribes).

  ## Durability, and its honest limit

  A debounce timer (`persist_debounce_ms`) is armed by the first unflushed
  op. When it fires, ONE `Repo.transaction` upserts the snapshot
  (`chat_canvas_rooms`: state + seq) and `insert_all`s the buffered ops into
  the append-only log (`chat_canvas_room_events`). The room also flushes
  synchronously before an idle stop and in `terminate/2` (it traps exits, so
  a supervisor shutdown or `stop/2` runs it). A failed flush is logged, the
  buffer is KEPT and the timer re-armed; nothing is dropped.

  **A brutal kill (`Process.exit(pid, :kill)`, a node crash) runs no
  `terminate/2` and loses at most the last debounce window of ops.** That is
  the trade the experiment surface below measures.

  ## Experiment surface

  Read at call time, never as a module attribute:

      config :platform, Platform.Chat.CanvasRoom,
        persist_debounce_ms: 500,
        idle_stop_ms: 60_000

  The measured outcome is DB transactions per 100 ops against the ops lost
  to a brutal kill.

  ## Presence and idle stop

  `join/4` monitors the viewer pid. One pid is one viewer, however many
  times it joins (a browser can render one node twice: chat panel plus
  mobile overlay, `Platform.Chat.Canvas.Renderer`). Presence is grouped by
  actor id with a viewer count, and is broadcast as `{:canvas_room_presence,
  canvas_id, node_id, list}` on join, leave and `:DOWN`. The room owns this
  list itself rather than using `Platform.Chat.Presence`, because idle stop
  needs an exact local viewer count. At zero viewers it schedules a stop
  after `idle_stop_ms`; a join cancels it.

  ## Ephemeral broadcasts

  `ephemeral/5` is a cast that only broadcasts `{:canvas_room_ephemeral,
  canvas_id, node_id, channel, payload, actor_id}`: never persisted, never
  logged, never routed through `Ops`, and it never starts a room.

  ## Actors and rate limits

  `actor` is `%{type: "user" | "agent", id, display_name}`, supplied by the
  CALLER from its own session (stage 2's LiveView) — never from a frame. It
  is recorded on every event row. Per actor, a token bucket: durable ops
  20/s with a burst of 40 (`:rate_limited`), ephemeral 30/s with the excess
  dropped silently. An ephemeral payload is capped at 2 KB of JSON.

  ## Timers

  Every timer lives in `state.timers` by name, set through `schedule/4` and
  cleared through `cancel/2`; the debounce (`:persist`) and the idle stop
  (`:idle_stop`) use them, and `terminate/2` cancels them all. A timer
  message carries a token, so a message already in the mailbox when its
  timer was cancelled or replaced is ignored. A named timer with any other
  message is broadcast as `{:canvas_room_timer, canvas_id, node_id, name,
  msg}`. This is the seam the next member exposes to scripts as
  `after`/`every`.

  ## The handler seam

  Every op goes through the one private `run_event/3`, which today calls
  `Ops.apply/3`. The next member (scripted handlers, 01a1316b-aab0) inserts
  its engine behaviour there, as a pre/post hook around `Ops.apply/3`,
  without changing the bridge, the op wire format, the diff broadcast or the
  log.
  """

  use GenServer, restart: :temporary

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Chat
  alias Platform.Chat.CanvasRoom.{Event, Ops, Record}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.Types.UUIDv7

  @supervisor Platform.Chat.CanvasSupervisor
  @registry Platform.Chat.Registry

  @default_debounce_ms 500
  @default_idle_stop_ms 60_000

  @op_rate_per_s 20
  @op_burst 40
  @ephemeral_rate_per_s 30
  @ephemeral_burst 30
  @max_ephemeral_bytes 2_048
  @max_node_id_bytes 128

  @type actor :: %{type: String.t(), id: String.t(), display_name: String.t() | nil}

  defmodule State do
    @moduledoc false
    @enforce_keys [:canvas_id, :node_id]
    defstruct canvas_id: nil,
              node_id: nil,
              room_id: nil,
              data: nil,
              seq: 0,
              buffer: [],
              viewers: %{},
              timers: %{},
              buckets: %{}
  end

  @doc "The rate-limit and payload caps, for tests and docs."
  def limits do
    %{
      op_rate_per_s: @op_rate_per_s,
      op_burst: @op_burst,
      ephemeral_rate_per_s: @ephemeral_rate_per_s,
      ephemeral_burst: @ephemeral_burst,
      max_ephemeral_bytes: @max_ephemeral_bytes
    }
  end

  # ── Frame wiring (stage 2) ──────────────────────────────────────────────

  @doc """
  The node types a room may be joined for: `prototype`, and the scripted
  embed (`embed` with `scripts: true`, task 01a1316b-677a), whose wrapper in
  `embed.ex` carries `frame_attrs/2`. A plain embed runs under
  `sandbox=""`, so it has no script to talk to a room and is refused.
  """
  @spec room_node?(map() | nil) :: boolean()
  def room_node?(%{"type" => "prototype"}), do: true
  def room_node?(%{"type" => "embed", "props" => %{"scripts" => true}}), do: true
  def room_node?(_node), do: false

  @doc """
  The attributes that mount the `CanvasRoomBridge` hook on a frame wrapper
  (task 01a1316b-84fa stage 2). Every kind that frames a room-backed iframe
  puts these on the element that CONTAINS the iframe, so the kinds cannot
  drift apart. The element must carry its own DOM id (the hook uses it to
  tell two renders of one node apart). With no canvas id (a read-only
  surface that renders a document without one) it returns no attributes and
  the frame runs with `suite.connected === false`.
  """
  @spec frame_attrs(binary() | nil, binary() | nil) :: map()
  def frame_attrs(canvas_id, node_id)
      when is_binary(canvas_id) and canvas_id != "" and is_binary(node_id) and node_id != "" do
    %{
      "phx-hook" => "CanvasRoomBridge",
      "data-canvas-id" => canvas_id,
      "data-node-id" => node_id,
      "data-role" => "canvas-room-bridge"
    }
  end

  def frame_attrs(_canvas_id, _node_id), do: %{}

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Start the room under the canvas supervisor, idempotent."
  @spec start_room(binary(), binary()) :: {:ok, pid()} | {:error, term()}
  def start_room(canvas_id, node_id) do
    with :ok <- validate_key(canvas_id, node_id) do
      case whereis(canvas_id, node_id) do
        pid when is_pid(pid) ->
          {:ok, pid}

        nil ->
          case DynamicSupervisor.start_child(
                 @supervisor,
                 {__MODULE__, canvas_id: canvas_id, node_id: node_id}
               ) do
            {:error, {:already_started, pid}} -> {:ok, pid}
            other -> other
          end
      end
    end
  end

  @doc """
  The room's pid, or nil when it is not running.

  The Registry drops a dead owner's key asynchronously, so for a moment
  after a room exits (idle stop, `stop/2`) the lookup can still name its
  pid. That pid is reported as nil here: the Registry is node-local, so
  `Process.alive?/1` is exact, and `start_room/2` then starts a fresh room
  (the Registry replaces a dead owner's key on register).
  """
  @spec whereis(binary(), binary()) :: pid() | nil
  def whereis(canvas_id, node_id) do
    case Registry.lookup(@registry, {:canvas_room, canvas_id, node_id}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end

  @doc """
  Join `viewer_pid` to the room, starting it if needed. Monitors the viewer
  and cancels any pending idle stop. Returns the snapshot.
  """
  @spec join(binary(), binary(), pid(), map()) ::
          {:ok, %{seq: non_neg_integer(), state: map(), presence: list(), room_pid: pid()}}
          | {:error, term()}
  def join(canvas_id, node_id, viewer_pid, actor) when is_pid(viewer_pid) do
    with {:ok, actor} <- normalize_actor(actor) do
      call_room(canvas_id, node_id, {:join, viewer_pid, actor})
    end
  end

  @doc "Remove `viewer_pid` from the room. No-op when the room is not running."
  @spec leave(binary(), binary(), pid()) :: :ok
  def leave(canvas_id, node_id, viewer_pid) when is_pid(viewer_pid) do
    case whereis(canvas_id, node_id) do
      nil -> :ok
      pid -> safe_call(pid, {:leave, viewer_pid}, :ok)
    end
  end

  @doc """
  Apply one durable op as `actor`, serialised in the room. Returns
  `{:ok, %{seq, result}}` or `{:error, code}` (an `Ops` code, or
  `:rate_limited`).
  """
  @spec apply_op(binary(), binary(), map(), map()) ::
          {:ok, %{seq: pos_integer(), result: term()}} | {:error, term()}
  def apply_op(canvas_id, node_id, actor, op) when is_map(op) do
    with {:ok, actor} <- normalize_actor(actor) do
      call_room(canvas_id, node_id, {:op, actor, op})
    end
  end

  def apply_op(_canvas_id, _node_id, _actor, _op), do: {:error, :invalid_op}

  @doc """
  Broadcast an ephemeral message (a cursor, a drag) to the room. Never
  persisted or logged; dropped silently when the room is not running, the
  payload is over 2 KB, or the actor is over its rate.
  """
  @spec ephemeral(binary(), binary(), map(), binary(), term()) :: :ok
  def ephemeral(canvas_id, node_id, actor, channel, payload) do
    with pid when is_pid(pid) <- whereis(canvas_id, node_id),
         {:ok, actor} <- normalize_actor(actor),
         true <- is_binary(channel) and channel != "" and byte_size(channel) <= 128,
         {:ok, json} <- Jason.encode(payload),
         true <- byte_size(json) <= @max_ephemeral_bytes do
      GenServer.cast(pid, {:ephemeral, actor, channel, payload})
    end

    :ok
  end

  @doc "The room's current seq, state and presence, starting it if needed."
  @spec snapshot(binary(), binary()) ::
          {:ok, %{seq: non_neg_integer(), state: map(), presence: list()}} | {:error, term()}
  def snapshot(canvas_id, node_id), do: call_room(canvas_id, node_id, :snapshot)

  @doc "Stop the room gracefully (flushes first). No-op when not running."
  @spec stop(binary(), binary()) :: :ok
  def stop(canvas_id, node_id) do
    case whereis(canvas_id, node_id) do
      nil ->
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(@supervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
        end
    end
  end

  @doc false
  # Test and next-member seam: set a named timer from outside the room.
  # Returns the timer reference so a caller can observe cancellation.
  def schedule_timer(canvas_id, node_id, name, ms, msg) do
    call_room(canvas_id, node_id, {:schedule, name, ms, msg})
  end

  @doc false
  def cancel_timer(canvas_id, node_id, name) do
    call_room(canvas_id, node_id, {:cancel, name})
  end

  # ── Timer seam (in-process) ─────────────────────────────────────────────

  @doc false
  # Set (or replace) the named timer. Pure over `state` apart from the
  # `Process.send_after/3`; call only from inside the room.
  @spec schedule(%State{}, term(), non_neg_integer(), term()) :: %State{}
  def schedule(%State{} = state, name, ms, msg) do
    state = cancel(state, name)
    token = make_ref()
    ref = Process.send_after(self(), {:room_timer, name, token, msg}, ms)
    %{state | timers: Map.put(state.timers, name, {ref, token})}
  end

  @doc false
  @spec cancel(%State{}, term()) :: %State{}
  def cancel(%State{} = state, name) do
    case Map.pop(state.timers, name) do
      {nil, _} ->
        state

      {{ref, _token}, timers} ->
        Process.cancel_timer(ref)
        %{state | timers: timers}
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  def start_link(opts) do
    canvas_id = Keyword.fetch!(opts, :canvas_id)
    node_id = Keyword.fetch!(opts, :node_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {@registry, {:canvas_room, canvas_id, node_id}}}
    )
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    canvas_id = Keyword.fetch!(opts, :canvas_id)
    node_id = Keyword.fetch!(opts, :node_id)

    case load(canvas_id, node_id) do
      {:ok, room_id, data, seq} ->
        state = %State{
          canvas_id: canvas_id,
          node_id: node_id,
          room_id: room_id,
          data: data,
          seq: seq
        }

        # No viewer yet: a room started by apply_op/4 or snapshot/2 alone must
        # not live forever.
        {:ok, maybe_schedule_idle(state)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:op, actor, op}, _from, state) do
    case take_token(state, {:op, actor.id}, @op_rate_per_s, @op_burst) do
      {:error, state} ->
        {:reply, {:error, :rate_limited}, state}

      {:ok, state} ->
        case run_event(state, op, actor) do
          {:ok, data, diff} ->
            {state, seq} = accept(state, op, actor, data, diff)
            {:reply, {:ok, %{seq: seq, result: diff["result"]}}, state}

          {:error, code} ->
            {:reply, {:error, code}, state}
        end
    end
  end

  def handle_call({:join, viewer_pid, actor}, _from, state) do
    viewers =
      case Map.fetch(state.viewers, viewer_pid) do
        {:ok, viewer} ->
          Map.put(state.viewers, viewer_pid, %{viewer | actor: actor})

        :error ->
          ref = Process.monitor(viewer_pid)
          Map.put(state.viewers, viewer_pid, %{ref: ref, actor: actor})
      end

    state = cancel(%{state | viewers: viewers}, :idle_stop)
    presence = broadcast_presence(state)

    {:reply, {:ok, %{seq: state.seq, state: state.data, presence: presence, room_pid: self()}},
     state}
  end

  def handle_call({:leave, viewer_pid}, _from, state) do
    {:reply, :ok, remove_viewer(state, viewer_pid)}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, %{seq: state.seq, state: state.data, presence: presence(state)}}, state}
  end

  def handle_call({:schedule, name, ms, msg}, _from, state) do
    state = schedule(state, name, ms, msg)
    {ref, _token} = Map.fetch!(state.timers, name)
    {:reply, {:ok, ref}, state}
  end

  def handle_call({:cancel, name}, _from, state) do
    {:reply, :ok, cancel(state, name)}
  end

  @impl true
  def handle_cast({:ephemeral, actor, channel, payload}, state) do
    case take_token(state, {:ephemeral, actor.id}, @ephemeral_rate_per_s, @ephemeral_burst) do
      {:ok, state} ->
        ChatPubSub.broadcast_canvas_room(
          state.canvas_id,
          state.node_id,
          {:canvas_room_ephemeral, state.canvas_id, state.node_id, channel, payload, actor.id}
        )

        {:noreply, state}

      {:error, state} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:room_timer, name, token, msg}, state) do
    case Map.get(state.timers, name) do
      {_ref, ^token} -> fire_timer(name, msg, %{state | timers: Map.delete(state.timers, name)})
      _stale -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.viewers, pid) do
      %{ref: ^ref} -> {:noreply, remove_viewer(state, pid)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = Enum.reduce(Map.keys(state.timers), state, &cancel(&2, &1))
    _ = flush(state)
    :ok
  end

  # ── Internals ───────────────────────────────────────────────────────────

  # THE handler seam (moduledoc): every op passes through here.
  defp run_event(state, op, actor), do: Ops.apply(state.data, op, actor)

  defp accept(state, op, actor, data, diff) do
    seq = state.seq + 1

    logged_op =
      case diff do
        %{"kind" => "collection", "op" => "add", "id" => id} -> Map.put(op, "id", id)
        _ -> op
      end

    entry = %{seq: seq, op: logged_op, actor: actor, at: DateTime.utc_now()}

    ChatPubSub.broadcast_canvas_room(
      state.canvas_id,
      state.node_id,
      {:canvas_room_diff, state.canvas_id, state.node_id, seq, Map.delete(diff, "result"),
       actor.id}
    )

    state = %{state | data: data, seq: seq, buffer: [entry | state.buffer]}
    {arm_persist(state), seq}
  end

  defp arm_persist(state) do
    if Map.has_key?(state.timers, :persist),
      do: state,
      else: schedule(state, :persist, debounce_ms(), :flush)
  end

  defp fire_timer(:persist, :flush, state) do
    case flush(state) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:noreply, arm_persist(state)}
    end
  end

  defp fire_timer(:idle_stop, :idle_stop, state) do
    if map_size(state.viewers) == 0 do
      case flush(state) do
        {:ok, state} -> {:stop, :normal, state}
        {:error, state} -> {:noreply, schedule(state, :idle_stop, idle_stop_ms(), :idle_stop)}
      end
    else
      {:noreply, state}
    end
  end

  defp fire_timer(name, msg, state) do
    ChatPubSub.broadcast_canvas_room(
      state.canvas_id,
      state.node_id,
      {:canvas_room_timer, state.canvas_id, state.node_id, name, msg}
    )

    {:noreply, state}
  end

  # One transaction: the snapshot upsert, then the buffered events. On any
  # failure the buffer is kept; the caller re-arms.
  defp flush(%State{buffer: []} = state), do: {:ok, state}

  defp flush(%State{} = state) do
    entries = Enum.reverse(state.buffer)

    result =
      try do
        Repo.transaction(fn ->
          room_id = upsert_snapshot(state)
          Repo.insert_all(Event, Enum.map(entries, &event_row(&1, room_id)))
          room_id
        end)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    case result do
      {:ok, room_id} ->
        cancelled = cancel(state, :persist)
        {:ok, %{cancelled | room_id: room_id, buffer: []}}

      {:error, reason} ->
        Logger.error(
          "CanvasRoom flush failed for #{state.canvas_id}/#{state.node_id}, " <>
            "keeping #{length(entries)} buffered op(s): #{inspect(reason)}"
        )

        {:error, cancel(state, :persist)}
    end
  end

  defp upsert_snapshot(state) do
    record = %Record{
      id: state.room_id || UUIDv7.generate(),
      canvas_id: state.canvas_id,
      node_id: state.node_id,
      state: state.data,
      seq: state.seq
    }

    %Record{id: id} =
      Repo.insert!(record,
        on_conflict: {:replace, [:state, :seq, :updated_at]},
        conflict_target: [:canvas_id, :node_id],
        returning: [:id]
      )

    id
  end

  defp event_row(entry, room_id) do
    %{
      id: UUIDv7.generate(),
      room_id: room_id,
      seq: entry.seq,
      op: entry.op,
      actor_type: entry.actor.type,
      actor_id: if(Platform.UUID.valid?(entry.actor.id), do: entry.actor.id, else: nil),
      inserted_at: entry.at
    }
  end

  defp load(canvas_id, node_id) do
    case Repo.one(from(r in Record, where: r.canvas_id == ^canvas_id and r.node_id == ^node_id)) do
      %Record{} = record ->
        {:ok, record.id, Map.merge(Ops.empty(), record.state || %{}), record.seq}

      nil ->
        if Chat.get_canvas(canvas_id),
          do: {:ok, nil, Ops.empty(), 0},
          else: {:error, :canvas_not_found}
    end
  end

  defp remove_viewer(state, pid) do
    case Map.pop(state.viewers, pid) do
      {nil, _} ->
        state

      {%{ref: ref}, viewers} ->
        Process.demonitor(ref, [:flush])
        state = %{state | viewers: viewers}
        broadcast_presence(state)
        maybe_schedule_idle(state)
    end
  end

  defp maybe_schedule_idle(state) do
    if map_size(state.viewers) == 0,
      do: schedule(state, :idle_stop, idle_stop_ms(), :idle_stop),
      else: state
  end

  defp presence(state) do
    state.viewers
    |> Map.values()
    |> Enum.group_by(& &1.actor.id)
    |> Enum.map(fn {id, [%{actor: actor} | _] = viewers} ->
      %{id: id, type: actor.type, display_name: actor.display_name, viewers: length(viewers)}
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp broadcast_presence(state) do
    list = presence(state)

    ChatPubSub.broadcast_canvas_room(
      state.canvas_id,
      state.node_id,
      {:canvas_room_presence, state.canvas_id, state.node_id, list}
    )

    list
  end

  defp take_token(state, key, rate, burst) do
    now = System.monotonic_time(:millisecond)
    {tokens, last} = Map.get(state.buckets, key, {burst * 1.0, now})
    tokens = min(burst * 1.0, tokens + (now - last) * rate / 1000)

    if tokens >= 1.0 do
      {:ok, %{state | buckets: Map.put(state.buckets, key, {tokens - 1.0, now})}}
    else
      {:error, %{state | buckets: Map.put(state.buckets, key, {tokens, now})}}
    end
  end

  # A room that is stopping (idle stop, `stop/2`) between `whereis` and the
  # call exits the caller; one retry starts a fresh room.
  defp call_room(canvas_id, node_id, msg, attempt \\ 1) do
    with {:ok, pid} <- start_room(canvas_id, node_id) do
      try do
        GenServer.call(pid, msg)
      catch
        :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] and attempt < 2 ->
          call_room(canvas_id, node_id, msg, attempt + 1)
      end
    end
  end

  defp safe_call(pid, msg, default) do
    GenServer.call(pid, msg)
  catch
    :exit, _ -> default
  end

  defp validate_key(canvas_id, node_id) do
    cond do
      not Platform.UUID.valid?(canvas_id) -> {:error, :invalid_canvas_id}
      not is_binary(node_id) -> {:error, :invalid_node_id}
      node_id == "" or byte_size(node_id) > @max_node_id_bytes -> {:error, :invalid_node_id}
      true -> :ok
    end
  end

  defp normalize_actor(actor) when is_map(actor) do
    type = Map.get(actor, :type) || Map.get(actor, "type")
    id = Map.get(actor, :id) || Map.get(actor, "id")
    name = Map.get(actor, :display_name) || Map.get(actor, "display_name")

    if type in ["user", "agent"] and is_binary(id) and id != "" do
      {:ok, %{type: type, id: id, display_name: name}}
    else
      {:error, :invalid_actor}
    end
  end

  defp normalize_actor(_actor), do: {:error, :invalid_actor}

  defp config, do: Application.get_env(:platform, __MODULE__, [])
  defp debounce_ms, do: Keyword.get(config(), :persist_debounce_ms, @default_debounce_ms)
  defp idle_stop_ms, do: Keyword.get(config(), :idle_stop_ms, @default_idle_stop_ms)
end

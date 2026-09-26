defmodule Platform.GameStream.Session do
  @moduledoc """
  One live play session (task 01a0db5f stage 2). A `:temporary` GenServer
  under `Platform.GameStream.SessionSupervisor`, named in
  `Platform.GameStream.Registry` by `{:session, id}`.

  ## One session per host, claimed atomically

  `init/1` registers `{:host, host_runtime_id}` in the unique Registry. A
  second session for the same host fails that registration and the start
  returns `{:error, :host_busy}` — the check and the claim are one
  operation, so two concurrent starts cannot both win. The claim is released
  the moment the session reaches a terminal state, not when the process
  exits, so a new session can start while an ended one lingers for
  `status/1` readers.

  ## State transitions

  `building → connecting → live → ended | failed`, driven by the host's
  `play_session_status` frames. `ended` and `failed` are terminal: a frame
  after them is ignored. Core itself moves a session to a terminal state in
  exactly three places: `GameStream.stop_session/2` (`ended`), a host disconnect (`failed`,
  "The play host disconnected"), and a host that reports `ended`/`failed`.

  ## Viewers

  At most one viewer at a time. The previous viewer receives
  `{:game_stream, session_id, :moved}` directly (not on the shared topic,
  which the new viewer also reads). A viewer that goes away — its LiveView
  process exits — does NOT end the session; it stays `live` until the host
  idles out, so a reload re-attaches to the same stream.

  ### Which window wins (task 01a0db5f stage 6)

  An attach carries a mode:

    * `:take` — a window the user acted in: the canvas opened in it, "Play
      here", or the window that clicked "Start again". It becomes the viewer
      and the previous one is told `:moved`. Latest `:take` wins.
    * `:follow` — a window whose node was re-rendered onto this session
      because SOMEONE ELSE restarted it (it saw the canvas patch). It becomes
      the viewer only if nobody holds the session; otherwise it is answered
      `viewer: false` and shows "Continued in another window".

  An attach to a session that has already ended or failed claims nothing
  and moves nobody: there is no stream to continue anywhere.

  "Start again" also passes `viewer: pid` to `start_session/2`, so the
  clicking window holds the session from the moment it exists — before the
  canvas patch reaches any other window. Together these make the clicking
  window win whatever order the attaches arrive in.

  ### Only the current viewer talks to the host

  Every successful attach is issued a fresh `viewer_token`. A viewer signal
  (`answer`, `ice`) reaches the host only when it carries the CURRENT
  viewer's pid and token; anything else is refused `{:error, :moved}` and
  never broadcast, so a superseded window (or a stale twin in the same page)
  cannot answer an offer meant for another peer. The host's own signals
  (`offer`, `ice`) are sent to the current viewer's pid directly, never on
  the shared topic, so a window that is not the viewer is never handed an
  offer to answer.

  ## The latest unanswered offer is kept (task 01a0db5f stage 4)

  The host sends a complete offer once per viewer peer and re-offers only
  when that peer ends. A window that attaches AFTER the offer went out (the
  canvas opened while the build finished, or a reload) would otherwise wait
  for a peer timeout that never comes, because nobody answered. So the
  session keeps the host's most recent `offer` until a viewer answers it, and
  `attach_viewer` hands it to the attaching window as `pending_offer`. An
  answered offer is cleared: it belongs to a peer another window owns, and
  answering it twice would fail on the host.

  ## The idle end reads the way the design words it (stage 6)

  The host reports an idle end as the bare detail `"idle"`. The session
  turns it into "Session ended after N minutes idle" (singular for one) from
  its own `idle_timeout_s`, so the canvas and the row's `ended_reason` carry
  the design's wording. See `idle_reason/1`.

  ## PubSub

  Everything a viewer renders is published on `game_stream:<session_id>`
  (`Platform.GameStream.topic/1`) as `{:game_stream, id, {:status, map}}`
  and `{:game_stream, id, {:signal, kind, data}}`.

  ## The row is written once, at the end

  On the transition to a terminal state the session writes its
  `game_stream_sessions` row with the last stats the viewer reported. A
  failed write is logged and swallowed: losing one measurement must not
  crash the process a viewer is watching.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Platform.GameStream
  alias Platform.GameStream.Protocol
  alias Platform.GameStream.SessionRecord
  alias Platform.GameStream.Supervisor, as: GSSupervisor
  alias Platform.Repo

  @default_linger_ms 60_000

  # ── Client ──────────────────────────────────────────────────────────────

  @doc false
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via(args.session_id))
  end

  @doc false
  def via(session_id), do: {:via, Registry, {GSSupervisor.registry(), {:session, session_id}}}

  @doc "The session id currently holding `host_runtime_id`, or nil."
  @spec session_for_host(String.t()) :: String.t() | nil
  def session_for_host(host_runtime_id) do
    case Registry.lookup(GSSupervisor.registry(), {:host, host_runtime_id}) do
      [{_pid, session_id}] -> session_id
      [] -> nil
    end
  end

  @doc false
  def call(session_id, message) when is_binary(session_id) do
    GenServer.call(via(session_id), message)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> {:error, :not_found}
    :exit, {:shutdown, _} -> {:error, :not_found}
  end

  def call(_session_id, _message), do: {:error, :not_found}

  # ── Server ──────────────────────────────────────────────────────────────

  # A crash report (and `:sys.get_status/1`) prints the whole state; the
  # state holds the TURN credential in `ice_servers`, and a pending offer's
  # SDP. Neither belongs in a log, so both are redacted here (stage 5).
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, &redact_state/1)
  end

  defp redact_state(%{} = state) do
    state
    |> Map.update(:ice_servers, [], &redact_ice_servers/1)
    |> Map.update(:pending_offer, nil, &if(&1, do: :redacted))
  end

  defp redact_state(other), do: other

  defp redact_ice_servers(servers) when is_list(servers) do
    Enum.map(servers, fn
      %{} = server -> Map.replace(server, :credential, :redacted)
      _ -> :redacted
    end)
  end

  defp redact_ice_servers(_), do: []

  @impl true
  def init(args) do
    case Registry.register(
           GSSupervisor.registry(),
           {:host, args.host_runtime_id},
           args.session_id
         ) do
      {:ok, _owner} ->
        now = DateTime.utc_now()

        state =
          args
          |> Map.take(
            ~w(session_id task_id review_sha branch repo_url host_runtime_id started_by encoder
               experiment_id variant_slug idle_timeout_s ice_servers force_relay)a
          )
          |> Map.merge(%{
            state: "building",
            detail: "Waiting for the play host",
            elapsed_ms: 0,
            started_at: now,
            viewer: nil,
            viewer_epoch: 0,
            pending_offer: nil,
            stats: %{},
            ended_reason: nil,
            linger_ms: Map.get(args, :linger_ms, @default_linger_ms)
          })

        state =
          case Map.get(args, :viewer) do
            pid when is_pid(pid) -> claim_viewer(state, pid)
            _ -> state
          end

        {:ok, state, {:continue, :dispatch}}

      {:error, {:already_registered, _pid}} ->
        {:stop, :host_busy}
    end
  end

  @impl true
  def handle_continue(:dispatch, state) do
    broadcast_host(state, "play_session_start", Protocol.session_start_payload(state))
    publish_status(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, {:ok, public_status(state)}, state}

  def handle_call({:host_status, runtime_id, parsed}, _from, state) do
    cond do
      runtime_id != state.host_runtime_id ->
        {:reply, {:error, :not_host}, state}

      terminal?(state) ->
        {:reply, {:error, :terminal}, state}

      true ->
        state = %{
          state
          | state: parsed.state,
            detail: display_detail(parsed.state, parsed.detail, state),
            elapsed_ms: parsed.elapsed_ms
        }

        state =
          if parsed.state in Protocol.terminal_states(),
            do: finish(state, state.detail || parsed.state),
            else: tap(state, &publish_status/1)

        {:reply, :ok, state}
    end
  end

  def handle_call({:host_signal, runtime_id, parsed}, _from, state) do
    cond do
      runtime_id != state.host_runtime_id ->
        {:reply, {:error, :not_host}, state}

      terminal?(state) ->
        {:reply, {:error, :terminal}, state}

      true ->
        # To the current viewer only (see "Only the current viewer talks to
        # the host"): a window that is not the viewer must never be handed an
        # offer it could answer.
        case state.viewer do
          %{pid: pid} ->
            send(pid, {:game_stream, state.session_id, {:signal, parsed.kind, parsed.data}})

          nil ->
            :ok
        end

        state =
          if parsed.kind == "offer", do: %{state | pending_offer: parsed.data}, else: state

        {:reply, :ok, state}
    end
  end

  def handle_call({:viewer_signal, {pid, token}, parsed}, _from, state) do
    cond do
      terminal?(state) ->
        {:reply, {:error, :terminal}, state}

      not current_viewer?(state, pid, token) ->
        Logger.debug(
          "[GameStream] dropped #{parsed.kind} from a window that is not the viewer of #{state.session_id}"
        )

        {:reply, {:error, :moved}, state}

      true ->
        broadcast_host(state, "play_signal", %{
          session_id: state.session_id,
          kind: parsed.kind,
          data: parsed.data
        })

        state = if parsed.kind == "answer", do: %{state | pending_offer: nil}, else: state
        {:reply, :ok, state}
    end
  end

  def handle_call({:attach_viewer, pid, mode}, _from, state)
      when is_pid(pid) and mode in [:take, :follow] do
    held_by_other? =
      case state.viewer do
        %{pid: ^pid} -> false
        %{pid: other} -> Process.alive?(other)
        nil -> false
      end

    # An ended or failed session has nothing to view: attaching to it moves
    # nobody (a window that opens it must not tell another window "Continued
    # in another window" about a stream that no longer exists).
    if terminal?(state) or (mode == :follow and held_by_other?) do
      reply =
        public_status(state)
        |> Map.merge(%{pending_offer: nil, viewer: false, viewer_token: nil})

      {:reply, {:ok, reply}, state}
    else
      state = claim_viewer(state, pid)

      reply =
        public_status(state)
        |> Map.merge(%{
          pending_offer: state.pending_offer,
          viewer: true,
          viewer_token: state.viewer.token
        })

      {:reply, {:ok, reply}, state}
    end
  end

  def handle_call({:report_stats, stats}, _from, state) do
    {:reply, :ok, %{state | stats: Map.merge(state.stats, stats)}}
  end

  def handle_call({:stop, reason}, _from, state) do
    if terminal?(state) do
      {:reply, {:ok, public_status(state)}, state}
    else
      broadcast_host(
        state,
        "play_session_stop",
        Protocol.session_stop_payload(state.session_id, reason)
      )

      state = finish(%{state | state: "ended", detail: reason}, reason)
      {:reply, {:ok, public_status(state)}, state}
    end
  end

  def handle_call(:host_disconnected, _from, state) do
    if terminal?(state) do
      {:reply, :ok, state}
    else
      detail = "The play host disconnected"
      {:reply, :ok, finish(%{state | state: "failed", detail: detail}, detail)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{viewer: %{ref: ref}} = state) do
    {:noreply, %{state | viewer: nil}}
  end

  def handle_info(:linger_over, state), do: {:stop, :normal, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ───────────────────────────────────────────────────────────

  defp terminal?(state), do: state.state in Protocol.terminal_states()

  # Makes `pid` the viewer with a fresh token. A different previous viewer is
  # told `:moved`; the same pid re-attaching (a reload's twin, the restarting
  # window's re-rendered node) keeps the monitor and only gets a new token,
  # which retires the token its older copy held.
  defp claim_viewer(state, pid) do
    epoch = state.viewer_epoch + 1

    case state.viewer do
      %{pid: ^pid} = viewer ->
        %{state | viewer: %{viewer | token: epoch}, viewer_epoch: epoch}

      %{pid: old_pid, ref: old_ref} ->
        Process.demonitor(old_ref, [:flush])
        send(old_pid, {:game_stream, state.session_id, :moved})
        %{state | viewer: new_viewer(pid, epoch), viewer_epoch: epoch}

      nil ->
        %{state | viewer: new_viewer(pid, epoch), viewer_epoch: epoch}
    end
  end

  defp new_viewer(pid, token), do: %{pid: pid, ref: Process.monitor(pid), token: token}

  defp current_viewer?(%{viewer: %{pid: pid, token: token}}, pid, token), do: true
  defp current_viewer?(_state, _pid, _token), do: false

  defp display_detail("ended", "idle", state), do: idle_reason(state.idle_timeout_s)
  defp display_detail(_state_name, detail, _state), do: detail

  @doc """
  The design's wording for an idle end: "Session ended after 10 minutes
  idle", singular for one minute. A timeout that is not a whole number of
  minutes is given in seconds.
  """
  @spec idle_reason(term()) :: String.t()
  def idle_reason(seconds) when is_integer(seconds) and seconds > 0 do
    cond do
      seconds == 60 -> "Session ended after 1 minute idle"
      rem(seconds, 60) == 0 -> "Session ended after #{div(seconds, 60)} minutes idle"
      seconds == 1 -> "Session ended after 1 second idle"
      true -> "Session ended after #{seconds} seconds idle"
    end
  end

  def idle_reason(_seconds), do: "Session ended after a period idle"

  defp finish(state, reason) do
    Registry.unregister(GSSupervisor.registry(), {:host, state.host_runtime_id})
    state = %{state | ended_reason: reason, pending_offer: nil}
    record(state)
    publish_status(state)
    Process.send_after(self(), :linger_over, state.linger_ms)
    state
  end

  defp record(state) do
    {kind, id} =
      case state.started_by do
        {kind, id} when kind in [:agent, :user] -> {Atom.to_string(kind), id}
        _ -> {nil, nil}
      end

    attrs = %{
      id: state.session_id,
      task_id: state.task_id,
      review_sha: state.review_sha,
      branch: state.branch,
      host_runtime_id: state.host_runtime_id,
      started_by_kind: kind,
      started_by_id: id,
      experiment_id: state.experiment_id,
      variant_slug: state.variant_slug,
      encoder: state.encoder,
      connection_path: Map.get(state.stats, :connection_path),
      rtt_p50_ms: Map.get(state.stats, :rtt_p50_ms),
      rtt_p95_ms: Map.get(state.stats, :rtt_p95_ms),
      fps_avg: Map.get(state.stats, :fps_avg),
      ended_state: state.state,
      ended_reason: state.ended_reason,
      started_at: state.started_at,
      ended_at: DateTime.utc_now()
    }

    case %SessionRecord{} |> SessionRecord.changeset(attrs) |> Repo.insert() do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[GameStream] could not record session #{state.session_id}: #{inspect(changeset.errors)}"
        )
    end
  rescue
    error ->
      Logger.warning(
        "[GameStream] could not record session #{state.session_id}: #{Exception.message(error)}"
      )
  end

  defp public_status(state) do
    %{
      session_id: state.session_id,
      task_id: state.task_id,
      state: state.state,
      detail: state.detail,
      elapsed_ms: state.elapsed_ms,
      review_sha: state.review_sha,
      branch: state.branch,
      host_runtime_id: state.host_runtime_id,
      started_at: state.started_at,
      ended_reason: state.ended_reason,
      ice_servers: state.ice_servers,
      force_relay: Map.get(state, :force_relay) == true
    }
  end

  defp publish_status(state), do: publish(state, {:status, public_status(state)})

  defp publish(state, message) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      GameStream.topic(state.session_id),
      {:game_stream, state.session_id, message}
    )
  end

  defp broadcast_host(state, event, payload) do
    topic = Protocol.host_topic(state.host_runtime_id)

    case PlatformWeb.Endpoint.broadcast(topic, event, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[GameStream] broadcast #{event} to #{topic} failed: #{inspect(reason)}")
    end
  end
end

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
  exactly three places: `GameStream.stop_session/2` (`ended`), a host that
  dropped and did not come back within the grace window (`failed`, "The play
  host disconnected"), and a host that reports `ended`/`failed`.

  ## A host that drops (task 01a0dbd6 stage 6)

  The viewers' media is browser to host and never passes through core, so a
  dropped runtime channel does not stop anyone's video. The session does not
  fail when the channel drops: it waits `host_grace_ms` (the start option,
  else `config :platform, :game_stream_host_grace_ms`, else 20 s) for the
  host's `play_session_status` with `resume: true` (see
  `Platform.GameStream.Protocol`, "Resume"). The resume ends the wait, and
  core re-sends what the host may have missed: `play_peer_open` for each
  peer it holds that the host does not, `play_peer_close` for each the host
  holds that core does not, and a fresh `play_slots`. If the wait runs out,
  the session fails with "The play host disconnected", as before.

  The session remembers the channel pid that last spoke for the host. A drop
  reported by any OTHER channel is ignored: the host already came back on a
  new channel before the old one's `terminate/2` ran.

  ## Peers, player slots and spectators (task 01a0dbd6)

  One session per host, N attached peers. A PEER is one LiveView's WebRTC
  peer connection to the host, named by a core-minted `peer_id`; see
  `Platform.GameStream.Protocol`, "Widening". The state holds:

    * `peers` — `%{peer_id => %{pid, ref, token, user_id, name, slots}}`,
      where `slots` is `%{src => slot}` (the browser's local controller
      ordinal to a player slot). A peer with no slots is a spectator.
    * `slots` — `%{slot => peer_id}`, the inverse, one peer per slot.
    * `pending_offers` — `%{peer_id => offer}`: each peer's latest
      unanswered offer.
    * `max_players`, `max_spectators`, `open_as` — the resolved
      `game_stream.roster` surface payload.
    * `touch` — whether the host declares `game_stream_touch`, and
      `touch_tuning` — the resolved `game_stream.touch` surface payload
      (task 01a0fe45). Both reach the browser as the `touch` map of the
      public status and of the roster: `%{enabled, slop_px, move_hz,
      variant}`. See `Platform.GameStream.Protocol`, "Touch".

  Each LiveView pid holds AT MOST ONE peer per session. The copies of one
  node in a page (chat inline, desktop panel, mobile overlay) all run in the
  same LiveView process, so they share its peer: a copy that takes the
  stream back re-attaches the SAME peer and never mints a second one, and so
  never counts twice against the spectator cap.

  ### Attach watches; it never moves anyone

  `attach(:watch | :follow)` adds a spectator peer. Opening a canvas never
  moves or disconnects another peer. The only data variant is the roster
  surface's `open_as: "join"`, under which a `:watch` attach also joins the
  next free slot if there is one (`:follow`, a window re-rendered onto a
  session someone else restarted, never joins). A new spectator beyond
  `max_spectators` is refused `{:error, :spectators_full}`.

  A re-attach from the pid that already owns a peer issues a fresh token and
  sends `play_peer_open` for that peer_id, so the host re-offers AT ONCE.
  Before this, the re-attaching copy waited for an offer the host sent only
  after the old peer timed out: task 01a0dbd6 stage 1 measured about 10.7 s
  over TURN (its hypothesis H3).

  ### Join, leave, take over

    * `join(pid, src)` gives the pid's peer the next free slot for `src`
      (idempotent for a src that already holds one) or `{:error, :slots_full}`.
    * `leave(pid, src | :all)` frees that src's slot, or all of them.
    * `take_over(pid, slot, src)` gives `slot` to the pid's peer. The
      displaced peer is sent `{:game_stream, id, {:displaced, slot, by_name}}`
      directly and KEEPS its peer and video: it becomes a spectator of that
      slot, nothing more.

  Every change sends a full `play_slots` snapshot to the host and publishes
  `{:roster, roster}` on the topic.

  ### Only a peer's owner talks to the host for it

  A viewer signal names a peer (or, from a client that sends none, the pid's
  own peer). It reaches the host only when it carries that peer's pid AND
  its current token; a wrong pid, a stale token or another peer's id is
  refused `{:error, :moved}` and nothing is broadcast. Host signals for a
  peer are sent to that peer's pid only, never on the shared topic.

  ### A peer that goes away

  A peer's LiveView exiting (a `:DOWN`) removes the peer, frees its slots and
  sends `play_peer_close`. It does NOT end the session; the host idles it
  out. A peer whose pid is already dead is also pruned at the next attach,
  so a reload's new window is not refused by the old window's leftover.

  ### Hosts without `game_stream_multi` (v1 fallback)

  Against a v1 host core sends none of the peer frames and `play_signal`
  carries no `peer_id`. Peers are still tracked, but only ONE of them holds
  the host's single WebRTC peer, the `media_peer`, and that peer is P1: v1
  has one slot. An attach claims the media only when nobody holds it, so
  watch-by-default holds here too: a second window is answered
  `viewer: false` and shows "Play here", which is `take_over(slot 0)`. The
  previous holder is then sent `:displaced` AND `:moved` (with one peer on
  the host it cannot keep video). `leave` is refused `:single_peer_host`:
  the v1 host cannot drop a connected viewer's input. The spectator cap is
  not applied, since a v1 non-holder receives no media. A same-pid
  re-attach cannot ask a v1 host for a fresh offer, so H3 remains on v1
  hosts until they upgrade.

  ### `start_session(viewer: pid)`

  The window that clicked "Start again" is attached as a peer and joined as
  P1 from the moment the session exists, before the canvas patch reaches
  any other window.

  ## The idle end reads the way the design words it (stage 6)

  The host reports an idle end as the bare detail `"idle"`. The session
  turns it into "Session ended after N minutes idle" (singular for one) from
  its own `idle_timeout_s`, so the canvas and the row's `ended_reason` carry
  the design's wording. See `idle_reason/1`.

  ## PubSub

  Everything every viewer renders is published on `game_stream:<session_id>`
  (`Platform.GameStream.topic/1`) as `{:game_stream, id, {:status, map}}`,
  `{:game_stream, id, {:roster, %{slots, spectators, names, max_players, multi, touch}}}`
  and `{:game_stream, id, {:slot_activity, [slot]}}`. Signals are NOT
  published there; they go to one peer's pid.

  ## The row is written once, at the end

  On the transition to a terminal state the session writes its
  `game_stream_sessions` row with the last stats each slot's viewer
  reported (`slot_stats`), the worst slot's figures in the v1 rtt columns,
  and the peak player and spectator counts. A
  failed write is logged and swallowed: losing one measurement must not
  crash the process a viewer is watching.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Platform.Experiments.Surfaces.GameStreamTouch
  alias Platform.GameStream
  alias Platform.GameStream.Protocol
  alias Platform.GameStream.SessionRecord
  alias Platform.GameStream.Supervisor, as: GSSupervisor
  alias Platform.Repo
  alias Platform.Types.UUIDv7

  @default_linger_ms 60_000
  @default_host_grace_ms 20_000
  @default_max_players 4
  @default_max_spectators 4
  # The v1 key for the single peer's pending offer.
  @v1 :v1

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
  # state holds the TURN credential in `ice_servers`, and pending offers'
  # SDP. Neither belongs in a log, so both are redacted here (stage 5).
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, &redact_state/1)
  end

  defp redact_state(%{} = state) do
    state
    |> Map.update(:ice_servers, [], &redact_ice_servers/1)
    |> Map.update(:pending_offers, %{}, fn offers ->
      Map.new(offers, fn {peer_id, _offer} -> {peer_id, :redacted} end)
    end)
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
        roster = Map.get(args, :roster, %{})

        state =
          args
          |> Map.take(
            ~w(session_id task_id review_sha branch repo_url host_runtime_id started_by encoder
               experiment_id variant_slug roster_experiment_id roster_variant_slug
               touch_experiment_id touch_variant_slug idle_timeout_s ice_servers force_relay)a
          )
          |> Map.merge(%{
            state: "building",
            detail: "Waiting for the play host",
            elapsed_ms: 0,
            started_at: now,
            multi: Map.get(args, :multi) == true,
            touch: Map.get(args, :touch) == true,
            touch_tuning: touch_tuning(Map.get(args, :touch_tuning, %{})),
            max_players: roster_int(roster, "max_players", @default_max_players, 1),
            max_spectators: roster_int(roster, "max_spectators", @default_max_spectators, 0),
            open_as: if(Map.get(roster, "open_as") == "join", do: "join", else: "watch"),
            peers: %{},
            slots: %{},
            pending_offers: %{},
            media_peer: nil,
            epoch: 0,
            peak_players: 0,
            peak_spectators: 0,
            stats: %{},
            ended_reason: nil,
            build_ms: nil,
            linger_ms: Map.get(args, :linger_ms, @default_linger_ms),
            host_grace_ms:
              Map.get_lazy(args, :host_grace_ms, fn ->
                Application.get_env(:platform, :game_stream_host_grace_ms, @default_host_grace_ms)
              end),
            host_pid: nil,
            host_away: nil
          })

        # "Start again": the clicking window is a peer and P1 from the start.
        # Nothing is sent to the host yet; handle_continue sends
        # play_session_start first, then this peer's frames.
        state =
          case Map.get(args, :viewer) do
            pid when is_pid(pid) ->
              info = Map.get(args, :viewer_info, %{})
              {state, peer_id} = add_peer(state, pid, info)
              {state, _slot} = claim_free_slot(state, peer_id, 0)
              state

            _ ->
              state
          end

        {:ok, state, {:continue, :dispatch}}

      {:error, {:already_registered, _pid}} ->
        {:stop, :host_busy}
    end
  end

  @impl true
  def handle_continue(:dispatch, state) do
    broadcast_host(state, "play_session_start", Protocol.session_start_payload(state))

    if state.multi and map_size(state.peers) > 0 do
      Enum.each(Map.keys(state.peers), &send_peer_open(state, &1))
      send_slots(state)
    end

    publish_status(state)
    {:noreply, track_peaks(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, {:ok, public_status(state)}, state}

  def handle_call({:host_status, runtime_id, parsed}, {from_pid, _}, state) do
    cond do
      runtime_id != state.host_runtime_id ->
        {:reply, {:error, :not_host}, state}

      terminal?(state) ->
        {:reply, {:error, :terminal}, state}

      true ->
        state = state |> host_spoke(from_pid) |> maybe_resume(parsed)
        state = note_build_ms(state, parsed)

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

  def handle_call({:host_signal, runtime_id, parsed}, {from_pid, _}, state) do
    cond do
      runtime_id != state.host_runtime_id ->
        {:reply, {:error, :not_host}, state}

      terminal?(state) ->
        {:reply, {:error, :terminal}, state}

      true ->
        state = host_spoke(state, from_pid)

        # To one peer's pid only (see "Only a peer's owner talks to the host
        # for it"): a window that does not own the peer must never be handed
        # an offer it could answer.
        case host_signal_target(state, parsed.peer_id) do
          {:ok, key, pid} ->
            if pid,
              do: send(pid, {:game_stream, state.session_id, {:signal, parsed.kind, parsed.data}})

            state =
              if parsed.kind == "offer",
                do: put_in(state.pending_offers[key], parsed.data),
                else: state

            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:slot_activity, runtime_id, parsed}, _from, state) do
    cond do
      runtime_id != state.host_runtime_id -> {:reply, {:error, :not_host}, state}
      terminal?(state) -> {:reply, {:error, :terminal}, state}
      true -> {:reply, publish(state, {:slot_activity, parsed.slots}), state}
    end
  end

  def handle_call({:viewer_signal, {pid, token, peer_id}, parsed}, _from, state) do
    cond do
      terminal?(state) ->
        {:reply, {:error, :terminal}, state}

      not owns_signal_peer?(state, pid, token, peer_id) ->
        Logger.debug(
          "[GameStream] dropped #{parsed.kind} from a window that does not own the peer on #{state.session_id}"
        )

        {:reply, {:error, :moved}, state}

      true ->
        {:ok, own_id, _peer} = peer_for_pid(state, pid)

        payload = %{session_id: state.session_id, kind: parsed.kind, data: parsed.data}
        payload = if state.multi, do: Map.put(payload, :peer_id, own_id), else: payload
        broadcast_host(state, "play_signal", payload)

        key = if state.multi, do: own_id, else: @v1

        state =
          if parsed.kind == "answer",
            do: %{state | pending_offers: Map.delete(state.pending_offers, key)},
            else: state

        {:reply, :ok, state}
    end
  end

  def handle_call({:attach, pid, mode, info}, _from, state)
      when is_pid(pid) and mode in [:watch, :follow] do
    state = prune_dead(state)

    cond do
      # An ended or failed session has nothing to view: attaching to it
      # claims nothing and moves nobody.
      terminal?(state) ->
        {:reply, {:ok, not_attached(state)}, state}

      match?({:ok, _, _}, peer_for_pid(state, pid)) ->
        {:ok, peer_id, _peer} = peer_for_pid(state, pid)
        state = reattach(state, peer_id)
        {:reply, {:ok, attach_reply(state, peer_id)}, state}

      state.multi and not (auto_join?(state, mode) and free_slot(state) != nil) and
          spectator_count(state) >= state.max_spectators ->
        {:reply, {:error, :spectators_full}, state}

      true ->
        {state, peer_id} = add_peer(state, pid, info)

        state =
          if state.multi do
            send_peer_open(state, peer_id)

            {state, _slot} =
              if auto_join?(state, mode),
                do: claim_free_slot(state, peer_id, 0),
                else: {state, nil}

            state
          else
            # v1: the opener takes the single peer only when nobody holds it.
            if is_nil(state.media_peer), do: claim_media(state, peer_id), else: state
          end

        state = changed(state)
        {:reply, {:ok, attach_reply(state, peer_id)}, state}
    end
  end

  def handle_call({:join, pid, src}, from, state),
    do: handle_call({:join, pid, src, nil}, from, state)

  def handle_call({:join, pid, src, prefer}, _from, state) do
    with_peer(state, pid, fn peer_id, peer ->
      cond do
        Map.has_key?(peer.slots, src) ->
          {:reply, {:ok, peer_reply(state, peer_id)}, state}

        state.multi ->
          case claim_free_slot(state, peer_id, src, prefer) do
            {state, nil} ->
              {:reply, {:error, :slots_full}, state}

            {state, _slot} ->
              state = changed(state)
              {:reply, {:ok, peer_reply(state, peer_id)}, state}
          end

        # v1: one slot, held with the media. A free media is claimed.
        src == 0 and is_nil(state.media_peer) ->
          state = state |> claim_media(peer_id) |> changed()

          {:reply, {:ok, Map.put(peer_reply(state, peer_id), :pending_offer, v1_offer(state))},
           state}

        true ->
          {:reply, {:error, :slots_full}, state}
      end
    end)
  end

  def handle_call({:leave, pid, which}, _from, state) do
    with_peer(state, pid, fn peer_id, peer ->
      if state.multi do
        srcs = if which == :all, do: Map.keys(peer.slots), else: [which]
        state = Enum.reduce(srcs, state, &release_src(&2, peer_id, &1)) |> changed()
        {:reply, {:ok, peer_reply(state, peer_id)}, state}
      else
        {:reply, {:error, :single_peer_host}, state}
      end
    end)
  end

  def handle_call({:take_over, pid, slot, src}, _from, state) do
    with_peer(state, pid, fn peer_id, peer ->
      cond do
        not (is_integer(slot) and slot >= 0 and slot < effective_max_players(state)) ->
          {:reply, {:error, :no_such_slot}, state}

        Map.get(state.slots, slot) == peer_id ->
          {:reply, {:ok, peer_reply(state, peer_id)}, state}

        state.multi ->
          state =
            state
            |> release_src(peer_id, src)
            |> displace(slot, peer.name)
            |> assign_slot(peer_id, src, slot)
            |> changed()

          {:reply, {:ok, peer_reply(state, peer_id)}, state}

        true ->
          # v1: slot 0 IS the host's single peer. The previous holder is told
          # :displaced and :moved (it cannot keep video on a v1 host).
          state = state |> displace(slot, peer.name) |> claim_media(peer_id) |> changed()

          {:reply, {:ok, Map.put(peer_reply(state, peer_id), :pending_offer, v1_offer(state))},
           state}
      end
    end)
  end

  def handle_call({:report_stats, pid, slot_hint, stats}, _from, state) do
    case stats_slot(state, pid, slot_hint) do
      nil ->
        {:reply, :ok, state}

      slot ->
        merged = Map.merge(Map.get(state.stats, slot, %{}), stats)
        {:reply, :ok, %{state | stats: Map.put(state.stats, slot, merged)}}
    end
  end

  def handle_call(:roster, _from, state), do: {:reply, {:ok, roster(state)}, state}

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

  def handle_call(:host_disconnected, from, state),
    do: handle_call({:host_disconnected, nil}, from, state)

  def handle_call({:host_disconnected, channel_pid}, _from, state) do
    cond do
      terminal?(state) ->
        {:reply, :ok, state}

      # The host already came back on a newer channel (it spoke from it)
      # before this old channel's terminate/2 ran.
      is_pid(channel_pid) and is_pid(state.host_pid) and channel_pid != state.host_pid ->
        {:reply, :ok, state}

      true ->
        ref = make_ref()
        Process.send_after(self(), {:host_grace_over, ref}, state.host_grace_ms)

        Logger.info(
          "[GameStream] host #{state.host_runtime_id} dropped; session #{state.session_id} " <>
            "waits #{state.host_grace_ms} ms for it to resume"
        )

        {:reply, :ok, %{state | host_away: ref}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.peers, fn {_id, peer} -> peer.ref == ref end) do
      {peer_id, _peer} -> {:noreply, state |> drop_peer(peer_id) |> changed()}
      nil -> {:noreply, state}
    end
  end

  def handle_info(:linger_over, state), do: {:stop, :normal, state}

  def handle_info({:host_grace_over, ref}, %{host_away: ref} = state) do
    if terminal?(state) do
      {:noreply, %{state | host_away: nil}}
    else
      detail = "The play host disconnected"
      {:noreply, finish(%{state | state: "failed", detail: detail, host_away: nil}, detail)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── A host that drops ───────────────────────────────────────────────────

  defp host_spoke(state, pid) when is_pid(pid), do: %{state | host_pid: pid}
  defp host_spoke(state, _pid), do: state

  # The host's one status after its socket rejoined. Ends the wait (if one
  # is running) and re-sends what the host may have missed while it was
  # gone. A v1 host sends no resume.
  defp maybe_resume(state, %{resume: true, peers: host_peers}) do
    Logger.info(
      "[GameStream] host #{state.host_runtime_id} resumed session #{state.session_id} " <>
        "(#{length(host_peers)} peer(s) on the host, #{map_size(state.peers)} in core)"
    )

    state = %{state | host_away: nil}
    if state.multi, do: resync_peers(state, host_peers), else: state
  end

  defp maybe_resume(state, _parsed), do: state

  defp resync_peers(state, host_peers) do
    on_host = MapSet.new(host_peers)
    missing = Enum.reject(Map.keys(state.peers), &MapSet.member?(on_host, &1))
    Enum.each(missing, &send_peer_open(state, &1))

    host_peers
    |> Enum.reject(&Map.has_key?(state.peers, &1))
    |> Enum.each(fn peer_id ->
      broadcast_host(
        state,
        "play_peer_close",
        Protocol.peer_close_payload(state.session_id, peer_id)
      )
    end)

    send_slots(state)
    %{state | pending_offers: Map.drop(state.pending_offers, missing)}
  end

  # ── Peers ───────────────────────────────────────────────────────────────

  defp add_peer(state, pid, info) do
    peer_id = UUIDv7.generate()
    epoch = state.epoch + 1

    peer = %{
      pid: pid,
      ref: Process.monitor(pid),
      token: epoch,
      user_id: Map.get(info, :user_id),
      name: Map.get(info, :name),
      slots: %{}
    }

    {%{state | peers: Map.put(state.peers, peer_id, peer), epoch: epoch}, peer_id}
  end

  # The same pid attaching again (a twin copy in the page taking the stream
  # back, a panel reopened): a fresh token retires the one the older copy
  # held. A multi host is asked for a fresh offer NOW (play_peer_open), so the
  # new copy does not wait for the old peer to time out (stage 1's H3). The
  # old pending offer belongs to the peer connection being replaced.
  defp reattach(state, peer_id) do
    epoch = state.epoch + 1
    state = %{state | epoch: epoch}
    state = update_in(state.peers[peer_id], &%{&1 | token: epoch})

    cond do
      state.multi ->
        send_peer_open(state, peer_id)
        %{state | pending_offers: Map.delete(state.pending_offers, peer_id)}

      is_nil(state.media_peer) ->
        state |> claim_media(peer_id) |> changed()

      true ->
        state
    end
  end

  defp drop_peer(state, peer_id) do
    case Map.fetch(state.peers, peer_id) do
      {:ok, peer} ->
        Process.demonitor(peer.ref, [:flush])
        state = Enum.reduce(Map.keys(peer.slots), state, &release_src(&2, peer_id, &1))

        state = %{
          state
          | peers: Map.delete(state.peers, peer_id),
            pending_offers: Map.delete(state.pending_offers, peer_id)
        }

        cond do
          state.multi and not terminal?(state) ->
            broadcast_host(
              state,
              "play_peer_close",
              Protocol.peer_close_payload(state.session_id, peer_id)
            )

            state

          state.media_peer == peer_id ->
            %{state | media_peer: nil}

          true ->
            state
        end

      :error ->
        state
    end
  end

  defp prune_dead(state) do
    state.peers
    |> Enum.reject(fn {_id, peer} -> Process.alive?(peer.pid) end)
    |> Enum.reduce(state, fn {peer_id, _peer}, acc -> acc |> drop_peer(peer_id) |> changed() end)
  end

  defp peer_for_pid(state, pid) do
    case Enum.find(state.peers, fn {_id, peer} -> peer.pid == pid end) do
      {peer_id, peer} -> {:ok, peer_id, peer}
      nil -> :error
    end
  end

  defp with_peer(state, pid, fun) do
    state = prune_dead(state)

    if terminal?(state) do
      {:reply, {:error, :terminal}, state}
    else
      case peer_for_pid(state, pid) do
        {:ok, peer_id, peer} -> fun.(peer_id, peer)
        :error -> {:reply, {:error, :not_attached}, state}
      end
    end
  end

  # The peer-owner check. `peer_id` nil means "the pid's own peer" (a v1
  # client sends none). Owned means: the named peer exists, belongs to this
  # pid, and carries this token. On a v1 host the peer must also hold the
  # single media peer.
  defp owns_signal_peer?(state, pid, token, peer_id) do
    case peer_for_pid(state, pid) do
      {:ok, own_id, peer} ->
        (is_nil(peer_id) or peer_id == own_id) and peer.token == token and
          (state.multi or state.media_peer == own_id)

      :error ->
        false
    end
  end

  defp host_signal_target(%{multi: true} = state, peer_id) when is_binary(peer_id) do
    case Map.fetch(state.peers, peer_id) do
      {:ok, peer} -> {:ok, peer_id, peer.pid}
      :error -> {:error, :unknown_peer}
    end
  end

  defp host_signal_target(%{multi: true}, _peer_id), do: {:error, :unknown_peer}

  defp host_signal_target(state, _peer_id) do
    pid =
      case state.media_peer && Map.get(state.peers, state.media_peer) do
        %{pid: pid} -> pid
        _ -> nil
      end

    {:ok, @v1, pid}
  end

  # ── Slots ───────────────────────────────────────────────────────────────

  defp effective_max_players(%{multi: true} = state), do: state.max_players
  defp effective_max_players(_state), do: 1

  defp auto_join?(state, mode), do: mode == :watch and state.open_as == "join"

  # The next free slot for `src` of `peer_id`, or nil when every slot is taken.
  # `prefer` is used when it names a free slot; a join never displaces.
  defp claim_free_slot(state, peer_id, src, prefer \\ nil) do
    free =
      if is_integer(prefer) and prefer < effective_max_players(state) and
           not Map.has_key?(state.slots, prefer),
         do: prefer,
         else: free_slot(state)

    cond do
      is_nil(free) -> {state, nil}
      state.multi -> {assign_slot(state, peer_id, src, free), free}
      true -> {claim_media(state, peer_id), free}
    end
  end

  defp free_slot(state),
    do: Enum.find(0..(effective_max_players(state) - 1), &(not Map.has_key?(state.slots, &1)))

  defp assign_slot(state, peer_id, src, slot) do
    state = update_in(state.peers[peer_id].slots, &Map.put(&1, src, slot))
    %{state | slots: Map.put(state.slots, slot, peer_id)}
  end

  defp release_src(state, peer_id, src) do
    case get_in(state.peers, [peer_id, :slots, src]) do
      nil ->
        state

      slot ->
        state = update_in(state.peers[peer_id].slots, &Map.delete(&1, src))
        %{state | slots: Map.delete(state.slots, slot)}
    end
  end

  # Takes `slot` away from whoever holds it. The holder keeps its peer (and,
  # on a multi host, its video); on a v1 host it also loses the media.
  defp displace(state, slot, by_name) do
    case Map.get(state.slots, slot) do
      nil ->
        state

      holder_id ->
        holder = Map.fetch!(state.peers, holder_id)
        {src, ^slot} = Enum.find(holder.slots, fn {_src, s} -> s == slot end)
        send(holder.pid, {:game_stream, state.session_id, {:displaced, slot, by_name}})
        state = release_src(state, holder_id, src)

        if state.multi do
          state
        else
          send(holder.pid, {:game_stream, state.session_id, :moved})
          %{state | media_peer: nil}
        end
    end
  end

  # v1 only: `peer_id` holds the host's single peer and slot 0.
  defp claim_media(state, peer_id) do
    state =
      case state.media_peer do
        nil -> state
        ^peer_id -> state
        old -> Enum.reduce(Map.keys(state.peers[old].slots), state, &release_src(&2, old, &1))
      end

    state = %{state | media_peer: peer_id}

    case Map.get(state.slots, 0) do
      nil -> assign_slot(state, peer_id, 0, 0)
      _ -> state
    end
  end

  defp v1_offer(state), do: Map.get(state.pending_offers, @v1)

  defp spectator_count(state),
    do: Enum.count(state.peers, fn {_id, peer} -> map_size(peer.slots) == 0 end)

  # After any change to peers or slots: a full snapshot to a multi host, the
  # roster to every viewer, and the peaks for the row.
  defp changed(state) do
    if state.multi and not terminal?(state), do: send_slots(state)
    publish(state, {:roster, roster(state)})
    track_peaks(state)
  end

  defp track_peaks(state) do
    %{
      state
      | peak_players: max(state.peak_players, map_size(state.slots)),
        peak_spectators: max(state.peak_spectators, spectator_count(state))
    }
  end

  defp send_peer_open(state, peer_id) do
    broadcast_host(state, "play_peer_open", Protocol.peer_open_payload(state.session_id, peer_id))
  end

  defp send_slots(state) do
    peers = Map.new(state.peers, fn {peer_id, peer} -> {peer_id, peer.slots} end)

    broadcast_host(
      state,
      "play_slots",
      Protocol.slots_payload(state.session_id, state.max_players, peers)
    )
  end

  # The roster every viewer renders: who holds which slot, and how many watch.
  defp roster(state) do
    slots =
      Map.new(state.slots, fn {slot, peer_id} ->
        peer = Map.fetch!(state.peers, peer_id)
        {slot, %{peer_id: peer_id, name: peer.name, user_id: peer.user_id}}
      end)

    spectators = Enum.filter(state.peers, fn {_id, peer} -> map_size(peer.slots) == 0 end)

    %{
      slots: slots,
      spectators: length(spectators),
      names: spectators |> Enum.map(fn {_id, peer} -> peer.name end) |> Enum.reject(&is_nil/1),
      max_players: effective_max_players(state),
      # The canvas shows the roster strip, Join, Leave and the overflow only
      # for a multi host (task 01a0dbd6 stage 4); a v1 host keeps Play here.
      multi: state.multi,
      # The roster is what the attach reply and every roster push carry to the
      # browser whole, so the touch gate and tuning ride here (01a0fe45).
      touch: touch(state)
    }
  end

  # `enabled` is false whenever the host lacks `game_stream_touch`; the
  # tuning is still reported, so the arm is visible either way.
  defp touch(state) do
    tuning = Map.get(state, :touch_tuning, touch_tuning(%{}))

    %{
      enabled: Map.get(state, :touch) == true,
      slop_px: tuning.slop_px,
      move_hz: tuning.move_hz,
      variant: Map.get(state, :touch_variant_slug)
    }
  end

  # A resolved payload is already validated by the surface. Re-validating
  # keeps a malformed one (a hand-built arg) from reaching the browser: it
  # falls back to the control whole, as `resolve_touch/1` does.
  defp touch_tuning(payload) do
    tuning =
      case GameStreamTouch.validate_payload(payload) do
        {:ok, valid} -> valid
        {:error, _} -> GameStreamTouch.control()
      end

    %{slop_px: tuning["slop_px"], move_hz: tuning["move_hz"]}
  end

  defp attach_reply(state, peer_id) do
    offer =
      if state.multi,
        do: Map.get(state.pending_offers, peer_id),
        else: if(state.media_peer == peer_id, do: v1_offer(state))

    state
    |> public_status()
    |> Map.merge(peer_reply(state, peer_id))
    |> Map.merge(%{pending_offer: offer, roster: roster(state)})
  end

  defp peer_reply(state, peer_id) do
    peer = Map.fetch!(state.peers, peer_id)
    viewer? = state.multi or state.media_peer == peer_id

    %{
      peer_id: peer_id,
      viewer: viewer?,
      viewer_token: if(viewer?, do: peer.token),
      role: if(map_size(peer.slots) > 0, do: :player, else: :spectator),
      slots: peer.slots
    }
  end

  defp not_attached(state) do
    state
    |> public_status()
    |> Map.merge(%{
      peer_id: nil,
      viewer: false,
      viewer_token: nil,
      role: nil,
      slots: %{},
      pending_offer: nil,
      roster: roster(state)
    })
  end

  # Stats are kept per slot. The slot is the reporting pid's own: the hint is
  # used only when that peer holds it, otherwise its lowest slot. A spectator
  # (no slot) has no input-to-photon to report, so its stats are dropped. A
  # caller with no pid (the v1 two-argument API) reports for slot 0.
  defp stats_slot(_state, nil, _hint), do: 0

  defp stats_slot(state, pid, hint) do
    case peer_for_pid(state, pid) do
      {:ok, _peer_id, %{slots: slots}} when map_size(slots) > 0 ->
        held = Map.values(slots)
        if hint in held, do: hint, else: Enum.min(held)

      _ ->
        nil
    end
  end

  defp roster_int(roster, key, default, min) do
    case Map.get(roster, key) do
      n when is_integer(n) and n >= min -> n
      _ -> default
    end
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp terminal?(state), do: state.state in Protocol.terminal_states()

  # The first time the host leaves `building` for `connecting` or `live`, the
  # elapsed time it reports is how long the build took. A session that fails
  # or is stopped while building records none, so a failed build never
  # becomes "the last build" the Building card compares against.
  defp note_build_ms(%{state: "building", build_ms: nil} = state, %{state: next} = parsed)
       when next in ["connecting", "live"] do
    ms = if is_integer(parsed.elapsed_ms) and parsed.elapsed_ms > 0, do: parsed.elapsed_ms
    %{state | build_ms: ms || DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)}
  end

  defp note_build_ms(state, _parsed), do: state

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
    state = %{state | ended_reason: reason, pending_offers: %{}}
    record(state)
    publish_status(state)
    Process.send_after(self(), :linger_over, state.linger_ms)
    state
  end

  @doc """
  The row's figures from per-slot stats: `slot_stats` (string slot keys, as
  JSON stores them) and the WORST slot's `rtt_p50_ms`, `rtt_p95_ms`,
  `fps_avg` and `connection_path` for the v1 columns. Worst is the highest
  `rtt_p95_ms` (then `rtt_p50_ms`); a slot that reported neither is never
  worst. With one slot, the columns are that slot's figures exactly.
  """
  @spec summarize_stats(%{non_neg_integer() => map()}) :: map()
  def summarize_stats(stats) when is_map(stats) do
    slot_stats =
      Map.new(stats, fn {slot, s} ->
        {Integer.to_string(slot),
         Map.new(Map.take(s, [:rtt_p50_ms, :rtt_p95_ms, :fps_avg, :connection_path]), fn {k, v} ->
           {Atom.to_string(k), v}
         end)}
      end)

    worst =
      stats
      |> Map.values()
      |> Enum.filter(&(is_number(&1[:rtt_p95_ms]) or is_number(&1[:rtt_p50_ms])))
      |> Enum.max_by(&{&1[:rtt_p95_ms] || -1, &1[:rtt_p50_ms] || -1}, fn -> %{} end)

    %{
      slot_stats: slot_stats,
      rtt_p50_ms: worst[:rtt_p50_ms],
      rtt_p95_ms: worst[:rtt_p95_ms],
      fps_avg: worst[:fps_avg],
      connection_path: worst[:connection_path]
    }
  end

  defp record(state) do
    {kind, id} =
      case state.started_by do
        {kind, id} when kind in [:agent, :user] -> {Atom.to_string(kind), id}
        _ -> {nil, nil}
      end

    summary = summarize_stats(state.stats)

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
      roster_experiment_id: Map.get(state, :roster_experiment_id),
      roster_variant_slug: Map.get(state, :roster_variant_slug),
      encoder: state.encoder,
      connection_path: summary.connection_path,
      rtt_p50_ms: summary.rtt_p50_ms,
      rtt_p95_ms: summary.rtt_p95_ms,
      fps_avg: summary.fps_avg,
      slot_stats: summary.slot_stats,
      peak_players: state.peak_players,
      peak_spectators: state.peak_spectators,
      ended_state: state.state,
      ended_reason: state.ended_reason,
      build_ms: Map.get(state, :build_ms),
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
      force_relay: Map.get(state, :force_relay) == true,
      multi: state.multi,
      max_players: effective_max_players(state),
      touch: touch(state)
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

defmodule Platform.GameStream.Protocol do
  @moduledoc """
  The wire contract between core and a play host (task 01a0db5f stage 2).

  A play host is an external runtime (the `Startup-Suite/play-host` binary on
  wave) that joins `runtime:<runtime_id>` over the ordinary runtime websocket
  (`PlatformWeb.RuntimeSocket` / `PlatformWeb.RuntimeChannel`). Stage 3
  implements this contract on the host side EXACTLY as written here; if the
  contract is wrong, it is fixed here first and the host follows.

  ## Discovery

  A host is a PRESENT runtime (`Platform.Federation.RuntimePresence`) whose
  row is `active` and whose `metadata["client_info"]["features"]` contains
  `"game_stream_host"` — the list the channel persists from the join
  payload's `client_info.features`. The host's `client_info.product` may be
  any string: an unrecognised product is stored as `"unknown"` but its
  `features` are persisted all the same, so no `@valid_client_products`
  entry is needed. See `Platform.Federation.present_runtimes_with_feature/1`.

  ## Core → host (Phoenix broadcasts onto `runtime:<runtime_id>`)

  Sent with `PlatformWeb.Endpoint.broadcast/3`, in the shape of
  `Platform.Meetings`' `meeting_join` dispatch. Phoenix pushes a broadcast on
  a channel topic straight to the joined client.

    * `play_session_start` —
      `%{session_id, task_id, repo_url, branch, sha, encoder, ice_servers, idle_timeout_s}`.
      `task_id` names the task whose review build this is; the host uses
      its first 8 hex to name the checkout (`<task8>-<sha12>`, stage 3).
      `sha` is the 40-hex tip of `branch` at the moment the session started;
      the host checks out THAT sha (never the branch head it sees later, and
      never main). `encoder` is the resolved `game_stream.encoder_preset`
      payload (`preset`, `tune`, `bitrate_kbps`, `fps`, `width`, `height`,
      `gop_frames`). `ice_servers` is a list of RTCIceServer-shaped maps
      (`%{urls: [..], username?, credential?}`); it is `[]` until stage 5
      configures TURN, which means host candidates only (LAN).
    * `play_session_stop` — `%{session_id, reason}`. The host kills the
      Godot it launched (its own Job Object, never by process name) and
      answers with a final `play_session_status` of `ended`.
    * `play_signal` — `%{session_id, kind, data}` where `kind` is `"answer"`
      or `"ice"`. Relayed from the viewer's browser.

  ## Host → core (`handle_in` on `PlatformWeb.RuntimeChannel`)

    * `play_session_status` —
      `%{session_id, state, detail, elapsed_ms}` where `state` is one of
      `building | connecting | live | ended | failed`. `detail` is a short
      human-readable line (at most 500 bytes) and `elapsed_ms` a
      non-negative integer. `ended` and `failed` are terminal.
    * `play_signal` — `%{session_id, kind, data}` where `kind` is `"offer"`
      or `"ice"`. The HOST creates the WebRTC offer; the viewer answers.

  ## What `play_signal` `data` holds

  Core relays `data` opaquely and bounds only its encoded size. Host and
  viewer agree on these shapes (stage 3, `Startup-Suite/play-host`
  `internal/protocol`):

    * `offer` / `answer` — an `RTCSessionDescriptionInit`,
      `%{"type" => "offer" | "answer", "sdp" => sdp}`. The host sends a
      COMPLETE (non-trickle) offer: every host candidate is already in the
      SDP, so the host sends no `ice` of its own in v1.
    * `ice` (viewer → host) — an `RTCIceCandidateInit`,
      `%{"candidate", "sdpMid", "sdpMLineIndex", "usernameFragment"?}`;
      `nil` or an empty `candidate` is end-of-candidates. Candidates that
      arrive before the answer are queued by the host.

  The host re-offers whenever its viewer peer ends (failed, closed, or
  disconnected for 5 s): it publishes a fresh `offer` and reports
  `connecting` again. Core keeps the latest offer until a viewer answers it
  and hands it to a window that attaches later (stage 4,
  `Platform.GameStream.Session`), so a viewer that opens the canvas after the
  offer went out can still answer it. The host needs no "viewer attached"
  signal for that; nothing new crosses the wire.

  Core relays a viewer's `answer`/`ice` to the host ONLY from the session's
  current viewer (stage 6: a per-attach `viewer_token`), and sends the
  host's `offer` only to that viewer. So the host sees at most one answer
  per offer. The host still treats a second answer as an error to log, not
  a reason to fail the session.

  An idle end is reported as `ended` with the detail `"idle"`; core words it
  for display ("Session ended after 10 minutes idle") from the session's
  `idle_timeout_s`.

  A frame naming a session the sending runtime does not host is dropped: a
  host can only ever speak for its own session. Both `handle_in` clauses do
  nothing but log (once per channel process) while `GAME_STREAM_ENABLED` is
  unset.

  ## Widening: peers, player slots and spectators (task 01a0dbd6-76bb-7001-a322-08a81e3d7927)

  One session per host still holds, and N browsers attach to it. The unit
  the wire names is a PEER: one WebRTC peer connection between the host and
  one LiveView, identified by a `peer_id` that CORE mints (a UUIDv7 string).
  A peer is not a player. A spectator has a peer and no slot, and one browser
  with two pads is one peer holding two slots. (The v1 text reserved an
  optional `slot` key on `play_signal`, "one WebRTC peer per slot"; that
  unit was wrong for both cases above, so the key is `peer_id` instead.)

  Every frame below is additive. Both sides still ignore keys they do not
  know, in any frame.

  ### `play_signal` gains `peer_id`

  `play_signal` carries an optional `peer_id` in BOTH directions. Absent (or
  null) means the v1 single peer. A host that declares `game_stream_multi`
  tags every offer and ice it sends with the peer it belongs to, and core
  tags every answer and ice it relays with the peer that sent it.

  ### Core → host

    * `play_peer_open` — `%{session_id, peer_id}`. Create the peer, or
      REPLACE it if it exists (close the old peer connection), and publish a
      fresh peer-tagged `offer`. Core sends it when a peer attaches and when
      the same LiveView re-attaches (a twin copy in the page, a panel
      reopened). The re-attach case is the point: without it the new copy
      waits for an offer the host sends only after the old peer times out,
      which task 01a0dbd6 stage 1 measured at about 10.7 s over TURN. A host
      that is still building keeps the peer set and creates the peer
      connections once its media is ready.
    * `play_peer_close` — `%{session_id, peer_id}`. Close that peer and
      release its slots. Sent when the peer's LiveView goes away.
    * `play_slots` — `%{session_id, max_players, peers}` where `peers` is
      `%{peer_id => %{src => slot}}`: a FULL, idempotent snapshot of every
      attached peer, spectators included with an empty map, sent on every
      change. `src` is the browser's local controller ordinal (0 = keyboard
      and the first pad, 1 = the second pad, and so on); `slot` is the
      0-based player slot (P1 is slot 0). JSON carries both map keys as
      strings. The host binds a peer's input to the slot this table names
      for `(peer_id, src)` and never to a `slot` the browser sends; a peer
      with no slot has its input dropped (play-host, stage 3).

  ### Host → core

    * `play_slot_activity` — `%{session_id, slots: [slot]}`: the slots that
      saw input since the last frame, throttled on the host to at most 4 per
      second. Core relays it on the session's PubSub topic for the roster's
      activity dots and stores nothing.

  ### Capability gate

  A host declares `game_stream_multi` in `client_info.features`. Against a
  host WITHOUT it core keeps the v1 single-peer wiring: none of the frames
  above are sent, `play_signal` carries no `peer_id`, only one attached peer
  holds the media at a time, and there is one slot. Attaching still defaults
  to WATCH semantics: opening a canvas never moves the peer that holds the
  stream, and the other window offers an explicit "Play here", which is a
  take-over of slot 0. So core may deploy before play-host does.

  ### Who may signal

  Core relays a viewer's `answer`/`ice` for a peer only when it arrives from
  the LiveView pid that owns that peer, carrying that peer's current token.
  Anything else (another peer's id, a stale token, a pid that owns no peer)
  is refused `:moved` and never reaches the host. Host signals for a peer go
  to that peer's LiveView only.

  ## Resume: a session outlives a dropped runtime socket (task 01a0dbd6 stage 6)

  The media is browser to host and never passes through core, so a dropped
  runtime socket does not stop anyone's video. Before this, one drop failed
  the session for every viewer ("The play host disconnected"): the review of
  task 01a0dbd6 saw two drops in about 35 minutes of relay runs.

    * When the host's channel goes down, the session is NOT failed at once.
      It waits `config :platform, :game_stream_host_grace_ms` (default
      20 s) for the host to come back; only then does it fail with
      "The play host disconnected". A drop reported by a channel that is no
      longer the session's newest (the host already came back on a new one)
      is ignored.
    * After the host rejoins it sends ONE `play_session_status` carrying
      `resume: true` and `peers: [peer_id]`, the peers it still holds. That
      ends the wait. Core then sends `play_peer_open` for each peer it holds
      that the host does not (a joiner whose open was lost with the socket),
      `play_peer_close` for each the host holds that core does not, and a
      fresh `play_slots`. The host itself re-offers every peer that is not
      connected, since its offer or the answer may have been lost too.
    * A resume for a session core no longer runs (it ended, or its wait ran
      out) is answered with `play_session_stop`, so the host stops streaming
      to nobody.

  ## Why a second media plane, stated so a later task does not build a third

  Meetings already carry media over LiveKit (ADR 0030), with an SFU, TURN and
  a browser client. This protocol deliberately does NOT reuse it: a game
  stream is one sender and one viewer, and its budget is input-to-photon
  latency against a 50 ms target. An SFU hop, plus LiveKit's room model
  (tokens, participants, simulcast layers) costs latency and buys nothing for
  a 1:1 stream. So v1 is peer-to-peer pion WebRTC between the host and the
  browser, with signalling relayed over the runtime channel and LiveView.
  A future feature that wants 1:N viewing should extend THIS path or move
  both onto LiveKit — not add a third. The multiplayer widening above is
  that extension: one encode fanned out to N pion peers on the host, over
  the same runtime channel and `play_signal`.
  """

  @states ~w(building connecting live ended failed)
  @terminal_states ~w(ended failed)
  @host_signal_kinds ~w(offer ice)
  @viewer_signal_kinds ~w(answer ice)

  @multi_feature "game_stream_multi"
  @max_peer_id_bytes 64
  # A host has at most a handful of slots; this bounds an abusive frame.
  @max_activity_slots 32
  # A resume lists every peer the host holds: players plus spectators, far
  # under this (the roster caps are 4 + 4 by default).
  @max_resume_peers 64

  @max_detail_bytes 500
  # An SDP offer with a handful of candidates is a few KB; 64 KB is a
  # generous abuse cap on a payload core relays but never parses.
  @max_signal_bytes 64 * 1024

  @doc "Every session state the protocol names."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The states after which a session never changes again."
  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @doc "The signal kinds a host may send (`offer`, `ice`)."
  @spec host_signal_kinds() :: [String.t()]
  def host_signal_kinds, do: @host_signal_kinds

  @doc "The signal kinds a viewer may send (`answer`, `ice`)."
  @spec viewer_signal_kinds() :: [String.t()]
  def viewer_signal_kinds, do: @viewer_signal_kinds

  @doc "The `client_info.features` entry a host declares to speak the multi-peer frames."
  @spec multi_feature() :: String.t()
  def multi_feature, do: @multi_feature

  @doc "The channel topic a host joins."
  @spec host_topic(String.t()) :: String.t()
  def host_topic(runtime_id) when is_binary(runtime_id), do: "runtime:" <> runtime_id

  @doc """
  The `play_session_start` payload, built from a session's state. The
  session holds the commit as `review_sha`; on the wire it is `sha`.
  """
  @spec session_start_payload(map()) :: map()
  def session_start_payload(%{} = s) do
    %{
      session_id: s.session_id,
      task_id: s.task_id,
      repo_url: s.repo_url,
      branch: s.branch,
      sha: s.review_sha,
      encoder: s.encoder,
      ice_servers: s.ice_servers,
      idle_timeout_s: s.idle_timeout_s
    }
  end

  @doc "The `play_session_stop` payload."
  @spec session_stop_payload(String.t(), String.t()) :: map()
  def session_stop_payload(session_id, reason), do: %{session_id: session_id, reason: reason}

  @doc "The `play_peer_open` payload."
  @spec peer_open_payload(String.t(), String.t()) :: map()
  def peer_open_payload(session_id, peer_id), do: %{session_id: session_id, peer_id: peer_id}

  @doc "The `play_peer_close` payload."
  @spec peer_close_payload(String.t(), String.t()) :: map()
  def peer_close_payload(session_id, peer_id), do: %{session_id: session_id, peer_id: peer_id}

  @doc """
  The `play_slots` payload: a full snapshot. `peers` is
  `%{peer_id => %{src => slot}}` and must list every attached peer,
  spectators with an empty map.
  """
  @spec slots_payload(String.t(), pos_integer(), %{String.t() => map()}) :: map()
  def slots_payload(session_id, max_players, peers),
    do: %{session_id: session_id, max_players: max_players, peers: peers}

  @doc """
  Validates a host's `play_slot_activity` frame. Returns
  `{:ok, %{session_id, slots}}` with `slots` a sorted, de-duplicated list of
  non-negative integers, or `{:error, reason}`.
  """
  @spec parse_slot_activity(map()) :: {:ok, map()} | {:error, atom()}
  def parse_slot_activity(%{"session_id" => id, "slots" => slots})
      when is_binary(id) and is_list(slots) do
    cond do
      length(slots) > @max_activity_slots ->
        {:error, :too_many_slots}

      Enum.all?(slots, &(is_integer(&1) and &1 >= 0)) ->
        {:ok, %{session_id: id, slots: slots |> Enum.uniq() |> Enum.sort()}}

      true ->
        {:error, :bad_slots}
    end
  end

  def parse_slot_activity(_), do: {:error, :malformed}

  @doc """
  Validates a host's `play_session_status` frame.

  Returns `{:ok, %{session_id, state, detail, elapsed_ms, resume, peers}}`
  or `{:error, reason}`. An over-long `detail` is truncated rather than
  rejected: it is display text, and dropping a `failed` status because its
  explanation ran long would hide the failure.

  `resume` is true only for the one status a host sends after its socket
  rejoined (see "Resume"); `peers` is then the list of peer ids it still
  holds (nil otherwise). A resume whose `peers` is not a list of at most
  #{@max_resume_peers} peer ids is refused.
  """
  @spec parse_status(map()) :: {:ok, map()} | {:error, atom()}
  def parse_status(%{"session_id" => id, "state" => state} = payload)
      when is_binary(id) and is_binary(state) do
    elapsed = Map.get(payload, "elapsed_ms")
    resume? = Map.get(payload, "resume") == true

    cond do
      state not in @states ->
        {:error, :unknown_state}

      not (is_nil(elapsed) or (is_integer(elapsed) and elapsed >= 0)) ->
        {:error, :bad_elapsed_ms}

      resume? and not valid_resume_peers?(Map.get(payload, "peers")) ->
        {:error, :bad_resume_peers}

      true ->
        {:ok,
         %{
           session_id: id,
           state: state,
           detail: truncate_detail(Map.get(payload, "detail")),
           elapsed_ms: elapsed,
           resume: resume?,
           peers: if(resume?, do: Map.get(payload, "peers"), else: nil)
         }}
    end
  end

  def parse_status(_), do: {:error, :malformed}

  @doc """
  Validates a `play_signal` frame from `direction` (`:host` or `:viewer`).

  Returns `{:ok, %{session_id, kind, data, peer_id}}` or `{:error, reason}`.
  `data` is relayed opaquely; only its encoded size is bounded. `peer_id` is
  nil when the frame carries none (the v1 single peer); a `peer_id` that is
  not a short string is refused.
  """
  @spec parse_signal(:host | :viewer, map()) :: {:ok, map()} | {:error, atom()}
  def parse_signal(direction, %{"session_id" => id, "kind" => kind} = payload)
      when is_binary(id) and is_binary(kind) do
    allowed = if direction == :host, do: @host_signal_kinds, else: @viewer_signal_kinds
    data = Map.get(payload, "data")
    peer_id = Map.get(payload, "peer_id")

    cond do
      kind not in allowed -> {:error, :bad_signal_kind}
      not valid_peer_id?(peer_id) -> {:error, :bad_peer_id}
      oversized?(data) -> {:error, :signal_too_large}
      true -> {:ok, %{session_id: id, kind: kind, data: data, peer_id: peer_id}}
    end
  end

  def parse_signal(_direction, _), do: {:error, :malformed}

  defp valid_resume_peers?(peers) when is_list(peers),
    do:
      length(peers) <= @max_resume_peers and
        Enum.all?(peers, &(is_binary(&1) and valid_peer_id?(&1)))

  defp valid_resume_peers?(_), do: false

  defp valid_peer_id?(nil), do: true

  defp valid_peer_id?(peer_id) when is_binary(peer_id),
    do: peer_id != "" and byte_size(peer_id) <= @max_peer_id_bytes

  defp valid_peer_id?(_), do: false

  defp truncate_detail(detail) when is_binary(detail) do
    if byte_size(detail) <= @max_detail_bytes do
      detail
    else
      detail |> binary_part(0, @max_detail_bytes) |> String.replace_invalid()
    end
  end

  defp truncate_detail(_), do: nil

  defp oversized?(data) do
    case Jason.encode(data) do
      {:ok, json} -> byte_size(json) > @max_signal_bytes
      {:error, _} -> true
    end
  end
end

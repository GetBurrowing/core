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

  ## Widening to several players (follow-on task 01a0dbd6-76bb-7001-a322-08a81e3d7927)

  v1 is one session per host and ONE viewer per session: the latest window
  the user acted in wins and the previous one is told `:moved`. The follow-on keeps one
  session per host but allows N simultaneous viewers or gamepads as player
  slots. To keep that a widening rather than a rewrite: both sides MUST
  ignore keys they do not know in any frame above, and no v1 payload names
  "the" viewer — the expected widening is an optional `slot` key on
  `play_signal` (one WebRTC peer per slot), with the session's single
  `viewer` field becoming a slot-to-viewer map.

  ## Why a second media plane, stated so a later task does not build a third

  Meetings already carry media over LiveKit (ADR 0030), with an SFU, TURN and
  a browser client. This protocol deliberately does NOT reuse it: a game
  stream is one sender and one viewer, and its budget is input-to-photon
  latency against a 50 ms target. An SFU hop, plus LiveKit's room model
  (tokens, participants, simulcast layers) costs latency and buys nothing for
  a 1:1 stream. So v1 is peer-to-peer pion WebRTC between the host and the
  browser, with signalling relayed over the runtime channel and LiveView.
  A future feature that wants 1:N viewing should extend THIS path or move
  both onto LiveKit — not add a third.
  """

  @states ~w(building connecting live ended failed)
  @terminal_states ~w(ended failed)
  @host_signal_kinds ~w(offer ice)
  @viewer_signal_kinds ~w(answer ice)

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

  @doc """
  Validates a host's `play_session_status` frame.

  Returns `{:ok, %{session_id, state, detail, elapsed_ms}}` or
  `{:error, reason}`. An over-long `detail` is truncated rather than
  rejected: it is display text, and dropping a `failed` status because its
  explanation ran long would hide the failure.
  """
  @spec parse_status(map()) :: {:ok, map()} | {:error, atom()}
  def parse_status(%{"session_id" => id, "state" => state} = payload)
      when is_binary(id) and is_binary(state) do
    elapsed = Map.get(payload, "elapsed_ms")

    cond do
      state not in @states ->
        {:error, :unknown_state}

      not (is_nil(elapsed) or (is_integer(elapsed) and elapsed >= 0)) ->
        {:error, :bad_elapsed_ms}

      true ->
        {:ok,
         %{
           session_id: id,
           state: state,
           detail: truncate_detail(Map.get(payload, "detail")),
           elapsed_ms: elapsed
         }}
    end
  end

  def parse_status(_), do: {:error, :malformed}

  @doc """
  Validates a `play_signal` frame from `direction` (`:host` or `:viewer`).

  Returns `{:ok, %{session_id, kind, data}}` or `{:error, reason}`. `data`
  is relayed opaquely; only its encoded size is bounded.
  """
  @spec parse_signal(:host | :viewer, map()) :: {:ok, map()} | {:error, atom()}
  def parse_signal(direction, %{"session_id" => id, "kind" => kind} = payload)
      when is_binary(id) and is_binary(kind) do
    allowed = if direction == :host, do: @host_signal_kinds, else: @viewer_signal_kinds
    data = Map.get(payload, "data")

    cond do
      kind not in allowed -> {:error, :bad_signal_kind}
      oversized?(data) -> {:error, :signal_too_large}
      true -> {:ok, %{session_id: id, kind: kind, data: data}}
    end
  end

  def parse_signal(_direction, _), do: {:error, :malformed}

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

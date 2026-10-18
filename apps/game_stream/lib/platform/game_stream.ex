defmodule Platform.GameStream do
  @moduledoc """
  Playable review builds (task 01a0db5f): stream a task's review build of a
  game, running on a play host on the operator's LAN, into a `game_stream` canvas.

  This module is the context — the one API the agent tools (`play` bundle),
  the runtime channel and (stage 4) the canvas LiveView hook go through.
  The wire contract with the host is `Platform.GameStream.Protocol`; one live
  session is a `Platform.GameStream.Session`; which commit a session builds
  is `Platform.GameStream.ReviewBuild`.

  ## Off unless `GAME_STREAM_ENABLED` is set

  `enabled?/0` is the ONLY reader of the flag. Every public function here
  that starts, drives or observes a session returns `{:error, :disabled}` (or
  does nothing) while it is off, so with the flag unset the feature has no
  reachable behaviour: the canvas kind is unregistered, the `play` bundle
  lists no tools, and the channel frames are logged and dropped.

  ## Decisions this module encodes

    * One session per host; a second start is `{:error, :host_busy}`.
    * N peers attach to a session (task 01a0dbd6). Opening a canvas attaches
      as a SPECTATOR and never moves or disconnects anyone; joining a player
      slot, leaving it and taking one over are explicit (`join/3`,
      `leave/3`, `take_over/4`). Against a host that does not declare
      `game_stream_multi`, only one peer holds the stream and "Play here" is
      a take-over of slot 0. See `Platform.GameStream.Session`. Only a
      peer's own LiveView, with its current token, signals for that peer.
    * A host disconnect fails the session with "The play host disconnected",
      unless the host rejoins and resumes it within the grace window
      (`:game_stream_host_grace_ms`, task 01a0dbd6 stage 6; see
      `Platform.GameStream.Protocol`, "Resume").
    * A viewer detaching does not end the session; the host idles it out
      after `idle_timeout_s` (default 600 s).
    * The UI's "Start again" and the `play_session_start` tool are the same
      call, `start_session/2`.
  """

  require Logger

  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.GameStreamEncoder
  alias Platform.Experiments.Surfaces.GameStreamRoster
  alias Platform.Experiments.Surfaces.GameStreamTouch
  alias Platform.Federation
  alias Platform.GameStream.Protocol
  alias Platform.GameStream.ReviewBuild
  alias Platform.GameStream.Session
  alias Platform.GameStream.Supervisor, as: GSSupervisor
  alias Platform.Types.UUIDv7

  @host_feature "game_stream_host"
  @encoder_surface "game_stream.encoder_preset"
  @encoder_target "play_session.start"
  @roster_surface "game_stream.roster"
  @touch_surface "game_stream.touch"
  @default_idle_timeout_s 600
  @max_idle_timeout_s 3600

  @type start_error ::
          :disabled
          | :task_not_found
          | :not_in_review
          | :no_repo
          | :no_review_branch
          | {:review_branch_unresolved, term()}
          | :no_play_host
          | :host_busy

  @doc """
  Is the feature on? Reads `config :game_stream, :enabled`, which
  `Platform.GameStream.RuntimeConfig` sets at boot from `GAME_STREAM_ENABLED`
  (`"true"`/`"1"`).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:game_stream, :enabled, false) == true

  @doc "The `client_info.features` entry a play host declares."
  @spec host_feature() :: String.t()
  def host_feature, do: @host_feature

  @doc "The PubSub topic a viewer subscribes to for `session_id`."
  @spec topic(String.t()) :: String.t()
  def topic(session_id), do: "game_stream:" <> session_id

  @doc """
  ICE servers handed to the host (`play_session_start`) and the viewer
  (the `game_stream_attach` reply).

  Built from `config :game_stream, :turn` (`urls`, `username`,
  `credential`), which `Platform.GameStream.RuntimeConfig` fills at boot from
  `GAME_STREAM_TURN_URLS`, `GAME_STREAM_TURN_USERNAME` and the file named by
  `GAME_STREAM_TURN_CREDENTIAL_FILE` (stage 5). With ANY of the three
  missing it is `[]`: no STUN, no TURN, host candidates only — the LAN path.
  There is deliberately no STUN-only fallback: a game stream that cannot
  relay gains nothing from a server-reflexive candidate on this network.

  The result carries the TURN credential. Nothing in this module logs it;
  `Platform.GameStream.Session.format_status/1` redacts it from crash
  reports.
  """
  @spec ice_servers() :: [map()]
  def ice_servers do
    turn = Application.get_env(:game_stream, :turn, [])

    case {Keyword.get(turn, :urls, []), Keyword.get(turn, :username),
          Keyword.get(turn, :credential)} do
      {[_ | _] = urls, username, credential}
      when is_binary(username) and username != "" and is_binary(credential) and
             credential != "" ->
        [%{urls: urls, username: username, credential: credential}]

      _ ->
        []
    end
  end

  @doc """
  The RTCPeerConnection `iceTransportPolicy` for a session: `"relay"` when
  it was started with `force_relay: true` (so a viewer on the LAN measures
  the TURN path), `"all"` otherwise.
  """
  @spec ice_transport_policy(map()) :: String.t()
  def ice_transport_policy(%{force_relay: true}), do: "relay"
  def ice_transport_policy(_status), do: "all"

  @doc "Is a play host connected right now?"
  @spec host_available?() :: boolean()
  def host_available?, do: enabled?() and pick_host() != nil

  @doc """
  Starts a play session for `task_id`'s review build.

  Options:

    * `:started_by` — `{:agent, id}` or `{:user, id}`, recorded on the row;
    * `:idle_timeout_s` — passed to the host (default 600, clamped 60..3600);
    * `:force_relay` — `true` makes the viewer's peer connection
      `iceTransportPolicy: "relay"` (TURN only); default `false`;
    * `:viewer` — a pid attached as a peer and joined as P1 from the start
      (the window that clicked "Start again"); `:viewer_info` names it
      (`%{user_id, name}`) for the roster;
    * `:runner` — the `BranchProvisioner` runner (tests);
    * `:linger_ms` — how long an ended session stays readable (tests);
    * `:host_grace_ms` — how long the session waits for a host whose
      channel dropped (default `config :platform, :game_stream_host_grace_ms`,
      else 20 s; tests).

  Order of checks: flag, review build (task, `in_review`, repo, branch, sha),
  host present, host free. The review build is resolved BEFORE the host is
  looked up so a branchless task is refused as `:no_review_branch` whether
  or not a host is connected — and nothing is ever started for it.
  """
  @spec start_session(String.t(), keyword()) :: {:ok, map()} | {:error, start_error()}
  def start_session(task_id, opts \\ []) do
    with :ok <- ensure_enabled(),
         {:ok, build} <- ReviewBuild.resolve(task_id, Keyword.take(opts, [:runner])),
         {:ok, host} <- find_free_host() do
      {experiment_id, variant_slug, encoder} = resolve_encoder(build.task.id)
      {roster_experiment_id, roster_variant_slug, roster} = resolve_roster(build.task.id)
      {touch_experiment_id, touch_variant_slug, touch_tuning} = resolve_touch(build.task.id)
      session_id = UUIDv7.generate()

      args = %{
        session_id: session_id,
        task_id: build.task.id,
        review_sha: build.sha,
        branch: build.branch,
        repo_url: build.repo_url,
        host_runtime_id: host.runtime_id,
        started_by: Keyword.get(opts, :started_by),
        encoder: encoder,
        experiment_id: experiment_id,
        variant_slug: variant_slug,
        roster_experiment_id: roster_experiment_id,
        roster_variant_slug: roster_variant_slug,
        roster: roster,
        multi: multi_host?(host),
        touch: touch_host?(host),
        touch_tuning: touch_tuning,
        touch_experiment_id: touch_experiment_id,
        touch_variant_slug: touch_variant_slug,
        idle_timeout_s: idle_timeout(Keyword.get(opts, :idle_timeout_s)),
        ice_servers: ice_servers(),
        force_relay: Keyword.get(opts, :force_relay) == true
      }

      args =
        case Keyword.get(opts, :viewer) do
          pid when is_pid(pid) ->
            Map.merge(args, %{viewer: pid, viewer_info: Keyword.get(opts, :viewer_info, %{})})

          _ ->
            args
        end

      args =
        opts
        |> Keyword.take([:linger_ms, :host_grace_ms])
        |> Enum.into(args)

      case DynamicSupervisor.start_child(GSSupervisor.sessions(), {Session, args}) do
        {:ok, _pid} -> status(session_id)
        {:error, :host_busy} -> {:error, :host_busy}
        {:error, reason} -> {:error, {:session_start_failed, reason}}
      end
    end
  end

  @doc "Stops a session: tells the host to stop, and ends it with `reason`."
  @spec stop_session(String.t(), String.t()) :: {:ok, map()} | {:error, :disabled | :not_found}
  def stop_session(session_id, reason \\ "Stopped") do
    with :ok <- ensure_enabled() do
      Session.call(session_id, {:stop, reason})
    end
  end

  @doc "The current status of a session."
  @spec status(String.t()) :: {:ok, map()} | {:error, :disabled | :not_found}
  def status(session_id) do
    with :ok <- ensure_enabled() do
      Session.call(session_id, :status)
    end
  end

  @doc """
  Attaches `pid` (a viewer's LiveView) to the session as a peer.

  `mode` is `:watch` (the default: a spectator; under the roster surface's
  `open_as: "join"` variant it also joins a free slot) or `:follow` (a
  window re-rendered onto a session someone else restarted, which never
  joins). Neither moves anyone. A pid that already has a peer re-attaches it
  with a fresh token, and a multi host is asked to re-offer at once. `info`
  is `%{user_id, name}` for the roster.

  The reply is the session status plus `peer_id`, `viewer` (whether this
  peer receives the stream: always on a multi host, only the holder on a v1
  one), `viewer_token` (sent back with every signal), `role`, `slots`
  (`%{src => slot}`), `roster` and `pending_offer` (this peer's unanswered
  offer, or nil). `{:error, :spectators_full}` when the spectator cap is
  reached.
  """
  @spec attach_viewer(String.t(), pid(), :watch | :follow, map()) ::
          {:ok, map()} | {:error, :disabled | :not_found | :spectators_full}
  def attach_viewer(session_id, pid, mode \\ :watch, info \\ %{})
      when is_pid(pid) and mode in [:watch, :follow] and is_map(info) do
    with :ok <- ensure_enabled() do
      Session.call(session_id, {:attach, pid, mode, info})
    end
  end

  @doc """
  Gives `pid`'s peer the next free player slot for its local controller
  `src` (0 = keyboard and first pad). Idempotent for a src that already
  holds a slot. `{:error, :slots_full}` when none is free,
  `{:error, :not_attached}` when `pid` has no peer.

  `prefer` (task 01a0dbd6 stage 4: an open chip in the roster strip was
  clicked) asks for that slot. It is taken only when it is free; when it is
  not, the next free slot is given instead. A join never displaces anyone,
  so two viewers clicking the same open chip cannot take it from each other.
  """
  @spec join(String.t(), pid(), non_neg_integer(), non_neg_integer() | nil) ::
          {:ok, map()} | {:error, atom()}
  def join(session_id, pid, src \\ 0, prefer \\ nil)
      when is_pid(pid) and is_integer(src) and src >= 0 and
             (is_nil(prefer) or (is_integer(prefer) and prefer >= 0)) do
    with :ok <- ensure_enabled() do
      message = if is_nil(prefer), do: {:join, pid, src}, else: {:join, pid, src, prefer}
      Session.call(session_id, message)
    end
  end

  @doc "Frees `pid`'s slot for `src`, or all of its slots with `:all`. The peer keeps its video."
  @spec leave(String.t(), pid(), non_neg_integer() | :all) :: {:ok, map()} | {:error, atom()}
  def leave(session_id, pid, src \\ :all)
      when is_pid(pid) and (src == :all or (is_integer(src) and src >= 0)) do
    with :ok <- ensure_enabled() do
      Session.call(session_id, {:leave, pid, src})
    end
  end

  @doc """
  Gives `slot` to `pid`'s peer for its controller `src`. Whoever held it is
  sent `{:game_stream, id, {:displaced, slot, by_name}}` and keeps its peer.
  """
  @spec take_over(String.t(), pid(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom()}
  def take_over(session_id, pid, slot, src \\ 0)
      when is_pid(pid) and is_integer(src) and src >= 0 do
    with :ok <- ensure_enabled() do
      Session.call(session_id, {:take_over, pid, slot, src})
    end
  end

  @doc "The session's current roster."
  @spec roster(String.t()) :: {:ok, map()} | {:error, atom()}
  def roster(session_id) do
    with :ok <- ensure_enabled() do
      Session.call(session_id, :roster)
    end
  end

  @doc """
  Relays a viewer's signal (`answer` | `ice`) to the session's host.

  `viewer` is `{pid, viewer_token}` or `{pid, viewer_token, peer_id}` from
  `attach_viewer/4`; without a `peer_id` the pid's own peer is meant. The
  signal reaches the host only when the named peer belongs to `pid` and
  carries that token; anything else is refused `{:error, :moved}` and
  nothing is broadcast.
  """
  @spec relay_to_host(String.t(), String.t(), term(), tuple()) :: :ok | {:error, atom()}
  def relay_to_host(session_id, kind, data, {pid, token}) when is_pid(pid),
    do: relay_to_host(session_id, kind, data, {pid, token, nil})

  def relay_to_host(session_id, kind, data, {pid, _token, peer_id} = viewer)
      when is_pid(pid) and (is_nil(peer_id) or is_binary(peer_id)) do
    with :ok <- ensure_enabled(),
         {:ok, parsed} <-
           Protocol.parse_signal(:viewer, %{
             "session_id" => session_id,
             "kind" => kind,
             "data" => data
           }) do
      Session.call(session_id, {:viewer_signal, viewer, parsed})
    end
  end

  def relay_to_host(_session_id, _kind, _data, _viewer), do: {:error, :moved}

  @doc """
  Relays a host frame to the session's viewer. `payload` is the raw
  `play_signal` map from the channel; `runtime_id` is the SENDING runtime,
  which must be the session's host.
  """
  @spec relay_to_viewer(String.t(), map()) :: :ok | {:error, atom()}
  def relay_to_viewer(runtime_id, payload) when is_binary(runtime_id) and is_map(payload) do
    with :ok <- ensure_enabled(),
         {:ok, parsed} <- Protocol.parse_signal(:host, payload) do
      Session.call(parsed.session_id, {:host_signal, runtime_id, parsed})
    end
  end

  @doc """
  Relays a host's `play_slot_activity` frame to every viewer's roster.
  `runtime_id` is the SENDING runtime, which must be the session's host.
  """
  @spec handle_slot_activity(String.t(), map()) :: :ok | {:error, atom()}
  def handle_slot_activity(runtime_id, payload)
      when is_binary(runtime_id) and is_map(payload) do
    with :ok <- ensure_enabled(),
         {:ok, parsed} <- Protocol.parse_slot_activity(payload) do
      Session.call(parsed.session_id, {:slot_activity, runtime_id, parsed})
    end
  end

  @doc """
  Applies a host's `play_session_status` frame. `runtime_id` is the SENDING
  runtime, which must be the session's host.
  """
  @spec handle_host_status(String.t(), map()) :: :ok | {:error, atom()}
  def handle_host_status(runtime_id, payload) when is_binary(runtime_id) and is_map(payload) do
    with :ok <- ensure_enabled(),
         {:ok, parsed} <- Protocol.parse_status(payload) do
      parsed.session_id
      |> Session.call({:host_status, runtime_id, parsed})
      |> stop_orphaned_resume(runtime_id, parsed)
    end
  end

  # A host resuming a session core no longer runs (it ended, or the grace
  # ran out while the socket was down) is told to stop, so it does not keep
  # streaming to nobody. `:terminal` is only ever answered to the session's
  # own host; `:not_found` names a session no one runs.
  defp stop_orphaned_resume({:error, reason} = result, runtime_id, %{resume: true} = parsed)
       when reason in [:not_found, :terminal] do
    PlatformWeb.Endpoint.broadcast(
      Protocol.host_topic(runtime_id),
      "play_session_stop",
      Protocol.session_stop_payload(parsed.session_id, "The play host disconnected")
    )

    result
  end

  defp stop_orphaned_resume(result, _runtime_id, _parsed), do: result

  @doc """
  Records a viewer's latest stats: `rtt_p50_ms`, `rtt_p95_ms`, `fps_avg`
  (numbers) and `connection_path` (`"lan"` | `"turn"`). Unknown keys and
  ill-typed values are dropped. Written to the row when the session ends.

  Stats are kept per player slot. With `pid` (the reporting LiveView) they
  are filed under that peer's slot: `slot` when the peer holds it, else its
  lowest; a spectator's are dropped. Without a pid they are slot 0's.
  """
  @spec report_stats(String.t(), map(), pid() | nil, term()) :: :ok | {:error, atom()}
  def report_stats(session_id, stats, pid \\ nil, slot \\ nil) when is_map(stats) do
    with :ok <- ensure_enabled() do
      Session.call(session_id, {:report_stats, pid, slot, sanitize_stats(stats)})
    end
  end

  @doc """
  Called from `PlatformWeb.RuntimeChannel.terminate/2` (so `self()` is the
  dropping channel): the session `runtime_id` hosts, if any, starts waiting
  for the host to rejoin and resume it, and fails when its grace runs out
  (see `Platform.GameStream.Session`, "A host that drops"). Never raises — a
  channel's terminate must not crash on a feature that is off or a registry
  that is not running.
  """
  @spec host_disconnected(String.t()) :: :ok
  def host_disconnected(runtime_id) when is_binary(runtime_id) do
    if enabled?() do
      case Session.session_for_host(runtime_id) do
        nil -> :ok
        session_id -> Session.call(session_id, {:host_disconnected, self()})
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("[GameStream] host_disconnected(#{runtime_id}) failed: #{inspect(error)}")
      :ok
  end

  def host_disconnected(_runtime_id), do: :ok

  # ── Internals ───────────────────────────────────────────────────────────

  defp ensure_enabled, do: if(enabled?(), do: :ok, else: {:error, :disabled})

  defp pick_host do
    @host_feature |> Federation.present_runtimes_with_feature() |> List.first()
  end

  defp find_free_host do
    case Federation.present_runtimes_with_feature(@host_feature) do
      [] ->
        {:error, :no_play_host}

      hosts ->
        case Enum.find(hosts, &is_nil(Session.session_for_host(&1.runtime_id))) do
          nil -> {:error, :host_busy}
          host -> {:ok, host}
        end
    end
  end

  # `Surfaces.resolve/4` never raises. `:none` (no experiment, no promoted
  # default) and a default both run the surface's control.
  defp resolve_encoder(task_id) do
    subject = Subject.new("task", task_id)

    case Surfaces.resolve(@encoder_surface, @encoder_target, subject) do
      {:variant, experiment, variant_slug, payload} -> {experiment.id, variant_slug, payload}
      {:default, payload} when map_size(payload) > 0 -> {nil, nil, payload}
      _ -> {nil, nil, GameStreamEncoder.control()}
    end
  end

  # The roster caps. Same never-raising resolution as the encoder; a
  # promoted default or a variant replaces the control whole.
  defp resolve_roster(task_id) do
    subject = Subject.new("task", task_id)

    case Surfaces.resolve(@roster_surface, @encoder_target, subject) do
      {:variant, experiment, variant_slug, payload} -> {experiment.id, variant_slug, payload}
      {:default, payload} when map_size(payload) > 0 -> {nil, nil, payload}
      _ -> {nil, nil, GameStreamRoster.control()}
    end
  end

  # The touch tuning (task 01a0fe45). Same never-raising resolution as the
  # roster; a promoted default or a variant replaces the control whole.
  defp resolve_touch(task_id) do
    subject = Subject.new("task", task_id)

    case Surfaces.resolve(@touch_surface, @encoder_target, subject) do
      {:variant, experiment, variant_slug, payload} -> {experiment.id, variant_slug, payload}
      {:default, payload} when map_size(payload) > 0 -> {nil, nil, payload}
      _ -> {nil, nil, GameStreamTouch.control()}
    end
  end

  defp multi_host?(host) do
    case Federation.declared_features(host.metadata) do
      features when is_list(features) -> Protocol.multi_feature() in features
      :undeclared -> false
    end
  end

  @doc """
  Does `host` (a runtime, or anything with `metadata`) accept touch input?
  True only when its declared `client_info.features` list `game_stream_touch`
  (`Protocol.touch_feature/0`). Undeclared features fail closed. Public so
  the `:undeclared` arm is testable: `start_session/2` never reaches it,
  because host discovery already refuses an undeclared host.
  """
  @spec touch_host?(%{metadata: map() | nil}) :: boolean()
  def touch_host?(%{metadata: metadata}) do
    case Federation.declared_features(metadata) do
      features when is_list(features) -> Protocol.touch_feature() in features
      :undeclared -> false
    end
  end

  defp idle_timeout(n) when is_integer(n), do: n |> max(60) |> min(@max_idle_timeout_s)
  defp idle_timeout(_), do: @default_idle_timeout_s

  defp sanitize_stats(stats) do
    Enum.reduce(stats, %{}, fn {key, value}, acc ->
      case {to_string(key), value} do
        {k, v} when k in ["rtt_p50_ms", "rtt_p95_ms", "fps_avg"] and is_number(v) and v >= 0 ->
          Map.put(acc, String.to_existing_atom(k), v / 1)

        {"connection_path", v} when v in ["lan", "turn"] ->
          Map.put(acc, :connection_path, v)

        _ ->
          acc
      end
    end)
  end
end

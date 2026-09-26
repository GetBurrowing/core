defmodule Platform.GameStream do
  @moduledoc """
  Playable review builds (task 01a0db5f): stream a task's review build of a
  game, running on a play host on Rowan's LAN, into a `game_stream` canvas.

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

    * One session per host in v1; a second start is `{:error, :host_busy}`.
    * The latest window the user ACTED in wins (opened the canvas, "Play
      here", "Start again"); the previous one is told `:moved` (the default
      answer to the design's open question on multiple windows). A window
      that merely re-rendered onto a session someone else restarted does
      not take it (stage 6; `Platform.GameStream.Session`, "Which window
      wins"). Only the current viewer's signals reach the host.
    * A host disconnect fails the session with "The play host disconnected".
    * A viewer detaching does not end the session; the host idles it out
      after `idle_timeout_s` (default 600 s).
    * The UI's "Start again" and the `play_session_start` tool are the same
      call, `start_session/2`.
  """

  require Logger

  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.GameStreamEncoder
  alias Platform.Federation
  alias Platform.GameStream.Protocol
  alias Platform.GameStream.ReviewBuild
  alias Platform.GameStream.Session
  alias Platform.GameStream.Supervisor, as: GSSupervisor
  alias Platform.Types.UUIDv7

  @host_feature "game_stream_host"
  @encoder_surface "game_stream.encoder_preset"
  @encoder_target "play_session.start"
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
  Is the feature on? Reads `config :platform, :game_stream_enabled`, which
  `config/runtime.exs` sets from `GAME_STREAM_ENABLED` (`"true"`/`"1"`).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:platform, :game_stream_enabled, false) == true

  @doc "The `client_info.features` entry a play host declares."
  @spec host_feature() :: String.t()
  def host_feature, do: @host_feature

  @doc "The PubSub topic a viewer subscribes to for `session_id`."
  @spec topic(String.t()) :: String.t()
  def topic(session_id), do: "game_stream:" <> session_id

  @doc """
  ICE servers handed to the host (`play_session_start`) and the viewer
  (the `game_stream_attach` reply).

  Built from `config :platform, :game_stream_turn` (`urls`, `username`,
  `credential`), which `config/runtime.exs` fills at boot from
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
    turn = Application.get_env(:platform, :game_stream_turn, [])

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
    * `:viewer` — a pid that holds the session as its viewer from the start
      (the window that clicked "Start again", stage 6; see
      `Platform.GameStream.Session`, "Which window wins");
    * `:runner` — the `BranchProvisioner` runner (tests);
    * `:linger_ms` — how long an ended session stays readable (tests).

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
        idle_timeout_s: idle_timeout(Keyword.get(opts, :idle_timeout_s)),
        ice_servers: ice_servers(),
        force_relay: Keyword.get(opts, :force_relay) == true
      }

      args =
        case Keyword.get(opts, :viewer) do
          pid when is_pid(pid) -> Map.put(args, :viewer, pid)
          _ -> args
        end

      args =
        case Keyword.fetch(opts, :linger_ms) do
          {:ok, ms} -> Map.put(args, :linger_ms, ms)
          :error -> args
        end

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
  Attaches `pid` (a viewer's LiveView) to the session.

  `mode` is `:take` (the default: a window the user acted in, which becomes
  the viewer and moves the previous one) or `:follow` (a window re-rendered
  onto the session by someone else's restart, which becomes the viewer only
  if nobody holds it). See `Platform.GameStream.Session`, "Which window wins".

  The reply is the session status plus `viewer` (whether `pid` is now the
  viewer), `viewer_token` (to be sent back with every signal) and
  `pending_offer`: the host's latest offer that no viewer has answered yet,
  or nil. A window that did not become the viewer gets neither.
  """
  @spec attach_viewer(String.t(), pid(), :take | :follow) ::
          {:ok, map()} | {:error, :disabled | :not_found}
  def attach_viewer(session_id, pid, mode \\ :take)
      when is_pid(pid) and mode in [:take, :follow] do
    with :ok <- ensure_enabled() do
      Session.call(session_id, {:attach_viewer, pid, mode})
    end
  end

  @doc """
  Relays a viewer's signal (`answer` | `ice`) to the session's host.

  `viewer` is `{pid, viewer_token}` from `attach_viewer/3`. A signal from
  anything but the CURRENT viewer is refused `{:error, :moved}` and never
  reaches the host: two answers to one offer leave the host's peer
  half-connected (task 01a0db5f stage 6).
  """
  @spec relay_to_host(String.t(), String.t(), term(), {pid(), term()}) ::
          :ok | {:error, atom()}
  def relay_to_host(session_id, kind, data, {pid, _token} = viewer) when is_pid(pid) do
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
  Applies a host's `play_session_status` frame. `runtime_id` is the SENDING
  runtime, which must be the session's host.
  """
  @spec handle_host_status(String.t(), map()) :: :ok | {:error, atom()}
  def handle_host_status(runtime_id, payload) when is_binary(runtime_id) and is_map(payload) do
    with :ok <- ensure_enabled(),
         {:ok, parsed} <- Protocol.parse_status(payload) do
      Session.call(parsed.session_id, {:host_status, runtime_id, parsed})
    end
  end

  @doc """
  Records the viewer's latest stats: `rtt_p50_ms`, `rtt_p95_ms`, `fps_avg`
  (numbers) and `connection_path` (`"lan"` | `"turn"`). Unknown keys and
  ill-typed values are dropped. Written to the row when the session ends.
  """
  @spec report_stats(String.t(), map()) :: :ok | {:error, atom()}
  def report_stats(session_id, stats) when is_map(stats) do
    with :ok <- ensure_enabled() do
      Session.call(session_id, {:report_stats, sanitize_stats(stats)})
    end
  end

  @doc """
  Called from `PlatformWeb.RuntimeChannel.terminate/2`: fails the session
  `runtime_id` hosts, if any. Never raises — a channel's terminate must not
  crash on a feature that is off or a registry that is not running.
  """
  @spec host_disconnected(String.t()) :: :ok
  def host_disconnected(runtime_id) when is_binary(runtime_id) do
    if enabled?() do
      case Session.session_for_host(runtime_id) do
        nil -> :ok
        session_id -> Session.call(session_id, :host_disconnected)
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

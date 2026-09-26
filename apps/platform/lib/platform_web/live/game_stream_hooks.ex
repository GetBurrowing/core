defmodule PlatformWeb.GameStreamHooks do
  @moduledoc """
  The LiveView half of the `game_stream` canvas (task 01a0db5f stage 4):
  the events the `GameStream` JS hook pushes, and the session messages it is
  sent back.

  `attach/1` puts two lifecycle hooks on a socket, mirroring
  `PlatformWeb.ChatLive.CanvasHooks.attach/1`. It is called from
  `PlatformWeb.ChatLive` next to `CanvasHooks.attach/1` and from
  `PlatformWeb.CanvasLive.mount/3`.

  ## Inert while `GAME_STREAM_ENABLED` is unset

  The hooks are attached whatever the flag says, because the flag is read at
  run time and a client rendered before it flipped can still push. While it
  is unset every `game_stream_*` event is answered `%{ok: false, error:
  "disabled"}` and does nothing else: no subscription, no session call, no
  push. Other events and messages pass through untouched (`{:cont, socket}`).

  ## Every event is refused unless its session is on a canvas this viewer can read

  The grant is the one `PlatformWeb.CanvasLive` already uses,
  `Platform.Chat.CanvasAccess.fetch_for_viewer/3` (with `audit: false`: this
  is a socket, not an arrival). On top of it, the canvas's document must hold
  a `game_stream` node, at `node_id`, whose `session_id` prop is the session
  named in the event. A session the viewer merely knows the id of is refused.

  `game_stream_attach` and `game_stream_restart` check this against the
  database. A session that passes is remembered in the socket's
  `:game_stream_grants` assign, and the chattier events (`signal`, `stats`,
  `end`) are checked against that assign, so an ICE candidate does not cost
  a canvas read. A session id that never passed `attach` is not in the
  assign and is refused.

  ## Which window plays (stage 6)

  `game_stream_attach` carries `mode`: `"follow"` from a window whose node
  was re-rendered onto a session someone ELSE restarted, anything else
  (`"take"`) from a window the user acted in. The reply says whether this
  window is now the viewer (`viewer`) and, if so, its `viewer_token`, which
  every `game_stream_signal` must carry back: a signal from a window that is
  not the current viewer is refused `"moved"` and never reaches the host.
  "Start again" starts the session with this LiveView as its viewer, so the
  clicking window wins. See `Platform.GameStream.Session`.

  ## Restart writes the canvas

  "Start again" starts a NEW session (a new id) through
  `Platform.GameStream.start_session/2`, then `set_props` the node's
  `session_id` and `review_sha` through `Platform.Chat.patch_canvas/3`. That
  write needs space membership (`CanvasAccess.fetch_for_writer/2`), so a
  task- or org-reader cannot restart; the writer check runs BEFORE the
  session is started, so a refused restart never holds the play host.

  ## Messages to the client

  Pushed as the `"game_stream"` event with `%{session_id, type, ...}`; the
  hook drops any whose `session_id` is not its own, since one LiveView can
  hold several `game_stream` nodes:

    * `type: "status"` — the session's public status (never the SDP);
    * `type: "signal"` — `kind` and `data` from the host (`offer`, `ice`);
    * `type: "moved"` — another window took the session over. The socket
      unsubscribes from the session's topic at that moment, so a moved
      window receives no later offer and cannot answer one meant for the
      window that took over; "Play here" (`game_stream_attach`) subscribes
      again.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3]

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasAccess
  alias Platform.GameStream

  @events ~w(game_stream_attach game_stream_signal game_stream_stats game_stream_end
             game_stream_restart)

  @status_keys ~w(session_id task_id state detail elapsed_ms review_sha branch ended_reason)a

  @doc "Attach the game_stream event and info hooks to `socket`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:game_stream_grants, %{})
    |> assign(:game_stream_subscribed, MapSet.new())
    |> attach_hook(:game_stream_events, :handle_event, &handle_event/3)
    |> attach_hook(:game_stream_info, :handle_info, &handle_info/2)
  end

  @doc false
  def events, do: @events

  # ── Events ──────────────────────────────────────────────────────────────

  @doc false
  def handle_event(event, params, socket) when event in @events do
    if GameStream.enabled?() do
      {reply, socket} = dispatch(event, params, socket)
      {:halt, reply, socket}
    else
      {:halt, refusal("disabled"), socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  defp dispatch("game_stream_attach", params, socket) do
    with {:ok, session_id, grant} <- authorize(socket, params) do
      socket = grant(socket, session_id, grant)

      case GameStream.attach_viewer(session_id, self(), attach_mode(params)) do
        {:ok, status} ->
          {%{
             ok: true,
             status: public(status),
             ice_servers: GameStream.ice_servers(),
             ice_transport_policy: GameStream.ice_transport_policy(status),
             pending_offer: Map.get(status, :pending_offer),
             viewer: Map.get(status, :viewer, true),
             viewer_token: Map.get(status, :viewer_token)
           }, socket}

        {:error, :not_found} ->
          {%{
             ok: true,
             status: gone_status(session_id),
             ice_servers: [],
             ice_transport_policy: "all",
             pending_offer: nil
           }, socket}

        {:error, reason} ->
          {refusal(reason), socket}
      end
    else
      {:error, reason} -> {refusal(reason), socket}
    end
  end

  defp dispatch("game_stream_signal", %{"kind" => kind} = params, socket) do
    with {:ok, session_id} <- granted(socket, params),
         :ok <-
           GameStream.relay_to_host(
             session_id,
             kind,
             Map.get(params, "data"),
             {self(), Map.get(params, "viewer_token")}
           ) do
      {%{ok: true}, socket}
    else
      {:error, reason} -> {refusal(reason), socket}
    end
  end

  defp dispatch("game_stream_stats", params, socket) do
    with {:ok, session_id} <- granted(socket, params),
         stats when is_map(stats) <- Map.get(params, "stats", %{}),
         :ok <- GameStream.report_stats(session_id, stats) do
      {%{ok: true}, socket}
    else
      {:error, reason} -> {refusal(reason), socket}
      _ -> {refusal("bad_stats"), socket}
    end
  end

  defp dispatch("game_stream_end", params, socket) do
    with {:ok, session_id} <- granted(socket, params),
         {:ok, status} <- GameStream.stop_session(session_id, ended_by(socket)) do
      {%{ok: true, status: public(status)}, socket}
    else
      {:error, reason} -> {refusal(reason), socket}
    end
  end

  defp dispatch("game_stream_restart", params, socket) do
    with {:ok, _old_session_id, grant} <- authorize(socket, params),
         {:ok, canvas} <- CanvasAccess.fetch_for_writer(grant.canvas_id, viewer(socket)),
         {:ok, task_id} <- node_task_id(grant),
         {:ok, status} <-
           GameStream.start_session(task_id, started_by: viewer(socket), viewer: self()),
         :ok <- patch_node(socket, canvas, grant.node_id, status) do
      socket = grant(socket, status.session_id, grant)
      {%{ok: true, session_id: status.session_id, status: public(status)}, socket}
    else
      {:error, reason} -> {refusal(reason), socket}
    end
  end

  defp dispatch(_event, _params, socket), do: {refusal("malformed"), socket}

  # ── Messages ────────────────────────────────────────────────────────────

  @doc false
  def handle_info({:game_stream, session_id, :moved}, socket) do
    # Another window took the session. Stop listening, so this window can
    # never answer an offer meant for the new one (two answers to one offer
    # leave the host's peer half-connected). "Play here" re-attaches, which
    # subscribes again.
    if subscribed?(socket, session_id) do
      Phoenix.PubSub.unsubscribe(Platform.PubSub, GameStream.topic(session_id))

      {:halt,
       socket
       |> assign(:game_stream_subscribed, MapSet.delete(subscribed(socket), session_id))
       |> push_event("game_stream", client_message(session_id, :moved))}
    else
      {:halt, socket}
    end
  end

  def handle_info({:game_stream, session_id, message}, socket) do
    if Map.has_key?(grants(socket), session_id) and subscribed?(socket, session_id) do
      {:halt, push_event(socket, "game_stream", client_message(session_id, message))}
    else
      {:halt, socket}
    end
  end

  def handle_info(_message, socket), do: {:cont, socket}

  defp client_message(id, {:status, status}),
    do: %{session_id: id, type: "status", status: public(status)}

  defp client_message(id, {:signal, kind, data}),
    do: %{session_id: id, type: "signal", kind: kind, data: data}

  defp client_message(id, :moved), do: %{session_id: id, type: "moved"}
  defp client_message(id, _other), do: %{session_id: id, type: "unknown"}

  # ── Authorization ───────────────────────────────────────────────────────

  # The full check: the viewer can read `canvas_id`, and that canvas holds a
  # game_stream node at `node_id` whose session_id is the event's.
  defp authorize(socket, %{
         "session_id" => session_id,
         "canvas_id" => canvas_id,
         "node_id" => node_id
       })
       when is_binary(session_id) and is_binary(canvas_id) and is_binary(node_id) do
    with {:ok, canvas, _level} <-
           CanvasAccess.fetch_for_viewer(canvas_id, viewer(socket), audit: false),
         true <- is_nil(canvas.deleted_at),
         {:ok, props} <- session_node(canvas, node_id, session_id) do
      {:ok, session_id, %{canvas_id: canvas.id, node_id: node_id, props: props}}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize(_socket, _params), do: {:error, :forbidden}

  # The node at `node_id` must name `session_id`. The row's document is read
  # first; when it does not match, the live `Canvas.Server` document is: a
  # "Start again" patch is persisted ASYNCHRONOUSLY, and every window it
  # re-renders attaches to the new session at once, so for a moment the row
  # still names the old one. Refusing then flashed the Failed panel ("You
  # cannot play this session from here") in the window that had just
  # clicked Start again (stage 6). The grant itself (who may read the
  # canvas) always comes from `fetch_for_viewer/3` above.
  defp session_node(canvas, node_id, session_id) do
    case node_props(canvas.document, node_id, session_id) do
      {:ok, props} ->
        {:ok, props}

      :error ->
        case CanvasServer.describe(canvas.id) do
          {:ok, %{document: document}} -> node_props(document, node_id, session_id)
          _ -> :error
        end
    end
  end

  defp node_props(document, node_id, session_id) do
    case find_node(document, node_id) do
      %{"type" => "game_stream", "props" => %{"session_id" => ^session_id} = props} ->
        {:ok, props}

      _ ->
        :error
    end
  end

  # "follow" is sent by a window whose node was re-rendered onto a session
  # someone else restarted; anything else is a window the user acted in.
  defp attach_mode(%{"mode" => "follow"}), do: :follow
  defp attach_mode(_params), do: :take

  # The cheap check: the session passed `authorize/2` on this socket.
  defp granted(socket, %{"session_id" => session_id}) when is_binary(session_id) do
    if Map.has_key?(socket.assigns[:game_stream_grants] || %{}, session_id),
      do: {:ok, session_id},
      else: {:error, :forbidden}
  end

  defp granted(_socket, _params), do: {:error, :forbidden}

  # Records the grant and subscribes to the session's topic, once per
  # session per socket (a re-attach after `:moved` subscribes again).
  defp grant(socket, session_id, grant) do
    socket =
      if subscribed?(socket, session_id) do
        socket
      else
        :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(session_id))
        assign(socket, :game_stream_subscribed, MapSet.put(subscribed(socket), session_id))
      end

    assign(socket, :game_stream_grants, Map.put(grants(socket), session_id, grant))
  end

  defp grants(socket), do: socket.assigns[:game_stream_grants] || %{}
  defp subscribed(socket), do: socket.assigns[:game_stream_subscribed] || MapSet.new()
  defp subscribed?(socket, session_id), do: MapSet.member?(subscribed(socket), session_id)

  defp viewer(socket) do
    case socket.assigns do
      %{current_user_id: id} when is_binary(id) -> {:user, id}
      %{user_id: id} when is_binary(id) -> {:user, id}
      _ -> nil
    end
  end

  defp find_node(%{"root" => root}, node_id), do: find_in(root, node_id)
  defp find_node(_document, _node_id), do: nil

  defp find_in(%{"id" => id} = node, id), do: node

  defp find_in(%{"children" => children}, id) when is_list(children),
    do: Enum.find_value(children, &find_in(&1, id))

  defp find_in(_node, _id), do: nil

  defp node_task_id(%{props: %{"task_id" => task_id}}) when is_binary(task_id),
    do: {:ok, task_id}

  defp node_task_id(_grant), do: {:error, :task_not_found}

  defp patch_node(socket, canvas, node_id, status) do
    props = %{"session_id" => status.session_id, "review_sha" => status.review_sha}

    props =
      if is_binary(status[:branch]), do: Map.put(props, "branch", status.branch), else: props

    case Chat.patch_canvas(viewer(socket), canvas, [{:set_props, node_id, props}]) do
      {:ok, _canvas} ->
        :ok

      other ->
        # The node still names the old session, so nobody could reach the new
        # one: stop it rather than hold the play host for its idle timeout.
        _ = GameStream.stop_session(status.session_id, "Could not update the canvas")
        {:error, {:canvas_patch_failed, other}}
    end
  end

  defp ended_by(socket) do
    name =
      case viewer(socket) do
        {:user, id} ->
          case Accounts.get_user(id) do
            %{name: name} when is_binary(name) and name != "" -> name
            _ -> nil
          end

        _ ->
          nil
      end

    if name, do: "Ended by " <> name, else: "Ended by a viewer"
  end

  # ── Replies ─────────────────────────────────────────────────────────────

  defp public(status), do: Map.take(status, @status_keys)

  defp gone_status(session_id) do
    if GameStream.host_available?(),
      do: %{session_id: session_id, state: "ended", detail: "This session has ended"},
      else: %{session_id: session_id, state: "unavailable", detail: nil}
  end

  defp refusal(reason), do: %{ok: false, error: reason_text(reason)}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(_reason), do: "error"
end

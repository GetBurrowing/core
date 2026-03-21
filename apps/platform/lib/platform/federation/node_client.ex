defmodule Platform.Federation.NodeClient do
  @moduledoc """
  GenServer that connects to OpenClaw Gateway as a node via WebSocket using :gun.
  Handles the device identity handshake, reconnection with exponential backoff,
  and dispatches incoming node.invoke.request commands to NodeCommandHandler.
  """

  use GenServer
  require Logger

  alias Platform.Federation.NodeIdentity
  alias Platform.Federation.NodeCommandHandler

  @base_backoff_ms 5_000
  @max_backoff_ms 60_000

  # ── Public API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def connected? do
    GenServer.call(__MODULE__, :connected?)
  catch
    :exit, _ -> false
  end

  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> %{state: :not_running}
  end

  # ── GenServer callbacks ──

  @impl true
  def init(_opts) do
    identity = NodeIdentity.load_or_create()

    state = %{
      identity: identity,
      conn: nil,
      stream_ref: nil,
      state: :disconnected,
      backoff: @base_backoff_ms,
      msg_id: 0,
      gateway_url: gateway_url(),
      token: System.get_env("OPENCLAW_GATEWAY_TOKEN", ""),
      display_name: System.get_env("OPENCLAW_NODE_DISPLAY_NAME", "Startup Suite")
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.state == :connected, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       state: state.state,
       device_id: NodeIdentity.device_id(state.identity),
       gateway_url: state.gateway_url
     }, state}
  end

  @impl true
  def handle_info(:connect, state) do
    uri = URI.parse(state.gateway_url)
    host = String.to_charlist(uri.host || "127.0.0.1")
    port = uri.port || 18789

    transport = if uri.scheme in ["wss", "https"], do: :tls, else: :tcp
    gun_opts = %{protocols: [:http], transport: transport}

    case :gun.open(host, port, gun_opts) do
      {:ok, conn} ->
        _monitor = Process.monitor(conn)
        {:noreply, %{state | conn: conn, state: :connecting}}

      {:error, reason} ->
        Logger.error("[NodeClient] gun.open failed: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info({:gun_up, conn, :http}, %{conn: conn} = state) do
    path = ~c"/"
    stream_ref = :gun.ws_upgrade(conn, path, [])
    {:noreply, %{state | stream_ref: stream_ref}}
  end

  def handle_info(
        {:gun_upgrade, conn, ref, [<<"websocket">>], _headers},
        %{conn: conn, stream_ref: ref} = state
      ) do
    Logger.info("[NodeClient] WebSocket connected, waiting for challenge")
    {:noreply, %{state | state: :handshaking}}
  end

  def handle_info({:gun_ws, conn, _ref, {:text, json}}, %{conn: conn} = state) do
    case Jason.decode(json) do
      {:ok, frame} ->
        handle_frame(frame, state)

      {:error, reason} ->
        Logger.warning("[NodeClient] invalid JSON frame: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:gun_ws, conn, _ref, {:close, _code, _reason}}, %{conn: conn} = state) do
    Logger.warning("[NodeClient] WebSocket closed by server")
    {:noreply, schedule_reconnect(%{state | state: :disconnected, conn: nil, stream_ref: nil})}
  end

  def handle_info({:gun_down, conn, _proto, reason, _}, %{conn: conn} = state) do
    Logger.warning("[NodeClient] connection down: #{inspect(reason)}")
    {:noreply, schedule_reconnect(%{state | state: :disconnected, conn: nil, stream_ref: nil})}
  end

  def handle_info({:gun_error, conn, _ref, reason}, %{conn: conn} = state) do
    Logger.error("[NodeClient] gun error: #{inspect(reason)}")
    {:noreply, schedule_reconnect(%{state | state: :disconnected, conn: nil, stream_ref: nil})}
  end

  def handle_info({:gun_error, conn, reason}, %{conn: conn} = state) do
    Logger.error("[NodeClient] gun error: #{inspect(reason)}")
    {:noreply, schedule_reconnect(%{state | state: :disconnected, conn: nil, stream_ref: nil})}
  end

  def handle_info({:DOWN, _ref, :process, conn, reason}, %{conn: conn} = state) do
    Logger.warning("[NodeClient] gun process down: #{inspect(reason)}")
    {:noreply, schedule_reconnect(%{state | state: :disconnected, conn: nil, stream_ref: nil})}
  end

  def handle_info({:gun_response, _conn, _ref, _fin, status, _headers}, state) do
    Logger.error("[NodeClient] ws upgrade rejected with HTTP #{status}")
    {:noreply, schedule_reconnect(%{state | state: :disconnected, conn: nil, stream_ref: nil})}
  end

  def handle_info(msg, state) do
    Logger.debug("[NodeClient] unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Frame handling ──

  defp handle_frame(
         %{
           "type" => "event",
           "event" => "connect.challenge",
           "payload" => %{"nonce" => nonce_b64}
         },
         state
       ) do
    nonce = Base.decode64!(nonce_b64)
    signature = NodeIdentity.sign_challenge(nonce, state.identity)
    device_id = NodeIdentity.device_id(state.identity)

    {msg_id, state} = next_msg_id(state)

    connect_frame = %{
      type: "req",
      id: "msg-#{msg_id}",
      method: "connect",
      params: %{
        role: "node",
        token: state.token,
        device: %{
          id: device_id,
          displayName: state.display_name,
          platform: "suite",
          publicKey: Base.encode64(state.identity.public_key),
          signature: Base.encode64(signature)
        },
        capabilities: [
          "canvas.present",
          "canvas.navigate",
          "canvas.eval",
          "canvas.snapshot",
          "canvas.a2ui_push",
          "canvas.a2ui_reset"
        ]
      }
    }

    send_frame(state, connect_frame)
    {:noreply, state}
  end

  defp handle_frame(%{"type" => "res", "ok" => true, "payload" => %{"type" => "hello-ok"}}, state) do
    Logger.info("[NodeClient] connected and authenticated as node")
    {:noreply, %{state | state: :connected, backoff: @base_backoff_ms}}
  end

  defp handle_frame(%{"type" => "res", "ok" => false} = frame, state) do
    Logger.error("[NodeClient] connect rejected: #{inspect(frame)}")
    {:noreply, schedule_reconnect(%{state | state: :disconnected, conn: nil, stream_ref: nil})}
  end

  defp handle_frame(
         %{
           "type" => "event",
           "event" => "node.invoke.request",
           "payload" => %{"id" => invoke_id, "nodeId" => node_id, "command" => command} = payload
         },
         state
       ) do
    params_json = Map.get(payload, "paramsJSON", "{}")

    params =
      case Jason.decode(params_json) do
        {:ok, p} -> p
        {:error, _} -> %{}
      end

    {msg_id, state} = next_msg_id(state)

    result_frame =
      case NodeCommandHandler.handle(command, params) do
        {:ok, result} ->
          %{
            type: "req",
            id: "msg-#{msg_id}",
            method: "node.invoke.result",
            params: %{
              id: invoke_id,
              nodeId: node_id,
              ok: true,
              payloadJSON: Jason.encode!(result)
            }
          }

        {:error, code, message} ->
          %{
            type: "req",
            id: "msg-#{msg_id}",
            method: "node.invoke.result",
            params: %{
              id: invoke_id,
              nodeId: node_id,
              ok: false,
              error: %{code: code, message: message}
            }
          }
      end

    send_frame(state, result_frame)
    {:noreply, state}
  end

  defp handle_frame(frame, state) do
    Logger.debug("[NodeClient] unhandled frame: #{inspect(frame)}")
    {:noreply, state}
  end

  # ── Helpers ──

  defp send_frame(%{conn: conn, stream_ref: ref}, frame) do
    json = Jason.encode!(frame)
    :gun.ws_send(conn, ref, {:text, json})
  end

  defp next_msg_id(state) do
    id = state.msg_id + 1
    {id, %{state | msg_id: id}}
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.backoff)
    next_backoff = min(state.backoff * 2, @max_backoff_ms)
    Logger.info("[NodeClient] reconnecting in #{state.backoff}ms")
    %{state | backoff: next_backoff}
  end

  defp gateway_url do
    System.get_env("OPENCLAW_GATEWAY_URL", "ws://127.0.0.1:18789")
  end
end

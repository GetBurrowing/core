defmodule PlatformWeb.TerminalCliChannel do
  @moduledoc """
  The agent machine's end of the remote terminal, on `terminal:<runtime_id>`
  of the runtime socket (task 01a17b17, protocol v1).

  Joining is the opt-in signal: the CLI joins only when its owner started it
  with the terminal on. The join registers "terminal CLI present" for the
  runtime in a process registry, nothing more. It never touches runtime
  presence or the `runtime:` topic.

  Frames pass through untouched. Channel logging is off so Phoenix cannot
  print them, and no clause here reads, decodes or measures a frame beyond
  its size bound.
  """
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias Platform.Terminal

  @max_frame_bytes 1_048_576

  @impl true
  def join("terminal:" <> runtime_id, _params, socket) do
    if runtime_id == socket.assigns.runtime_id do
      :ok = Terminal.register_cli(runtime_id)
      {:ok, assign(socket, :session_id, nil)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_in("hello", %{"pub" => pub}, %{assigns: %{session_id: sid}} = socket)
      when is_binary(sid) and is_binary(pub) do
    Terminal.relay(sid, {:to_view, "hello", %{"pub" => pub}})
    {:noreply, socket}
  end

  def handle_in("out", {:binary, bin}, %{assigns: %{session_id: sid}} = socket)
      when is_binary(sid) and byte_size(bin) <= @max_frame_bytes do
    Terminal.relay(sid, {:to_view, "out", bin})
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:terminal_open, sid}, socket) when is_binary(sid) do
    # A new open replaces the old session; its viewer is told it ended.
    case socket.assigns.session_id do
      old when is_binary(old) -> Terminal.relay(old, {:to_view, :cli_gone, nil})
      _ -> :ok
    end

    socket = end_session(socket)
    :ok = Terminal.subscribe(sid)
    push(socket, "open", %{"session_id" => sid})
    {:noreply, assign(socket, :session_id, sid)}
  end

  def handle_info({:to_cli, "detach", _}, socket) do
    push(socket, "detach", %{})
    {:noreply, end_session(socket)}
  end

  def handle_info({:to_cli, event, payload}, socket)
      when event in ["hello", "mode", "resize"] and is_map(payload) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info({:to_cli, "in", bin}, socket) when is_binary(bin) do
    push(socket, "in", {:binary, bin})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:session_id] do
      sid when is_binary(sid) -> Terminal.relay(sid, {:to_view, :cli_gone, nil})
      _ -> :ok
    end

    :ok
  end

  defp end_session(%{assigns: %{session_id: sid}} = socket) when is_binary(sid) do
    Phoenix.PubSub.unsubscribe(Platform.PubSub, Terminal.session_topic(sid))
    assign(socket, :session_id, nil)
  end

  defp end_session(socket), do: socket
end

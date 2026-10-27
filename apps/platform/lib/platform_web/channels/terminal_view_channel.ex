defmodule PlatformWeb.TerminalViewChannel do
  @moduledoc """
  The owner's browser end of the remote terminal, on
  `terminal_view:<runtime_id>` of `PlatformWeb.TerminalSocket`.

  Join order (each refusal writes ONE `terminal.session.refused` audit row
  and never an `opened` row):

    1. the socket carries a user (a valid short-lived token);
    2. the user is allowed the terminal for this runtime. That is
       `Platform.Federation.RemoteAccess`: the relationship kind must be an
       allowed kind, and today that means the runtime's owner. Otherwise
       `forbidden`;
    3. the runtime is online but no terminal CLI is joined (the opt-in is off):
       `flag_off`; the runtime is not online: `offline`.

  After a join the session starts read-only. While read-only, `in` frames are
  dropped by event name alone; a frame is never examined. A `mode` request is
  audited, then forwarded to the CLI.

  Core never decrypts. Frames are sealed between the CLI and the browser, and
  this module only moves them. Channel logging is off and every clause is
  total, so no log line or crash report carries a frame.
  """
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias Platform.Accounts
  alias Platform.Federation
  alias Platform.Federation.RemoteAccess
  alias Platform.Federation.RuntimePresence
  alias Platform.Terminal
  alias Platform.Terminal.Audit

  @max_frame_bytes 1_048_576

  @impl true
  def join("terminal_view:" <> runtime_id, _params, socket) do
    user_id = socket.assigns[:user_id]

    with {:user, %{id: ^user_id}} <- {:user, user_id && Accounts.get_user(user_id)},
         runtime = Federation.get_runtime_by_runtime_id(runtime_id),
         kind = RemoteAccess.kind_for(runtime, user_id),
         {:allowed, true} <- {:allowed, RemoteAccess.allowed_kind?(kind)},
         {:online, true} <- {:online, RuntimePresence.online?(runtime_id)},
         cli_pid = Terminal.cli_pid(runtime_id),
         {:opt_in, true} <- {:opt_in, RemoteAccess.permitted?(kind, cli_pid != nil)},
         {:audit, :ok} <- {:audit, Audit.record("opened", user_id, runtime_id, %{mode: "ro"})} do
      {:ok, %{mode: "ro"}, start_session(socket, runtime_id, cli_pid)}
    else
      {:user, _} -> {:error, %{reason: "unauthorized"}}
      {:allowed, _} -> refuse(user_id, runtime_id, "forbidden")
      {:online, _} -> refuse(user_id, runtime_id, "offline")
      {:opt_in, _} -> refuse(user_id, runtime_id, "flag_off")
      {:audit, _} -> {:error, %{reason: "unavailable"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  defp refuse(user_id, runtime_id, reason) do
    Audit.record("refused", user_id, runtime_id, %{reason: reason})
    {:error, %{reason: reason}}
  end

  defp start_session(socket, runtime_id, cli_pid) do
    sid = Terminal.new_session_id()
    :ok = Terminal.subscribe(sid)
    send(cli_pid, {:terminal_open, sid})

    socket
    |> assign(:runtime_id, runtime_id)
    |> assign(:session_id, sid)
    |> assign(:mode, "ro")
    |> assign(:opened_at, DateTime.utc_now())
    |> assign(:closed?, false)
  end

  @impl true
  def handle_in("hello", %{"pub" => pub}, socket) when is_binary(pub) do
    Terminal.relay(socket.assigns.session_id, {:to_cli, "hello", %{"pub" => pub}})
    {:noreply, socket}
  end

  # Read-only drops by event name alone: the frame is never looked at.
  def handle_in("in", {:binary, _bin}, %{assigns: %{mode: "ro"}} = socket) do
    {:noreply, socket}
  end

  def handle_in("in", {:binary, bin}, %{assigns: %{mode: "rw"}} = socket)
      when byte_size(bin) <= @max_frame_bytes do
    Terminal.relay(socket.assigns.session_id, {:to_cli, "in", bin})
    {:noreply, socket}
  end

  def handle_in("mode", %{"mode" => mode}, socket) when mode in ["ro", "rw"] do
    if mode == socket.assigns.mode do
      {:reply, {:ok, %{mode: mode}}, socket}
    else
      :ok =
        Audit.record("mode_changed", socket.assigns.user_id, socket.assigns.runtime_id, %{
          mode: mode
        })

      Terminal.relay(socket.assigns.session_id, {:to_cli, "mode", %{"mode" => mode}})
      {:reply, {:ok, %{mode: mode}}, assign(socket, :mode, mode)}
    end
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket)
      when is_integer(cols) and is_integer(rows) do
    Terminal.relay(
      socket.assigns.session_id,
      {:to_cli, "resize", %{"cols" => cols, "rows" => rows}}
    )

    {:noreply, socket}
  end

  def handle_in("detach", _payload, socket) do
    {:stop, :normal, close(socket)}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:to_view, "hello", %{"pub" => _} = payload}, socket) do
    push(socket, "hello", payload)
    {:noreply, socket}
  end

  def handle_info({:to_view, "out", bin}, socket) when is_binary(bin) do
    push(socket, "out", {:binary, bin})
    {:noreply, socket}
  end

  def handle_info({:to_view, :cli_gone, _}, socket) do
    socket = close(socket)
    push(socket, "closed", %{"reason" => "cli_gone"})
    {:stop, :normal, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:session_id] do
      sid when is_binary(sid) ->
        _ = close(socket)
        Terminal.relay(sid, {:to_cli, "detach", %{}})
        :ok

      _ ->
        :ok
    end
  end

  # Writes the single `closed` row. Idempotent through the `closed?` assign.
  defp close(%{assigns: %{closed?: false}} = socket) do
    closed_at = DateTime.utc_now()

    Audit.record("closed", socket.assigns.user_id, socket.assigns.runtime_id, %{
      mode: socket.assigns.mode,
      opened_at: DateTime.to_iso8601(socket.assigns.opened_at),
      closed_at: DateTime.to_iso8601(closed_at)
    })

    assign(socket, :closed?, true)
  end

  defp close(socket), do: socket
end

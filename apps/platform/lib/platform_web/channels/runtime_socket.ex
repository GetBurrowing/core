defmodule PlatformWeb.RuntimeSocket do
  @moduledoc """
  Phoenix Socket for external agent runtimes.

  Authenticates via runtime_id + token, then allows the runtime
  to join its channel for bidirectional communication.
  """
  use Phoenix.Socket

  alias Platform.Federation
  alias Platform.Agents.AgentRuntime

  channel "runtime:*", PlatformWeb.RuntimeChannel

  @impl true
  def connect(%{"runtime_id" => runtime_id, "token" => token}, socket, _connect_info) do
    with %AgentRuntime{status: "active"} = runtime <-
           Federation.get_runtime_by_runtime_id(runtime_id),
         true <- AgentRuntime.verify_token(token, runtime.auth_token_hash) do
      socket =
        socket
        |> assign(:runtime_id, runtime.runtime_id)
        |> assign(:runtime_pk, runtime.id)
        |> assign(:agent_id, runtime.agent_id)

      {:ok, socket}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "runtime:#{socket.assigns.runtime_id}"
end

defmodule PlatformWeb.AgentHostSocket do
  @moduledoc """
  The socket the install's agent host dials OUT to core on (task 01a10322
  stage 2), at `/agent-host/websocket`.

  The host authenticates with the install's `AGENT_HOST_TOKEN`, sent in the
  `x-agent-host-token` header (a header, not a query parameter, so it does not
  land in a proxy's access log). It is compared with
  `Plug.Crypto.secure_compare/2`. With no `AGENT_HOST_TOKEN` configured,
  EVERY connection is refused: there is no default token.

  See `Platform.AgentHost` for the protocol.
  """
  use Phoenix.Socket

  channel "agent_host:control", PlatformWeb.AgentHostChannel

  @header "x-agent-host-token"

  @doc false
  def header, do: @header

  @impl true
  def connect(_params, socket, connect_info) do
    with expected when is_binary(expected) <- Platform.AgentHost.token(),
         presented when is_binary(presented) <- presented_token(connect_info),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      {:ok, socket}
    else
      _ -> :error
    end
  end

  @impl true
  def id(_socket), do: "agent_host"

  defp presented_token(%{x_headers: headers}) when is_list(headers) do
    case List.keyfind(headers, @header, 0) do
      {_, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp presented_token(_), do: nil
end

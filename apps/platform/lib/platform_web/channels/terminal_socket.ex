defmodule PlatformWeb.TerminalSocket do
  @moduledoc """
  The owner's browser socket for the remote terminal, at `/terminal/ws`
  (task 01a17b17).

  Authenticated by a short-lived `Phoenix.Token` minted for the signed-in
  user (`mint_token/1`, called by the LiveView). The token is single-purpose,
  salted for this socket and valid for `max_age/0` seconds, so it is useless
  after the page that minted it has been open for a minute.
  """
  use Phoenix.Socket

  channel "terminal_view:*", PlatformWeb.TerminalViewChannel

  @salt "terminal socket v1"
  @max_age 60

  def max_age, do: @max_age

  @doc "Mint a token for `user_id`."
  def mint_token(user_id) when is_binary(user_id),
    do: Phoenix.Token.sign(PlatformWeb.Endpoint, @salt, user_id)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Phoenix.Token.verify(PlatformWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, user_id} when is_binary(user_id) -> {:ok, assign(socket, :user_id, user_id)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "terminal_user:" <> socket.assigns.user_id
end

defmodule PlatformWeb.Plugs.VerifyInstallIntakeToken do
  @moduledoc """
  Authenticate the getburrow.ing request function on
  `POST /api/install-requests` (task 01a18f0c stage 2).

  The caller sends `Authorization: Bearer <token>`; the token is
  `config :platform, Platform.Installs, intake_token:`
  (`BURROW_INSTALL_INTAKE_TOKEN`). Both sides are sha256-hashed before
  `Plug.Crypto.secure_compare/2`, so the comparison is constant-time and
  length-independent (the shape of `PlatformWeb.AgentHostSocket.connect/3`).

    * No token configured: 404, so the route looks absent (fail closed).
    * A missing or wrong token: 401 with an empty JSON body.

  Either way the plug halts before the controller, and nothing about the
  presented token is logged.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case configured_token() do
      nil ->
        refuse(conn, 404)

      expected ->
        with ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
             true <- presented != "",
             true <- Plug.Crypto.secure_compare(hash(presented), hash(expected)) do
          conn
        else
          _ -> refuse(conn, 401)
        end
    end
  end

  defp configured_token do
    case Keyword.get(Application.get_env(:platform, Platform.Installs, []), :intake_token) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp hash(value), do: :crypto.hash(:sha256, value)

  defp refuse(conn, status) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, "{}")
    |> halt()
  end
end

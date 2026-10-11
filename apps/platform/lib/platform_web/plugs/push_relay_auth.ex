defmodule PlatformWeb.Plugs.PushRelayAuth do
  @moduledoc """
  Authenticates a push relay request (task 01a1261e stage 2). Mirrors
  `PlatformWeb.Plugs.AppBearerAuth`.

    * relay mode off (`Platform.Push.RelayServer.enabled?/0` false) -> 404,
      so a normal install exposes nothing at these routes;
    * `Authorization: Bearer <credential>` hashed and matched to a
      non-revoked `push_relay_installs` row -> assigns `:relay_install`;
    * anything else -> `401 {"error": "unauthorized"}`, never saying which
      check failed and never echoing the credential.
  """

  import Plug.Conn

  alias Platform.Push.RelayServer

  def init(opts), do: opts

  def call(conn, _opts) do
    if RelayServer.enabled?() do
      authenticate(conn)
    else
      refuse(conn, 404, "not_found")
    end
  end

  defp authenticate(conn) do
    with [auth_header] <- get_req_header(conn, "authorization"),
         "Bearer " <> credential <- auth_header,
         {:ok, install} <- RelayServer.verify_credential(credential) do
      assign(conn, :relay_install, install)
    else
      _ -> refuse(conn, 401, "unauthorized")
    end
  end

  defp refuse(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end

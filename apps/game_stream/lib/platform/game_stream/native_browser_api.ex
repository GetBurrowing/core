defmodule Platform.GameStream.NativeBrowserAPI do
  @moduledoc "Session-authenticated native Play handoff. Explicit CSRF protection; no inherited extension auth."
  @behaviour Plug
  import Plug.Conn
  alias Platform.GameStream.{GameChannels, NativeSessions}

  def init(opts), do: opts

  def call(conn, _) do
    conn =
      conn
      |> fetch_session()
      |> PlatformWeb.Plugs.RequireAuthAPI.call([])
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

    if conn.halted do
      conn
    else
      conn = Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init(with: :exception))
      if conn.halted, do: conn, else: dispatch(conn)
    end
  end

  defp dispatch(%{method: "GET", path_info: ["csrf"]} = conn) do
    reply(conn, 200, %{csrf_token: Plug.CSRFProtection.get_csrf_token()})
  end

  defp dispatch(%{method: "POST", path_info: ["channels", id, "configure"]} = conn) do
    result = GameChannels.configure(conn.assigns.current_user, id, conn.body_params["project_id"])

    case result do
      {:ok, binding} ->
        reply(conn, 200, %{channel_id: binding.id, project_id: binding.project_id})

      _ ->
        reply(conn, 403, %{error: "unauthorized"})
    end
  end

  defp dispatch(%{method: "POST", path_info: ["channels", id, "play"]} = conn),
    do: result(conn, NativeSessions.play(conn.assigns.current_user, id))

  defp dispatch(%{method: "GET", path_info: ["channels", id, "status"]} = conn),
    do: result(conn, NativeSessions.status(conn.assigns.current_user, id))

  defp dispatch(%{method: "POST", path_info: ["sessions", id, "join"]} = conn),
    do: result(conn, NativeSessions.mint(conn.assigns.current_user, id))

  defp dispatch(conn), do: reply(conn, 404, %{error: "not_found"})
  defp result(conn, {:ok, value}), do: reply(conn, 200, value)

  defp result(conn, {:error, reason})
       when reason in [
              :no_build,
              :no_native_host,
              :host_unavailable,
              :not_running,
              :stopping,
              :full,
              :already_reserved
            ],
       do: reply(conn, 409, %{error: to_string(reason)})

  defp result(conn, _), do: reply(conn, 403, %{error: "unauthorized"})

  defp reply(conn, status, value),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
      |> halt()
end

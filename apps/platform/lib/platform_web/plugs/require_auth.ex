defmodule PlatformWeb.Plugs.RequireAuth do
  import Plug.Conn
  import Phoenix.Controller

  alias Platform.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :current_user_id) do
      user_id when is_binary(user_id) ->
        case Accounts.get_user(user_id) do
          nil ->
            emit_access_blocked(conn, :stale_session, user_id)

            conn
            |> configure_session(drop: true)
            |> redirect(to: "/auth/login")
            |> halt()

          user ->
            assign(conn, :current_user, user)
        end

      _ ->
        emit_access_blocked(conn, :no_session, nil)

        conn
        |> redirect(to: "/auth/login")
        |> halt()
    end
  end

  defp emit_access_blocked(conn, reason, actor_id) do
    :telemetry.execute(
      [:platform, :auth, :access_blocked],
      %{system_time: System.system_time()},
      %{
        action: "blocked",
        actor_id: actor_id,
        actor_type: if(actor_id, do: "user", else: "anonymous"),
        resource_type: "route",
        resource_id: conn.request_path,
        ip_address: format_ip(conn.remote_ip),
        reason: to_string(reason)
      }
    )
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: to_string(ip)
end

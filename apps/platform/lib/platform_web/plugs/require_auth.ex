defmodule PlatformWeb.Plugs.RequireAuth do
  import Plug.Conn
  import Phoenix.Controller

  alias Platform.Accounts
  alias Platform.Tenancy

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

          %{archived_at: %DateTime{}} ->
            # Stage 5: archived user with a lingering session — drop it
            # and bounce to login. Same shape as the stale-session branch
            # above so audit-log consumers get one class of "session
            # invalidated" event, differentiated by `reason`.
            emit_access_blocked(conn, :user_archived, user_id)

            conn
            |> configure_session(drop: true)
            |> redirect(to: "/auth/login")
            |> halt()

          user ->
            conn
            |> assign(:current_user, user)
            |> assign_membership(user)
        end

      _ ->
        emit_access_blocked(conn, :no_session, nil)

        conn
        |> redirect(to: "/auth/login")
        |> halt()
    end
  end

  # Pure-function derivation of MT/RBAC assigns from an already-preloaded
  # user struct (task 019e3c4a stage 2). `Accounts.get_user/1` preloaded
  # `:org_memberships` (with the nested `:org`) on the round-trip above,
  # so this step does NOT issue an additional Repo query. Keeping the
  # assigns set on the conn means controllers + LiveView mounts (via
  # session round-trip + LiveAuth) see a consistent shape without each
  # having to re-derive.
  defp assign_membership(conn, user) do
    membership = Tenancy.load_membership(user)
    fabrikam_admin? = Tenancy.fabrikam_admin_preloaded?(user)

    conn
    |> assign(:current_user_org_membership, membership)
    |> assign(:fabrikam_admin?, fabrikam_admin?)
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

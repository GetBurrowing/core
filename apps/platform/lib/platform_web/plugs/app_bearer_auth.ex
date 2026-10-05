defmodule PlatformWeb.Plugs.AppBearerAuth do
  @moduledoc """
  Authenticates a native-app request by its `Authorization: Bearer` token
  (task 01a10882). The user-side mirror of
  `PlatformWeb.Plugs.RuntimeBearerAuth`.

  The raw token is SHA-256 hashed and looked up in `app_sessions` by
  `Platform.Mobile.verify_bearer/1`, which refuses an unknown token, a
  revoked session and an archived user alike. On success it assigns
  `:current_user`, `:app_session`, and the same MT/RBAC assigns
  `PlatformWeb.Plugs.RequireAuth` sets (`:current_user_org_membership`,
  `:fabrikam_admin?`), so external-user scoping downstream sees the shape it
  expects. `last_used_at` is bumped at most once a minute.

  Every refusal is the same `401 {"error": "unauthorized"}`: the body never
  says which check failed and never echoes the token.
  """

  import Plug.Conn

  alias Platform.Mobile
  alias Platform.Tenancy

  def init(opts), do: opts

  def call(conn, _opts) do
    with [auth_header] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- auth_header,
         {:ok, user, session} <- Mobile.verify_bearer(token) do
      :ok = Mobile.touch_session(session)

      conn
      |> assign(:current_user, user)
      |> assign(:app_session, session)
      |> assign(:current_user_org_membership, Tenancy.load_membership(user))
      |> assign(:fabrikam_admin?, Tenancy.fabrikam_admin_preloaded?(user))
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end

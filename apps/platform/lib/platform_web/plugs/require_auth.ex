defmodule PlatformWeb.Plugs.RequireAuth do
  @moduledoc """
  Session-cookie authentication gate for browser-facing pipelines.

  A request carrying a valid `:current_user_id` session is annotated with
  `:current_user` plus the MT/RBAC assigns and passed through. A request
  that is NOT authenticated is denied by `deny/2`, whose outcome depends on
  who is calling:

    * `PlatformWeb.ApiClientRequest.api_client?/1` is true (an
      `authorization` header, or an `accept` header that asks for neither
      `text/html` nor `*/*`) -> `401` with a JSON body (see "JSON error
      envelope" below).
    * otherwise (a browser navigation) -> `302` redirect to `/auth/login`,
      exactly as before.

  JSON error envelope (task 01a0ac9c). The API-client arm emits

      {"error": {"code": "unauthorized",
                 "message": "Authentication required.",
                 "reason": "no_session" | "stale_session" | "user_archived"}}

  which is the envelope `docs/contracts/editable-messages-contract.md`
  section B.4 specifies (`{"error": {"code": ..., "message": ...}}`, 401 ->
  `code` `"unauthorized"`) and the one `PlatformWeb.Plugs.RequireAuthAPI`
  already returns, with the same human `message` per reason ("Authentication
  required.", "Session is stale; sign in again.", "Account is archived.").
  `reason` is an optional extra key and lives INSIDE `error`; nothing is
  emitted at the top level besides `error`. Clients branch on the stable
  machine key `error.code`, never on `message`. The next auth surface that
  answers an unauthenticated JSON caller must copy this shape: a stable
  machine `code`, a human `message`, and any extra keys inside `error`.

  `401` and not `403`: the caller presented no valid identity at all, which
  is an authentication failure. Per-resource ownership checks downstream
  keep returning `403`, so the seam stays legible — 401 "who are you",
  403 "not yours".

  SITING (task 01a09415, beneath ADR 0004 — which governs the
  redirect-vs-status contract; this is a placement detail under it, not a
  new strategy). Accept-based classification only reaches `deny/2` on
  pipelines whose `:accepts` list admits the caller's media type: on a
  pipeline declaring `plug(:accepts, ["html"])`, an `Accept:
  application/json` request is refused by content negotiation with 406
  before this plug runs. Two pipelines in `PlatformWeb.Router` pipe
  through this plug AND declare `plug(:accepts, ["html", "json"])`, so an
  `Accept: application/json` caller reaches `deny/2` on them:
  `:blob_browser` (used only by `/files/blob/:id`) and `:agent_avatar`
  (`GET /agents/:id/avatar`). On every other browser pipeline the reachable
  API-caller signal remains the `authorization` header.

  Both outcomes emit the same `[:platform, :auth, :access_blocked]`
  telemetry, and the stale-session / archived-user branches drop the
  session cookie in BOTH outcomes: an API caller presenting a dead session
  cookie should not keep it.
  """

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
            |> deny(:stale_session)

          %{archived_at: %DateTime{}} ->
            # Stage 5: archived user with a lingering session — drop it
            # and bounce to login. Same shape as the stale-session branch
            # above so audit-log consumers get one class of "session
            # invalidated" event, differentiated by `reason`.
            emit_access_blocked(conn, :user_archived, user_id)

            conn
            |> configure_session(drop: true)
            |> deny(:user_archived)

          user ->
            conn
            |> assign(:current_user, user)
            |> assign_membership(user)
        end

      _ ->
        emit_access_blocked(conn, :no_session, nil)

        deny(conn, :no_session)
    end
  end

  # Single denial tail for every unauthenticated branch above. Mirrors the
  # dual-principal split already used by `PlatformWeb.Plugs.AttachmentAuth`
  # (`unauthorized_json/1` vs. the session redirect).
  defp deny(conn, reason) do
    if PlatformWeb.ApiClientRequest.api_client?(conn) do
      body =
        Jason.encode!(%{
          error: %{code: "unauthorized", message: message(reason), reason: to_string(reason)}
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, body)
      |> halt()
    else
      conn
      |> redirect(to: "/auth/login")
      |> halt()
    end
  end

  # Same human messages as `PlatformWeb.Plugs.RequireAuthAPI`, so one reason
  # reads identically whichever of the two plugs denied it.
  defp message(:no_session), do: "Authentication required."
  defp message(:stale_session), do: "Session is stale; sign in again."
  defp message(:user_archived), do: "Account is archived."

  # Pure-function derivation of MT/RBAC assigns from an already-preloaded
  # user struct (task 019e3c4a stage 2). `Accounts.get_user/1` preloaded
  # `:org_memberships` (with the nested `:org`) on the round-trip above,
  # so this step does NOT issue an additional Repo query. Keeping the
  # assigns set on the conn means controllers + LiveView mounts (via
  # session round-trip + LiveAuth) see a consistent shape without each
  # having to re-derive.
  defp assign_membership(conn, user) do
    membership = Tenancy.load_membership(user)
    root_admin? = Tenancy.root_admin_preloaded?(user)

    conn
    |> assign(:current_user_org_membership, membership)
    |> assign(:root_admin?, root_admin?)
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

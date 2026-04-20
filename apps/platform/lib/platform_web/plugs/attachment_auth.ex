defmodule PlatformWeb.Plugs.AttachmentAuth do
  @moduledoc """
  Dual-auth plug for attachment reads (ADR 0039 phase 3).

  A request is authorized as one of two principals:

    - Bearer token matching an active `AgentRuntime` → `{:runtime, runtime}`
    - Session cookie with `current_user_id` → `{:user, user_id}`

  The resolved principal is assigned to `conn.assigns.principal`. Downstream
  controllers use it to check space membership against the attachment's
  `space_id`. Bearer failures return `401 JSON`; session failures redirect
  to `/auth/login` (preserving the pre-ADR-0039 browser behaviour).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Platform.Accounts
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    case authorization_header(conn) do
      "Bearer " <> token when token != "" ->
        authenticate_bearer(conn, token)

      _ ->
        authenticate_session(conn)
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] -> header
      _ -> nil
    end
  end

  defp authenticate_bearer(conn, token) do
    case lookup_runtime(token) do
      %AgentRuntime{status: "active"} = runtime ->
        conn
        |> assign(:runtime, runtime)
        |> assign(:principal, {:runtime, runtime})

      _ ->
        unauthorized_json(conn)
    end
  end

  defp authenticate_session(conn) do
    with user_id when is_binary(user_id) <- get_session(conn, :current_user_id),
         user when not is_nil(user) <- Accounts.get_user(user_id) do
      conn
      |> assign(:current_user, user)
      |> assign(:principal, {:user, user.id})
    else
      _ ->
        conn
        |> redirect(to: "/auth/login")
        |> halt()
    end
  end

  defp lookup_runtime(token) do
    hash = AgentRuntime.hash_token(token)
    Repo.get_by(AgentRuntime, auth_token_hash: hash)
  end

  defp unauthorized_json(conn) do
    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        error: %{code: -32000, message: "unauthorized"}
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end

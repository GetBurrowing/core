defmodule PlatformWeb.Plugs.RequireAuthAPI do
  @moduledoc """
  JSON-API counterpart to `PlatformWeb.Plugs.RequireAuth`.

  Reads `:current_user_id` from the browser session and assigns
  `conn.assigns.current_user` (a `%Platform.Accounts.User{}`). On a
  missing or stale session, halts with `401 Unauthorized` and a JSON
  envelope that matches the editable-messages contract Section (b.4):
  `{"error": {"code": "unauthorized", "message": "..."}}`.

  Used by controllers under `pipe_through(:require_auth_api)` that need
  to authenticate the requester *and* return JSON on failure (vs the
  redirect-on-failure behavior of `RequireAuth`, which is appropriate
  for browser-rendered routes but breaks API clients).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Platform.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :current_user_id) do
      user_id when is_binary(user_id) ->
        case Accounts.get_user(user_id) do
          nil ->
            conn
            |> configure_session(drop: true)
            |> unauthorized("Session is stale; sign in again.")

          %{archived_at: %DateTime{}} ->
            # Stage 5: JSON-API counterpart to `RequireAuth`'s
            # archived-user guard. Drop the session so the next
            # navigation to a browser route also bounces cleanly.
            conn
            |> configure_session(drop: true)
            |> unauthorized("Account is archived.")

          user ->
            assign(conn, :current_user, user)
        end

      _ ->
        unauthorized(conn, "Authentication required.")
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{code: "unauthorized", message: message}})
    |> halt()
  end
end

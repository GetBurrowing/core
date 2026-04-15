defmodule PlatformWeb.Plugs.RuntimeBearerAuth do
  @moduledoc """
  Authenticates a request against a federated `AgentRuntime` via a Bearer token.

  The raw token is SHA256-hashed and compared against `AgentRuntime.auth_token_hash`.
  Only runtimes in the `active` status are accepted. On success the runtime is
  assigned to `conn.assigns.runtime`. On failure the connection is halted with
  `401 Unauthorized` and a JSON-RPC style error body.
  """

  import Plug.Conn

  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    with [auth_header] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- auth_header,
         %AgentRuntime{status: "active"} = runtime <- lookup_runtime(token) do
      assign(conn, :runtime, runtime)
    else
      _ -> unauthorized(conn)
    end
  end

  defp lookup_runtime(token) when is_binary(token) and token != "" do
    hash = AgentRuntime.hash_token(token)
    Repo.get_by(AgentRuntime, auth_token_hash: hash)
  end

  defp lookup_runtime(_), do: nil

  defp unauthorized(conn) do
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

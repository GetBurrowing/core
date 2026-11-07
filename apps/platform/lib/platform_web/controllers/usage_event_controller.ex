defmodule PlatformWeb.UsageEventController do
  use PlatformWeb, :controller

  alias Platform.Analytics
  alias Platform.Federation

  def create(conn, params) do
    with :ok <- verify_bearer_token(conn) do
      case Analytics.record_usage_event(params) do
        {:ok, event} ->
          conn
          |> put_status(:created)
          |> json(%{id: event.id})

        {:error, changeset} ->
          errors =
            Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
              Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
                opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
              end)
            end)

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: errors})
      end
    end
  end

  defp verify_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        # Same rule as socket/MCP/attachment auth (task 01a1b34b): only an
        # `active` runtime bound to an agent may authenticate. A suspended,
        # revoked or agentless runtime's token is refused.
        if Federation.get_runtime_by_token(token) do
          :ok
        else
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "invalid token"})
          |> halt()
        end

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "missing authorization header"})
        |> halt()
    end
  end
end

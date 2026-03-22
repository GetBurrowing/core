defmodule PlatformWeb.UsageEventController do
  use PlatformWeb, :controller

  alias Platform.Analytics
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  import Ecto.Query

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
        hashed = AgentRuntime.hash_token(token)

        exists =
          from(r in AgentRuntime, where: r.auth_token_hash == ^hashed, limit: 1)
          |> Repo.exists?()

        if exists do
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

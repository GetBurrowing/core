defmodule Platform.Vault.ToolHandlers do
  @moduledoc """
  MCP handlers for `vault_fetch` and `vault_list` (the `federation` bundle).

  The caller is the AUTHENTICATED agent in `context.agent_id`
  (`Platform.Federation.ToolCall.build_context/2`); no argument names an agent.

  A tool result is model-visible and lands in the agent's transcript, so
  neither handler ever returns a secret value. `vault_fetch` returns a
  single-use URL and the shell command that downloads it to a private file;
  see `Platform.Vault.Fetch` for the flow and the accepted risks.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.Credential
  alias Platform.Vault.Fetch
  alias Platform.Vault.Shared

  @not_granted %{error: "not granted", recoverable: false}

  @doc """
  Issue a single-use fetch URL for the shared secret `args["name"]`.

  Returns `{:ok, %{url, expires_in, fingerprint, command}}`. An unknown name
  and an ungranted name answer identically, so an agent cannot probe which
  secrets exist.
  """
  @spec fetch(map(), map()) :: {:ok, map()} | {:error, map()}
  def fetch(args, context) do
    name = Map.get(args, "name")
    agent_id = Map.get(context, :agent_id)

    cond do
      not Shared.valid_slug?(name) ->
        {:error,
         %{
           error: "name must match #{inspect(Shared.slug_format().source)}",
           code: "invalid_name",
           recoverable: true
         }}

      is_nil(agent_id) ->
        {:error, @not_granted}

      true ->
        case Fetch.issue(agent_id, name) do
          {:ok, %{url: url} = ticket} ->
            {:ok, Map.put(ticket, :command, command(name, url))}

          {:error, _} ->
            {:error, @not_granted}
        end
    end
  end

  @doc """
  The shared secrets the calling agent holds a `use` grant on: name,
  fingerprint and rotated_at. Never a value.
  """
  @spec list(map(), map()) :: {:ok, map()} | {:error, map()}
  def list(_args, context) do
    case Platform.UUID.cast(Map.get(context, :agent_id)) do
      {:ok, agent_id} ->
        secrets =
          from(c in Credential,
            join: g in AccessGrant,
            on: g.credential_id == c.id,
            where:
              c.scope_type == "shared" and g.grantee_type == "agent" and
                g.grantee_id == ^agent_id and fragment("'use' = ANY(?)", g.permissions),
            order_by: [asc: c.slug],
            select: %{name: c.slug, metadata: c.metadata, rotated_at: c.rotated_at}
          )
          |> Repo.all()
          |> Enum.map(fn %{metadata: meta} = row ->
            row |> Map.delete(:metadata) |> Map.put(:fingerprint, (meta || %{})["fingerprint"])
          end)

        {:ok, %{secrets: secrets, total: length(secrets), has_more: false}}

      :error ->
        {:ok, %{secrets: [], total: 0, has_more: false}}
    end
  end

  # `name` has already matched the slug format (no quote, space, slash or
  # shell metacharacter), so it is safe unquoted in a path. The URL token is
  # base64url and the URL is single-quoted.
  defp command(name, url) do
    "umask 077 && mkdir -p ~/.suite-secrets && curl -fsS -o ~/.suite-secrets/#{name} '#{url}'"
  end
end

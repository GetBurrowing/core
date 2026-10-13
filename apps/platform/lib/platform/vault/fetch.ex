defmodule Platform.Vault.Fetch do
  @moduledoc """
  The agent read path for shared vault secrets: single-use fetch tickets.

  An MCP tool result is model-visible, so the `vault_fetch` tool never returns
  a value. It returns a URL instead; the agent's own shell downloads the value
  straight to a private file:

      umask 077 && mkdir -p ~/.suite-secrets && curl -fsS -o ~/.suite-secrets/<name> '<url>'

  and then uses it as `FOO=$(cat ~/.suite-secrets/<name>) some-cli ...`.

  ## Flow

    * `issue/2` authorizes `{:agent, agent_id}` for `:use` on the SHARED
      credential named `slug` (`scope_type == "shared"` only — a platform
      secret with the same name is never served), mints 32 random bytes,
      stores their SHA-256 with a 120s TTL and logs `read` with
      `%{"via" => "ticket_issued"}`. A refusal writes a `denied` row.
    * `redeem/2` claims the ticket atomically (unconsumed and unexpired), then
      RE-CHECKS the grant through `Platform.Vault.get/2`, so ungranting after
      issue makes the URL useless, and a rotation after issue serves the new
      value. A success logs `use` with the ticket id, fingerprint and remote
      IP.

  ## Accepted risks (v1)

    1. The URL appears in the agent's transcript. It is single-use, expires in
       120s, is bound to the issuing agent's grant, and is dead once redeemed.
       Someone who redeems it first makes the agent's curl fail with 410, and
       the access log records their remote IP.
    2. An agent that curls to stdout instead of `-o` puts the value in its own
       transcript. The server cannot detect that, so `-o` is mandatory.
    3. Native in-BEAM agents have no shell, so v1 does not serve them.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Vault
  alias Platform.Vault.Credential
  alias Platform.Vault.FetchTicket

  @ttl_seconds 120
  @token_bytes 32
  @path "/vault/fetch/"

  @doc "Ticket lifetime in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Issue a single-use fetch URL for the shared secret `slug` to `agent_id`.

  Returns `{:ok, %{url, expires_in, fingerprint}}`, or
  `{:error, :not_found | :access_denied}`. Nothing returned or logged here
  carries the value.
  """
  @spec issue(String.t() | nil, String.t()) ::
          {:ok, %{url: String.t(), expires_in: pos_integer(), fingerprint: String.t() | nil}}
          | {:error, :not_found | :access_denied}
  def issue(agent_id, slug) when is_binary(slug) do
    accessor = {:agent, agent_id}

    result =
      Repo.transaction(fn ->
        case Vault.authorize(slug, accessor, :use, scope: {:shared, nil}) do
          {:ok, %Credential{scope_type: "shared"} = cred} ->
            mint(cred, agent_id, accessor)

          {:ok, _other} ->
            {:error, :not_found}

          {:error, :ambiguous_slug} ->
            {:error, :not_found}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, reason} -> {:error, reason}
    end
  end

  defp mint(cred, agent_id, accessor) do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    now = DateTime.utc_now()
    ticket_id = Platform.Types.UUIDv7.generate()

    ticket =
      Repo.insert!(%FetchTicket{
        id: ticket_id,
        token_hash: hash(token),
        credential_id: cred.id,
        agent_id: agent_id,
        expires_at: DateTime.add(now, @ttl_seconds, :second)
      })

    {:ok, _} =
      Vault.record_access(cred, accessor, "read", %{
        "via" => "ticket_issued",
        "ticket_id" => ticket.id
      })

    {:ok,
     %{
       url: PlatformWeb.Endpoint.url() <> @path <> token,
       expires_in: @ttl_seconds,
       fingerprint: cred.metadata["fingerprint"]
     }}
  end

  @doc """
  Redeem a raw ticket token. Single-use: the claim is one atomic UPDATE over
  `consumed_at IS NULL AND expires_at > now()`.

  Returns `{:ok, value}`, `{:error, :gone}` (unknown, consumed or expired —
  indistinguishable on purpose) or `{:error, :access_denied}` (the grant was
  removed after issue; a `denied` row is written).
  """
  @spec redeem(String.t(), String.t() | nil) ::
          {:ok, binary()} | {:error, :gone | :access_denied}
  def redeem(token, remote_ip) when is_binary(token) do
    now = DateTime.utc_now()
    token_hash = hash(token)

    claim =
      from(t in FetchTicket,
        where: t.token_hash == ^token_hash and is_nil(t.consumed_at) and t.expires_at > ^now,
        select: t
      )

    case Repo.update_all(claim, set: [consumed_at: now]) do
      {1, [ticket]} -> serve(ticket, remote_ip)
      {0, []} -> {:error, :gone}
    end
  end

  def redeem(_token, _remote_ip), do: {:error, :gone}

  defp serve(%FetchTicket{} = ticket, remote_ip) do
    meta =
      from(c in Credential,
        where: c.id == ^ticket.credential_id and c.scope_type == "shared",
        select: %{slug: c.slug, metadata: c.metadata}
      )
      |> Repo.one()

    case meta do
      nil ->
        {:error, :gone}

      %{slug: slug, metadata: metadata} ->
        log_metadata = %{
          "via" => "fetch_ticket",
          "ticket_id" => ticket.id,
          "fingerprint" => (metadata || %{})["fingerprint"],
          "remote_ip" => remote_ip
        }

        case Vault.get(slug,
               scope: {:shared, nil},
               accessor: {:agent, ticket.agent_id},
               log_metadata: log_metadata
             ) do
          {:ok, value} -> {:ok, value}
          {:error, :access_denied} -> {:error, :access_denied}
          {:error, _} -> {:error, :gone}
        end
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end

defmodule Platform.Vault.Shared do
  @moduledoc """
  Admin-managed shared secrets: a human pastes a value and picks which agents
  may fetch it. The context behind `/admin/vault`.

  Every secret here is `scope_type: "shared"` at `{:shared, nil}`. Read
  access is decided by `Platform.Vault`'s shared-scope clause, which honours
  ONLY an explicit `"use"` grant; this module writes and removes those grants.
  `metadata` (note, fingerprint) is display-only and plays no part in access.

  ## Authorization

  Every function takes the acting user record and re-checks
  `Platform.Tenancy.root_admin?/1`, mirroring `Platform.Branding` — the route
  gate is not load-bearing alone. A non-admin gets `{:error, :unauthorized}`
  and nothing is written.

  ## Write-only

  No function here returns or logs a value. `list/1` selects explicit columns
  and never loads `encrypted_data`; errors carry only `:slug_taken`,
  `:invalid_slug` or strings derived from `changeset.errors`.
  """

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Vault
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.AccessLog
  alias Platform.Vault.Credential

  @scope {:shared, nil}
  @slug_format ~r/^[a-z0-9][a-z0-9_.-]{0,63}$/

  @doc "The slug format a shared secret name must match."
  @spec slug_format() :: Regex.t()
  def slug_format, do: @slug_format

  @doc "Is `slug` a valid shared secret name?"
  @spec valid_slug?(term()) :: boolean()
  def valid_slug?(slug) when is_binary(slug), do: Regex.match?(@slug_format, slug)
  def valid_slug?(_), do: false

  @doc """
  Create a shared secret and grant `use` on it to every agent in `agent_ids`,
  in one transaction.

  Refuses with `{:error, :slug_taken}` when the slug exists at ANY scope —
  a shared slug must not shadow a platform one — and writes nothing.
  """
  @spec create(map() | nil, map(), [String.t()]) ::
          {:ok, map()} | {:error, :unauthorized | :slug_taken | :invalid_slug | term()}
  def create(actor, attrs, agent_ids \\ []) do
    with_root_admin(actor, fn ->
      slug = fetch_attr(attrs, :slug)
      value = fetch_attr(attrs, :value)
      note = fetch_attr(attrs, :note)

      cond do
        not valid_slug?(slug) ->
          {:error, :invalid_slug}

        not is_binary(value) or value == "" ->
          {:error, :value_required}

        true ->
          do_create(actor, slug, value, note, agent_ids)
      end
    end)
  end

  defp do_create(actor, slug, value, note, agent_ids) do
    Repo.transaction(fn ->
      if Repo.exists?(from(c in Credential, where: c.slug == ^slug)) do
        Repo.rollback(:slug_taken)
      end

      metadata = if is_binary(note) and note != "", do: %{"note" => note}, else: %{}

      cred =
        case Vault.put(slug, "api_key", value,
               scope: @scope,
               provider: "admin_vault",
               metadata: metadata
             ) do
          {:ok, cred} -> cred
          {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(changeset_reason(cs))
        end

      {:ok, _} = Vault.record_access(cred, accessor(actor), "create", %{})

      case apply_grants(actor, cred, agent_ids) do
        :ok -> summary(cred)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Replace the value of the shared secret `slug`. Every grantee's next fetch gets the new value."
  @spec rotate(map() | nil, String.t(), binary()) ::
          {:ok, map()} | {:error, :unauthorized | :not_found | :value_required | term()}
  def rotate(actor, slug, value) do
    with_root_admin(actor, fn ->
      if is_binary(value) and value != "" do
        case Vault.rotate(slug, value, scope: @scope, accessor: accessor(actor)) do
          {:ok, cred} -> {:ok, summary(cred)}
          {:error, %Ecto.Changeset{} = cs} -> {:error, changeset_reason(cs)}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :value_required}
      end
    end)
  end

  @doc "Destroy the shared secret `slug` and every grant on it. The access log is retained."
  @spec revoke(map() | nil, String.t()) ::
          {:ok, %{slug: String.t()}} | {:error, :unauthorized | :not_found | term()}
  def revoke(actor, slug) do
    with_root_admin(actor, fn ->
      case Vault.delete(slug, scope: @scope, accessor: accessor(actor)) do
        # Vault.delete/2 returns the deleted struct, which still holds the
        # decrypted value in memory. Never hand it on.
        {:ok, _deleted} -> {:ok, %{slug: slug}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Make the set of agents holding a `use` grant on the shared credential
  `credential_id` exactly `agent_ids`. Adds missing grants, deletes only the
  removed agents' grants, and logs one `update` row per change.
  """
  @spec set_grants(map() | nil, String.t(), [String.t()]) ::
          :ok | {:error, :unauthorized | :not_found | term()}
  def set_grants(actor, credential_id, agent_ids) do
    with_root_admin(actor, fn ->
      with {:ok, id} <- cast_uuid(credential_id),
           %Credential{} = cred <- shared_credential(id) do
        case Repo.transaction(fn ->
               case apply_grants(actor, cred, agent_ids) do
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end
             end) do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Every shared secret, metadata only: id, slug, name, note, fingerprint,
  timestamps, `granted_agent_ids` and `refused_7d` (denied rows in the last
  seven days). Never a value.
  """
  @spec list(map() | nil) :: {:ok, [map()]} | {:error, :unauthorized}
  def list(actor) do
    with_root_admin(actor, fn ->
      creds =
        from(c in Credential,
          where: c.scope_type == "shared",
          order_by: [asc: c.slug],
          select: %{
            id: c.id,
            slug: c.slug,
            name: c.name,
            scope_type: c.scope_type,
            scope_id: c.scope_id,
            metadata: c.metadata,
            inserted_at: c.inserted_at,
            rotated_at: c.rotated_at,
            last_used_at: c.last_used_at
          }
        )
        |> Repo.all()

      ids = Enum.map(creds, & &1.id)
      grants = grants_by_credential(ids)
      refused = refused_since(ids, DateTime.add(DateTime.utc_now(), -7, :day))

      {:ok,
       Enum.map(creds, fn c ->
         meta = c.metadata || %{}

         c
         |> Map.drop([:metadata])
         |> Map.merge(%{
           note: meta["note"],
           fingerprint: meta["fingerprint"],
           granted_agent_ids: Map.get(grants, c.id, []),
           refused_7d: Map.get(refused, c.id, 0)
         })
       end)}
    end)
  end

  @doc "The access log for the shared secret `slug`, newest first."
  @spec access_log(map() | nil, String.t(), keyword()) ::
          {:ok, [AccessLog.t()]} | {:error, :unauthorized}
  def access_log(actor, slug, opts \\ []) do
    with_root_admin(actor, fn -> {:ok, Vault.access_log(slug, opts)} end)
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp apply_grants(actor, %Credential{} = cred, agent_ids) do
    with {:ok, wanted} <- cast_agent_ids(agent_ids) do
      existing =
        from(g in AccessGrant,
          where: g.credential_id == ^cred.id and g.grantee_type == "agent",
          select: g.grantee_id
        )
        |> Repo.all()
        |> MapSet.new()

      added = wanted |> MapSet.difference(existing) |> Enum.sort()
      removed = existing |> MapSet.difference(wanted) |> Enum.sort()

      Enum.each(added, fn agent_id ->
        Repo.insert!(
          %AccessGrant{
            credential_id: cred.id,
            grantee_type: "agent",
            grantee_id: agent_id,
            permissions: ["use"],
            granted_by: actor.id
          },
          on_conflict: :nothing,
          conflict_target: [:credential_id, :grantee_type, :grantee_id]
        )

        {:ok, _} =
          Vault.record_access(cred, accessor(actor), "update", %{
            "grant" => "added",
            "agent_id" => agent_id
          })
      end)

      if removed != [] do
        from(g in AccessGrant,
          where:
            g.credential_id == ^cred.id and g.grantee_type == "agent" and
              g.grantee_id in ^removed
        )
        |> Repo.delete_all()

        Enum.each(removed, fn agent_id ->
          {:ok, _} =
            Vault.record_access(cred, accessor(actor), "update", %{
              "grant" => "removed",
              "agent_id" => agent_id
            })
        end)
      end

      :ok
    end
  end

  # Every id must be a UUID naming an existing agent; one bad id refuses the
  # whole change rather than granting a partial set.
  defp cast_agent_ids(agent_ids) when is_list(agent_ids) do
    cast =
      Enum.map(agent_ids, fn id ->
        case Platform.UUID.cast(id) do
          {:ok, uuid} -> uuid
          :error -> :error
        end
      end)

    if Enum.member?(cast, :error) do
      {:error, :unknown_agent}
    else
      wanted = MapSet.new(cast)
      list = MapSet.to_list(wanted)

      found =
        from(a in Agent, where: a.id in ^list, select: a.id)
        |> Repo.all()
        |> MapSet.new()

      if MapSet.equal?(found, wanted), do: {:ok, wanted}, else: {:error, :unknown_agent}
    end
  end

  defp cast_agent_ids(_), do: {:error, :unknown_agent}

  defp grants_by_credential([]), do: %{}

  defp grants_by_credential(ids) do
    from(g in AccessGrant,
      where: g.credential_id in ^ids and g.grantee_type == "agent",
      where: fragment("'use' = ANY(?)", g.permissions),
      order_by: [asc: g.inserted_at],
      select: {g.credential_id, g.grantee_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp refused_since([], _since), do: %{}

  defp refused_since(ids, since) do
    from(l in AccessLog,
      where: l.credential_id in ^ids and l.action == "denied" and l.inserted_at >= ^since,
      group_by: l.credential_id,
      select: {l.credential_id, count(l.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp shared_credential(id) do
    Repo.one(from(c in Credential, where: c.id == ^id and c.scope_type == "shared"))
  end

  defp summary(%Credential{} = cred) do
    meta = cred.metadata || %{}

    %{
      id: cred.id,
      slug: cred.slug,
      name: cred.name,
      scope_type: cred.scope_type,
      note: meta["note"],
      fingerprint: meta["fingerprint"],
      inserted_at: cred.inserted_at,
      rotated_at: cred.rotated_at,
      last_used_at: cred.last_used_at
    }
  end

  defp changeset_reason(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {field, {_msg, opts}} ->
         field == :slug and Keyword.get(opts, :constraint) == :unique
       end) do
      :slug_taken
    else
      {:invalid, Enum.map(errors, fn {field, {msg, _opts}} -> "#{field} #{msg}" end)}
    end
  end

  defp cast_uuid(id) do
    case Platform.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, to_string(key)))
  end

  defp accessor(%{id: id}), do: {:platform, id}

  defp with_root_admin(actor, fun) do
    if Tenancy.root_admin?(actor), do: fun.(), else: {:error, :unauthorized}
  end
end

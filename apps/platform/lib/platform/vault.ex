defmodule Platform.Vault do
  @moduledoc "General-purpose encrypted credential store."

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.AccessLog
  alias Platform.Vault.Credential

  # Sentinel UUID used when the accessor is anonymous/system (accessor_id NOT NULL in DB).
  @system_accessor_id "00000000-0000-0000-0000-000000000000"

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Store a new encrypted credential.

  ## Options

    * `:provider`     - provider name (e.g. `"github"`)
    * `:scope`        - `{scope_type, scope_id}` tuple, default `{:platform, nil}`
    * `:name`         - human-readable name (defaults to `slug`)
    * `:metadata`     - arbitrary metadata map
    * `:expires_at`   - `DateTime` when the credential expires
    * `:workspace_id` - workspace this credential belongs to
  """
  @spec put(String.t(), atom() | String.t(), binary(), keyword()) ::
          {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def put(slug, credential_type, value, opts \\ []) do
    {scope_type, scope_id} = Keyword.get(opts, :scope, {:platform, nil})

    attrs = %{
      slug: slug,
      credential_type: to_string(credential_type),
      encrypted_data: value,
      scope_type: to_string(scope_type),
      scope_id: scope_id,
      name: Keyword.get(opts, :name, slug),
      provider: Keyword.get(opts, :provider),
      metadata: Keyword.get(opts, :metadata, %{}),
      expires_at: Keyword.get(opts, :expires_at),
      workspace_id: Keyword.get(opts, :workspace_id)
    }

    with {:ok, credential} <- %Credential{} |> Credential.changeset(attrs) |> Repo.insert() do
      :telemetry.execute(
        [:platform, :vault, :credential_created],
        %{system_time: System.system_time()},
        %{
          credential_id: credential.id,
          slug: slug,
          scope_type: to_string(scope_type)
        }
      )

      {:ok, strip_encrypted(credential)}
    end
  end

  @doc """
  Retrieve and decrypt a credential by slug.

  Access is checked against the credential's scope and any explicit grants.
  Every call — granted or denied — is written to the vault access log.

  ## Options

    * `:accessor`     - `{accessor_type, accessor_id}` tuple identifying the requester
    * `:workspace_id` - workspace context (used to narrow the lookup)
  """
  @spec get(String.t(), keyword()) ::
          {:ok, binary()} | {:error, :not_found | :access_denied}
  def get(slug, opts \\ []) do
    accessor = Keyword.get(opts, :accessor)

    credential = lookup_by_slug(slug, opts)

    case credential do
      nil ->
        {:error, :not_found}

      cred ->
        case check_access(cred, accessor) do
          :ok ->
            now = DateTime.utc_now()

            {:ok, updated} =
              cred
              |> Credential.changeset(%{last_used_at: now})
              |> Repo.update()

            :telemetry.execute(
              [:platform, :vault, :credential_used],
              %{system_time: System.system_time()},
              %{credential_id: cred.id, slug: slug, accessor: accessor}
            )

            log_access(cred.id, accessor, "use", %{})

            {:ok, updated.encrypted_data}

          {:error, :access_denied} ->
            :telemetry.execute(
              [:platform, :vault, :access_denied],
              %{system_time: System.system_time()},
              %{credential_id: cred.id, slug: slug, accessor: accessor}
            )

            log_access(cred.id, accessor, "denied", %{})

            {:error, :access_denied}
        end
    end
  end

  @doc """
  Atomically replace a credential's encrypted value.

  ## Options

    * `:accessor` - `{accessor_type, accessor_id}` performing the rotation
  """
  @spec rotate(String.t(), binary(), keyword()) ::
          {:ok, Credential.t()} | {:error, :not_found | any()}
  def rotate(slug, new_value, opts \\ []) do
    accessor = Keyword.get(opts, :accessor)

    case Repo.get_by(Credential, slug: slug) do
      nil ->
        {:error, :not_found}

      credential ->
        now = DateTime.utc_now()

        result =
          Repo.transaction(fn ->
            case credential
                 |> Credential.changeset(%{encrypted_data: new_value, rotated_at: now})
                 |> Repo.update() do
              {:ok, updated} -> updated
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)

        case result do
          {:ok, updated} ->
            :telemetry.execute(
              [:platform, :vault, :credential_rotated],
              %{system_time: System.system_time()},
              %{credential_id: credential.id, slug: slug}
            )

            log_access(credential.id, accessor, "rotate", %{})

            {:ok, strip_encrypted(updated)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  List credentials by filters, returning metadata only (no decryption).

  ## Options

    * `:scope`           - `{scope_type, scope_id}` to filter by
    * `:provider`        - filter by provider name
    * `:credential_type` - filter by credential type atom or string
    * `:workspace_id`    - filter by workspace
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    metadata_fields = [
      :id,
      :workspace_id,
      :slug,
      :name,
      :credential_type,
      :provider,
      :metadata,
      :scope_type,
      :scope_id,
      :expires_at,
      :last_used_at,
      :rotated_at,
      :inserted_at,
      :updated_at
    ]

    base = from(c in Credential, select: map(c, ^metadata_fields))

    opts
    |> Enum.reduce(base, fn
      {:scope, {scope_type, nil}}, q ->
        where(q, [c], c.scope_type == ^to_string(scope_type) and is_nil(c.scope_id))

      {:scope, {scope_type, scope_id}}, q ->
        where(q, [c], c.scope_type == ^to_string(scope_type) and c.scope_id == ^scope_id)

      {:provider, provider}, q ->
        where(q, [c], c.provider == ^provider)

      {:credential_type, type}, q ->
        where(q, [c], c.credential_type == ^to_string(type))

      {:workspace_id, wid}, q ->
        where(q, [c], c.workspace_id == ^wid)

      _other, q ->
        q
    end)
    |> Repo.all()
  end

  @doc """
  Delete a credential and cascade to access grants.

  The access log entry is written before deletion (FK constraint).

  ## Options

    * `:accessor` - `{accessor_type, accessor_id}` performing the deletion
  """
  @spec delete(String.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, :not_found | any()}
  def delete(slug, opts \\ []) do
    accessor = Keyword.get(opts, :accessor)

    case Repo.get_by(Credential, slug: slug) do
      nil ->
        {:error, :not_found}

      credential ->
        # Log BEFORE deletion — vault_access_log FK has on_delete: :nothing.
        log_access(credential.id, accessor, "revoke", %{})

        result =
          Repo.transaction(fn ->
            # Grants are cascade-deleted by the DB (on_delete: :delete_all).
            from(g in AccessGrant, where: g.credential_id == ^credential.id)
            |> Repo.delete_all()

            # Access logs have on_delete: :nothing — must delete manually.
            from(l in AccessLog, where: l.credential_id == ^credential.id)
            |> Repo.delete_all()

            case Repo.delete(credential) do
              {:ok, deleted} -> deleted
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)

        case result do
          {:ok, deleted} ->
            :telemetry.execute(
              [:platform, :vault, :credential_revoked],
              %{system_time: System.system_time()},
              %{credential_id: credential.id, slug: slug}
            )

            {:ok, deleted}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Find credentials expiring within a time window.

  ## Options

    * `:within` - `{amount, unit}` tuple, default `{7, :days}`
                  Supported units: `:days`, `:hours`, `:minutes`, `:seconds`
  """
  @spec expiring_soon(keyword()) :: [Credential.t()]
  def expiring_soon(opts \\ []) do
    {amount, unit} = Keyword.get(opts, :within, {7, :days})
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, duration_to_seconds({amount, unit}), :second)

    from(c in Credential,
      where: not is_nil(c.expires_at),
      where: c.expires_at >= ^now,
      where: c.expires_at <= ^cutoff,
      order_by: [asc: c.expires_at]
    )
    |> Repo.all()
    |> Enum.map(&strip_encrypted/1)
  end

  # ── Private: Lookup ──────────────────────────────────────────────────────────

  defp lookup_by_slug(slug, opts) do
    base = from(c in Credential, where: c.slug == ^slug, limit: 1)

    base =
      case Keyword.get(opts, :workspace_id) do
        nil -> base
        wid -> where(base, [c], c.workspace_id == ^wid)
      end

    Repo.one(base)
  end

  # ── Private: Access Control ──────────────────────────────────────────────────

  # Platform-scoped: accessible by any accessor.
  defp check_access(%Credential{scope_type: "platform"}, _accessor), do: :ok

  # Workspace-scoped: always allow for now (membership enforcement coming later).
  defp check_access(%Credential{scope_type: "workspace"}, _accessor), do: :ok

  # Agent-scoped: owner or explicit grant.
  defp check_access(
         %Credential{scope_type: "agent", scope_id: scope_id} = cred,
         {:agent, accessor_id}
       ) do
    if scope_id == accessor_id do
      :ok
    else
      check_explicit_grant(cred, "agent", accessor_id)
    end
  end

  # Integration-scoped: owner or explicit grant.
  defp check_access(
         %Credential{scope_type: "integration", scope_id: scope_id} = cred,
         {:integration, accessor_id}
       ) do
    if scope_id == accessor_id do
      :ok
    else
      check_explicit_grant(cred, "integration", accessor_id)
    end
  end

  # Cross-type access to restricted scopes: check explicit grants only.
  defp check_access(%Credential{scope_type: type} = cred, {accessor_type, accessor_id})
       when type in ["agent", "integration"] do
    check_explicit_grant(cred, to_string(accessor_type), accessor_id)
  end

  # All other cases (nil accessor, unknown accessor type): deny.
  defp check_access(_credential, _accessor), do: {:error, :access_denied}

  defp check_explicit_grant(%Credential{id: credential_id}, grantee_type, grantee_id) do
    grant =
      from(g in AccessGrant,
        where:
          g.credential_id == ^credential_id and
            g.grantee_type == ^grantee_type and
            g.grantee_id == ^grantee_id and
            fragment("? = ANY(?)", ^"use", g.permissions),
        limit: 1
      )
      |> Repo.one()

    if grant, do: :ok, else: {:error, :access_denied}
  end

  # ── Private: Audit Logging ───────────────────────────────────────────────────

  # Synchronous for v1 simplicity. Can be made async with Task.start + Sandbox.allow
  # for production hardening.
  defp log_access(credential_id, accessor, action, metadata) do
    {accessor_type, accessor_id} = parse_accessor(accessor)

    Repo.insert(%AccessLog{
      credential_id: credential_id,
      accessor_type: accessor_type,
      accessor_id: accessor_id,
      action: action,
      metadata: metadata
    })
  end

  # Converts accessor tuple to {type_string, id_string}.
  # Falls back to a sentinel UUID for system/nil access (accessor_id NOT NULL in DB).
  defp parse_accessor({type, nil}) when is_atom(type), do: {to_string(type), @system_accessor_id}
  defp parse_accessor({type, id}) when is_atom(type), do: {to_string(type), normalize_uuid(id)}
  defp parse_accessor({type, nil}), do: {to_string(type), @system_accessor_id}
  defp parse_accessor({type, id}), do: {to_string(type), normalize_uuid(id)}
  defp parse_accessor(nil), do: {"system", @system_accessor_id}

  # Ensures accessor_id is a valid UUID. Non-UUID strings (test stubs, opaque IDs)
  # fall back to the system sentinel so the NOT NULL constraint is satisfied.
  defp normalize_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> @system_accessor_id
    end
  end

  defp normalize_uuid(nil), do: @system_accessor_id
  defp normalize_uuid(id), do: id

  # ── Private: Helpers ─────────────────────────────────────────────────────────

  # Nil out encrypted_data before returning so callers never receive raw secrets.
  defp strip_encrypted(%Credential{} = credential) do
    %{credential | encrypted_data: nil}
  end

  defp duration_to_seconds({amount, unit}) when unit in [:day, :days], do: amount * 86_400
  defp duration_to_seconds({amount, unit}) when unit in [:hour, :hours], do: amount * 3_600
  defp duration_to_seconds({amount, unit}) when unit in [:minute, :minutes], do: amount * 60
  defp duration_to_seconds({amount, unit}) when unit in [:second, :seconds], do: amount
end

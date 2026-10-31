defmodule Platform.Vault do
  @moduledoc """
  General-purpose encrypted credential store.

  ## Authorization

  Every read and every mutation is checked against the credential's scope and
  any explicit `Platform.Vault.AccessGrant` rows, and every outcome — granted or
  denied — is written to the vault access log. That log outlives the credential
  it describes, including through `delete/2`; read it with `access_log/2`.

  **Read authority is not write authority.** Three permissions are recognised,
  sharing one vocabulary with `AccessGrant.permissions` and the action strings
  documented on `Platform.Vault.AccessLog`:

    * `:use`    — `get/2`, grant string `"use"`
    * `:rotate` — `rotate/3`, grant string `"rotate"`
    * `:revoke` — `delete/2`, grant string `"revoke"`

  Platform-scoped credentials stay readable by any accessor — the shared
  provider keys every agent depends on live there — but rotating or revoking one
  requires a privileged accessor (`{:system, _}` or `{:platform, _}`) or an
  explicit grant carrying the matching permission. Grants written before this
  vocabulary existed carry `["use"]` and therefore confer read only, which is
  the intended fail-closed default.

  ## Scopes

  `scope_type` is one of `"platform"`, `"agent"`, `"integration"`,
  `"shared"` or `"workspace"`. **New credentials should use `platform`,
  `agent` or `shared` scope.**

  `"shared"` scope holds secrets a human pasted in for named agents (the
  admin vault, `Platform.Vault.Shared`). It is the opposite of `platform`
  for reads: `:use` is granted ONLY by an explicit `AccessGrant` listing
  `"use"`, with no privileged bypass — `{:system, _}` and `{:platform, _}`
  cannot read a shared secret without a grant either. `:rotate` and
  `:revoke` follow the platform rule: a privileged accessor, or a grant
  carrying that permission. Who may read is decided by `scope_type` plus
  grant rows and never by `metadata`, which is a free-form map: wiping or
  rewriting it cannot widen access, because no clause reads it.

  `"workspace"` scope is deny-by-default for every permission, including `:use`
  and including the `{:system, _}` accessor. The only open path is an explicit
  `AccessGrant`. This is not a policy choice about workspaces; it is the absence
  of anything to check. There is no `workspaces` table — the vault's own
  migration carries `# TODO: add foreign key to workspaces once the workspaces
  table exists`, and `workspace_id` has never had a foreign key anywhere in the
  schema. There is no workspace-membership schema, and the live tenancy model
  (`Platform.Tenancy`, ADR-0042) relates orgs to *users*, while vault accessors
  are agents and integrations. Agent-to-org membership does not exist as a
  concept yet, so a real membership check cannot be written.

  The `workspace_id` column is vestigial scaffolding and the agreed direction is
  to delete it outright in follow-up work. Failing closed is the interim state
  until then; it costs nothing today because no production code creates a
  workspace-scoped credential.

  ### The escape hatch is temporary

      config :platform, Platform.Vault, allow_unscoped_workspace_access: true

  restores the pre-fix permissive behaviour verbatim — every accessor (including
  a `nil` one) and every permission — and logs a warning naming the slug and
  accessor on each use. It exists so a deployment that turns up an undiscovered
  dependent can roll forward instead of reverting the gate. It is **not** an
  operational knob and **not** a permission model, and it is expected to be
  removed together with the `workspace_id` column. If you are reading this after
  that column is gone, this flag should have gone with it.

  ## Named system readers

  A grant row's `grantee_id` is a uuid, so `{:system, "<name>"}` could never
  match one. `system_principals/0` gives each named in-BEAM system reader a
  fixed uuid; a grant with `grantee_type: "system"` and that uuid is honoured
  for exactly that accessor, and its access-log rows carry that uuid instead
  of the anonymous system sentinel. Grants are written and removed like agent
  grants, by a root admin through `Platform.Vault.Shared`
  (`grant_system/3`, `revoke_system_grant/3`), with an `update` log row each.

    * `"installs-provisioner"` — `Platform.Installs.DigitalOcean` reading
      the shared `digital-ocean-api-infra` token (task 01a18f0c stage 1).

  ## Known limit

  The accessor tuple is caller-asserted, not cryptographically bound — any
  in-BEAM caller can pass `{:system, nil}`. This closes "anyone who knows a slug
  can destroy it" and makes destructive intent explicit and auditable; it is not
  a capability boundary against a hostile in-process caller. Binding caller
  identity at the MCP/LiveView/channel edge is separate work.
  """

  import Ecto.Query

  require Logger

  # Ecto's query log (level :debug) renders `cast_params`, which for the
  # Cloak-typed `encrypted_data` field is the PLAINTEXT secret
  # (ecto_sql `Ecto.Adapters.SQL.log/4`: `opts[:cast_params] || params`).
  # Prod logs at :info so it is not emitted there, but dev, a debug-level
  # prod, and any test that lowers the level would write the value to the
  # server log. Every write carrying `encrypted_data` passes this.
  @no_query_log [log: false]

  alias Platform.Repo
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.AccessLog
  alias Platform.Vault.Credential

  # Sentinel UUID used when the accessor is anonymous/system (accessor_id NOT NULL in DB).
  @system_accessor_id "00000000-0000-0000-0000-000000000000"

  # Named system readers -> their fixed grantee uuid (moduledoc "Named system
  # readers"). Never reuse or change a uuid: grant and log rows hold it.
  @system_principals %{"installs-provisioner" => "e3ee1349-ca10-46f7-aaa9-65205a820f86"}

  @doc "Named system readers and their fixed grantee uuids (see the moduledoc)."
  @spec system_principals() :: %{String.t() => String.t()}
  def system_principals, do: @system_principals

  # Accessor types allowed to mutate platform-scoped credentials without a grant.
  @privileged_accessor_types ~w(system platform)

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
      metadata: with_fingerprint(Keyword.get(opts, :metadata, %{}), value),
      expires_at: Keyword.get(opts, :expires_at),
      workspace_id: Keyword.get(opts, :workspace_id)
    }

    # `log: false` on every write that carries `encrypted_data`: Ecto's :debug
    # query log prints CAST params, i.e. the plaintext, not the ciphertext
    # (task 01a131c5 stage 2 measured it on the dev rig). See @no_query_log.
    with {:ok, credential} <-
           %Credential{} |> Credential.changeset(attrs) |> Repo.insert(@no_query_log) do
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
  Idempotent inline credential upsert keyed by `vault_key`.

  Accepts a `{vault_key, secret}` pair from form submission and encrypts via
  Cloak through `Platform.Vault.EncryptedBinary`. If a row already exists at
  `slug=vault_key, scope_type="platform", scope_id=nil`, its encrypted value is
  replaced and `rotated_at` is bumped — otherwise a new row is inserted.

  This is the create-or-rotate path the inline-credential form needs:
  re-submitting the same `vault_key` MUST NOT collide on the
  `vault_credentials_unique_slug_per_scope` constraint that `put/4` would hit.

  Defaults the row to `credential_type="api_key"`, `scope={:platform, nil}`,
  `name=vault_key`, `provider="external_agent"` so vault-list UIs can filter
  inline-created credentials apart from first-class ones.

  Emits `[:platform, :vault, :credential_created]` on insert and
  `[:platform, :vault, :credential_rotated]` on update — reuses the existing
  telemetry surface.
  """
  @spec put_inline(String.t(), binary()) ::
          {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def put_inline(vault_key, secret) when is_binary(vault_key) and is_binary(secret) do
    now = DateTime.utc_now()

    lookup =
      from(c in Credential,
        where: c.slug == ^vault_key and c.scope_type == "platform" and is_nil(c.scope_id),
        limit: 1
      )

    result =
      Repo.transaction(fn ->
        case Repo.one(lookup) do
          nil ->
            attrs = %{
              slug: vault_key,
              credential_type: "api_key",
              encrypted_data: secret,
              scope_type: "platform",
              scope_id: nil,
              name: vault_key,
              provider: "external_agent",
              metadata: with_fingerprint(%{}, secret)
            }

            case %Credential{} |> Credential.changeset(attrs) |> Repo.insert(@no_query_log) do
              {:ok, inserted} -> {:inserted, inserted}
              {:error, changeset} -> Repo.rollback(changeset)
            end

          existing ->
            case existing
                 |> Credential.changeset(%{
                   encrypted_data: secret,
                   rotated_at: now,
                   metadata: with_fingerprint(existing.metadata, secret)
                 })
                 |> Repo.update(@no_query_log) do
              {:ok, updated} -> {:updated, updated}
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)

    case result do
      {:ok, {:inserted, credential}} ->
        :telemetry.execute(
          [:platform, :vault, :credential_created],
          %{system_time: System.system_time()},
          %{credential_id: credential.id, slug: vault_key, scope_type: "platform"}
        )

        {:ok, strip_encrypted(credential)}

      {:ok, {:updated, credential}} ->
        :telemetry.execute(
          [:platform, :vault, :credential_rotated],
          %{system_time: System.system_time()},
          %{credential_id: credential.id, slug: vault_key}
        )

        {:ok, strip_encrypted(credential)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Retrieve and decrypt a credential by slug.

  Requires the `:use` permission: platform-scoped credentials are readable by
  any accessor, otherwise the accessor must own the credential's scope or hold
  a grant listing `"use"`. Every call — granted or denied — is written to the
  vault access log.

  ## Options

    * `:accessor`     - `{accessor_type, accessor_id}` tuple identifying the requester
    * `:scope`        - `{scope_type, scope_id}` naming the credential exactly.
                        Optional. Without it the lookup matches on slug alone,
                        and a slug living at two scopes is refused — see
                        `rotate/3`.
    * `:workspace_id` - workspace context (used to narrow the lookup)
    * `:log_metadata` - map merged into the access-log row this call writes
                        on success (e.g. which fetch ticket redeemed it).
                        Default `%{}`. Never put a value in it.
  """
  @spec get(String.t(), keyword()) ::
          {:ok, binary()} | {:error, :not_found | :ambiguous_slug | :access_denied}
  def get(slug, opts \\ []) do
    accessor = Keyword.get(opts, :accessor)

    case resolve_one_by_slug(slug, opts) do
      {:error, :not_found} -> {:error, :not_found}
      {:error, :ambiguous_slug} -> refuse_ambiguous(slug, opts, "read")
      {:ok, cred} -> use_credential(cred, slug, accessor, Keyword.get(opts, :log_metadata, %{}))
    end
  end

  @doc """
  Retrieve and decrypt a credential by slug, **refusing an ambiguous slug**.

  Same options, same `:use` authorization, same access-log row, the same
  `last_used_at` bump and the same `[:platform, :vault, :credential_used]`
  telemetry as `get/2`. Target selection is now identical too: both resolve
  exactly as `rotate/3` does and return `{:error, :ambiguous_slug}` for two or
  more matches — decrypting nothing, bumping nothing, and logging a warning
  that names the matching scopes (never a value). `get_unique/2` exists as an
  explicit name for that same behaviour, for callers who want the refusal
  spelled out at the call site; either function works.

  Pass `:scope` to name the credential exactly.

  ## Options

    * `:accessor`     - `{accessor_type, accessor_id}` tuple identifying the requester
    * `:scope`        - `{scope_type, scope_id}` naming the credential exactly
    * `:workspace_id` - workspace context (used to narrow the lookup)
  """
  @spec get_unique(String.t(), keyword()) ::
          {:ok, binary()} | {:error, :not_found | :ambiguous_slug | :access_denied}
  def get_unique(slug, opts \\ []) do
    accessor = Keyword.get(opts, :accessor)

    case resolve_one_by_slug(slug, opts) do
      {:error, :not_found} -> {:error, :not_found}
      {:error, :ambiguous_slug} -> refuse_ambiguous(slug, opts, "read")
      {:ok, cred} -> use_credential(cred, slug, accessor, Keyword.get(opts, :log_metadata, %{}))
    end
  end

  # The granted/denied tail shared by get/2 and get_unique/2. Target selection
  # is the caller's; everything after it must stay identical between the two.
  defp use_credential(%Credential{} = cred, slug, accessor, log_metadata) do
    case check_access(cred, accessor, :use) do
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

        log_access(cred, accessor, "use", log_metadata)

        {:ok, updated.encrypted_data}

      {:error, :access_denied} ->
        deny(cred, slug, accessor)
    end
  end

  @doc """
  Decide whether `accessor` holds `permission` on the credential at `slug`,
  without returning its value.

  Same resolution as `get/2` (pass `:scope` to name the credential exactly;
  an ambiguous slug is refused) and the same `check_access/3` decision. A
  refusal emits `[:platform, :vault, :access_denied]` and writes a `"denied"`
  access-log row, exactly like a refused `get/2`. A grant writes NO log row
  and bumps nothing — the caller records what it did with the decision via
  `record_access/4`.

  Returns the credential with `encrypted_data` stripped. The row is loaded
  through the schema, so Cloak does decrypt it in memory on load; it is
  dropped before this function returns.
  """
  @spec authorize(String.t(), term(), :use | :rotate | :revoke, keyword()) ::
          {:ok, Credential.t()} | {:error, :not_found | :ambiguous_slug | :access_denied}
  def authorize(slug, accessor, permission, opts \\ [])
      when permission in [:use, :rotate, :revoke] do
    case resolve_one_by_slug(slug, opts) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :ambiguous_slug} ->
        refuse_ambiguous(slug, opts, to_string(permission))

      {:ok, cred} ->
        case check_access(cred, accessor, permission) do
          :ok -> {:ok, strip_encrypted(cred)}
          {:error, :access_denied} -> deny(cred, slug, accessor)
        end
    end
  end

  @doc """
  Append one access-log row for `credential`. No authorization: the caller
  has already made the decision this row records (a ticket issued after
  `authorize/4`, a grant added by a root admin). `action` must be one of the
  strings documented on `Platform.Vault.AccessLog`. `metadata` must never
  carry a value.
  """
  @spec record_access(Credential.t(), term(), String.t(), map()) ::
          {:ok, AccessLog.t()} | {:error, term()}
  def record_access(%Credential{} = credential, accessor, action, metadata)
      when action in ~w(use read create update rotate revoke denied) and is_map(metadata) do
    log_access(credential, accessor, action, metadata)
  end

  @doc """
  The display fingerprint of a value: `"sha256 .."` plus the last four hex
  digits of its SHA-256. Display-only — it plays no part in access control.
  Stored as `metadata["fingerprint"]` by `put/4`, `put_inline/2` and
  `rotate/3`.
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(value) when is_binary(value) do
    hex = :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
    "sha256 .." <> binary_part(hex, byte_size(hex) - 4, 4)
  end

  defp with_fingerprint(metadata, value) when is_binary(value) do
    Map.put(metadata || %{}, "fingerprint", fingerprint(value))
  end

  defp with_fingerprint(metadata, _value), do: metadata

  @doc """
  Atomically replace a credential's encrypted value.

  Requires the `:rotate` permission. Reading a credential does not confer the
  authority to overwrite it: on a platform-scoped credential the accessor must
  be privileged (`{:system, _}` or `{:platform, _}`) or hold a grant listing
  `"rotate"`; on an agent- or integration-scoped credential it must own the
  scope or hold such a grant. A refused rotation mutates nothing, emits
  `[:platform, :vault, :access_denied]` and writes a `"denied"` access-log row.

  ## A slug alone does not name a credential

  Uniqueness is per scope — `vault_credentials_unique_slug_per_scope` covers
  `(workspace_id, scope_type, scope_id, slug)` — so the same slug legitimately
  exists at more than one scope. A slug-only lookup with `limit: 1` and no
  `order_by` therefore has no defined target: it returns whichever row the
  planner happens to reach first, which in practice is insertion order.

  Until `20260829140000_enforce_vault_slug_uniqueness_across_null_scopes` that
  index was `NULLS DISTINCT` over two nullable columns, so a slug could also
  repeat *within* one scope — twice at `{:platform, nil}`, and in fact at any
  scope, since nothing populates `workspace_id`. It is now `NULLS NOT
  DISTINCT`, so ambiguity is once again only across scopes. Rows that predate
  the migration were parked under `__dup_`-suffixed slugs rather than deleted,
  so a slug that used to be ambiguous within its scope now resolves.

  ### The uniqueness-constraint question is settled — no new migration here

  Task 019f9cb8 stage 3 (Part C) re-checked this deliberately, because it is
  the kind of thing that looks unfinished from a support ticket alone: a
  slug (`t3`) with two rows in production. `check_access/3`'s per-scope
  dispatch above and `scope_type`/`scope_id` being independent namespaces (see
  the moduledoc's "Scopes" section) are BY DESIGN — the same slug legitimately
  exists at more than one scope at once, on purpose, not as a defect.

  `20260829140000_enforce_vault_slug_uniqueness_across_null_scopes` already
  ships the correct constraint for that design:
  `vault_credentials_unique_slug_per_scope` on
  `(workspace_id, scope_type, scope_id, slug)`, `NULLS NOT DISTINCT`, live on
  `main`. It already parks pre-existing same-scope duplicates under
  `__dup_`-suffixed slugs rather than deleting them, and it is re-runnable —
  it already satisfies "don't ship blind." Prod's two `t3` rows do not
  violate this constraint; they coexist at different scopes, which the schema
  intentionally permits. There is nothing here for a new migration to fix.
  The bug that ticket was really describing was `get/2`/`delete/2` resolving a
  slug alone while ignoring scope — that is the defect this task's stages 1-2
  fixed (see `resolve_one_by_slug/2` below).

  Rotation is what you run *because* a key leaked, so picking arbitrarily is
  the worst available behaviour — it leaves the compromised value live and
  overwrites an unrelated integration, both silently. Instead:

    * pass `:scope` to name the credential exactly, in the shape `put/4` takes;
    * with no `:scope`, an ambiguous slug is **refused** with
      `{:error, :ambiguous_slug}` and nothing is mutated.

  `get/2`, `get_unique/2` and `delete/2` all now refuse an ambiguous slug the
  same way: `:scope` narrows it, and with no `:scope` the call returns
  `{:error, :ambiguous_slug}` rather than picking a row.

  ## Options

    * `:accessor`     - `{accessor_type, accessor_id}` performing the rotation
    * `:scope`        - `{scope_type, scope_id}` naming the credential to rotate.
                        Optional; omitting it means "the only credential with
                        this slug", and is refused if there is more than one.
    * `:workspace_id` - workspace context (used to narrow the lookup)
  """
  @spec rotate(String.t(), binary(), keyword()) ::
          {:ok, Credential.t()} | {:error, :not_found | :ambiguous_slug | :access_denied | any()}
  def rotate(slug, new_value, opts \\ []) do
    accessor = Keyword.get(opts, :accessor)

    case resolve_one_by_slug(slug, opts) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :ambiguous_slug} ->
        refuse_ambiguous(slug, opts, "rotate")

      {:ok, credential} ->
        case check_access(credential, accessor, :rotate) do
          {:error, :access_denied} ->
            deny(credential, slug, accessor)

          :ok ->
            do_rotate(credential, slug, new_value, accessor)
        end
    end
  end

  # Names the slug and the scopes it was found at so an operator mid-incident
  # can see why the call refused and which `:scope` to pass. `verb` is the
  # caller's ("rotate", "read"). No value — new or stored — is in scope here
  # and none must ever be: a refusal log line is exactly where a plaintext
  # secret would go unnoticed.
  defp refuse_ambiguous(slug, opts, verb) do
    scopes =
      slug
      |> slug_query(opts)
      |> Repo.all()
      |> Enum.map(&"#{&1.scope_type}:#{inspect(&1.scope_id)}")
      |> Enum.sort()
      |> Enum.join(", ")

    Logger.warning(
      "vault: refusing to #{verb} #{slug} — the slug matches more than one credential " <>
        "(#{scopes}). Pass :scope to name the one you mean. Nothing was read or changed."
    )

    {:error, :ambiguous_slug}
  end

  defp do_rotate(credential, slug, new_value, accessor) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        case credential
             |> Credential.changeset(%{
               encrypted_data: new_value,
               rotated_at: now,
               metadata: with_fingerprint(credential.metadata, new_value)
             })
             |> Repo.update(@no_query_log) do
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

        log_access(credential, accessor, "rotate", %{})

        {:ok, strip_encrypted(updated)}

      {:error, reason} ->
        {:error, reason}
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

  Requires the `:revoke` permission, which is separate from `:rotate` — the
  authority to replace a value does not imply the authority to destroy it. On a
  platform-scoped credential the accessor must be privileged (`{:system, _}` or
  `{:platform, _}`) or hold a grant listing `"revoke"`; on an agent- or
  integration-scoped credential it must own the scope or hold such a grant. A
  refused deletion destroys nothing, emits `[:platform, :vault, :access_denied]`
  and writes a `"denied"` access-log row.

  The credential and its access grants are destroyed; **the access log is
  retained**. A `"revoke"` entry is written inside the deleting transaction and
  survives it: the foreign key is `ON DELETE SET NULL`, so each retained row
  keeps its `credential_slug`, `credential_scope_type`, accessor and action with
  only `credential_id` nulled. Read the surviving history with `access_log/2`.

  ## Options

    * `:accessor`     - `{accessor_type, accessor_id}` performing the deletion
    * `:scope`        - `{scope_type, scope_id}` naming the credential exactly.
                        Optional. Without it the lookup matches on slug alone,
                        and a slug living at two scopes is refused — see
                        `rotate/3`.
    * `:workspace_id` - workspace context (used to narrow the lookup)
  """
  @spec delete(String.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, :not_found | :ambiguous_slug | :access_denied | any()}
  def delete(slug, opts \\ []) do
    accessor = Keyword.get(opts, :accessor)

    case resolve_one_by_slug(slug, opts) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :ambiguous_slug} ->
        refuse_ambiguous(slug, opts, "revoke")

      {:ok, credential} ->
        case check_access(credential, accessor, :revoke) do
          {:error, :access_denied} -> deny(credential, slug, accessor)
          :ok -> do_delete(credential, slug, accessor)
        end
    end
  end

  defp do_delete(credential, slug, accessor) do
    result =
      Repo.transaction(fn ->
        # Written INSIDE the transaction. Ordering no longer matters — the FK is
        # ON DELETE SET NULL, so this row outlives the credential and the
        # database nulls its credential_id a few statements below. Writing it
        # here rather than before the transaction means a rolled-back deletion
        # leaves no phantom "revoke" claiming a destruction that never happened.
        log_access(credential, accessor, "revoke", %{})

        # Grants ARE subordinate to the credential — unlike the log, they carry
        # no history worth keeping once the thing they authorize is gone. The DB
        # cascades them (on_delete: :delete_all); doing it explicitly is
        # harmless and keeps the intent visible at the call site.
        from(g in AccessGrant, where: g.credential_id == ^credential.id)
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

  @doc """
  Read a credential's access log, newest first.

  Takes a slug or a `%Platform.Vault.Credential{}`. The history outlives the
  credential — `delete/2` retains it with `credential_id` nulled — so the query
  matches on `credential_id` *or* the denormalised `credential_slug`, and a slug
  whose credential has been destroyed still returns its full trail, ending in
  the `"revoke"` entry that recorded the destruction.

  The union matters in both directions: matching only on `credential_id` would
  lose everything the moment the credential is deleted, and matching only on
  `credential_slug` would miss any row written before the denormalised columns
  existed and not caught by the backfill. Rows for a *re-created* credential at
  the same slug are returned too — that is deliberate, the slug is the audit
  subject — and the old ones are distinguishable by `credential_id` being nil.

  ## Options

    * `:limit` - maximum number of entries, default `100`
  """
  @spec access_log(String.t() | Credential.t(), keyword()) :: [AccessLog.t()]
  def access_log(credential_or_slug, opts \\ [])

  def access_log(%Credential{id: credential_id, slug: slug}, opts) do
    query_access_log(credential_id, slug, opts)
  end

  def access_log(slug, opts) when is_binary(slug) do
    credential_id =
      from(c in Credential, where: c.slug == ^slug, select: c.id, limit: 1)
      |> Repo.one()

    query_access_log(credential_id, slug, opts)
  end

  defp query_access_log(credential_id, slug, opts) do
    limit = Keyword.get(opts, :limit, 100)

    # id is a UUIDv7, so it breaks inserted_at ties in insertion order rather
    # than arbitrarily — entries written in the same microsecond (a delete
    # writes its "revoke" alongside whatever preceded it) still read back in the
    # order they happened.
    base = from(l in AccessLog, order_by: [desc: l.inserted_at, desc: l.id], limit: ^limit)

    base =
      if credential_id do
        where(base, [l], l.credential_slug == ^slug or l.credential_id == ^credential_id)
      else
        where(base, [l], l.credential_slug == ^slug)
      end

    Repo.all(base)
  end

  # ── Private: Lookup ──────────────────────────────────────────────────────────

  # Resolve a slug to exactly ONE credential, or say why not. Fetches two rows
  # so "more than one" is a fact about the data rather than an inference from a
  # count query racing the read.
  defp resolve_one_by_slug(slug, opts) do
    case slug |> slug_query(opts) |> limit(2) |> Repo.all() do
      [] -> {:error, :not_found}
      [credential] -> {:ok, credential}
      [_, _] -> {:error, :ambiguous_slug}
    end
  end

  # Scope matching mirrors list/1's clauses exactly — `{scope_type, nil}` means
  # `IS NULL`, not `= NULL`, which would match nothing and read as :not_found.
  defp slug_query(slug, opts) do
    base = from(c in Credential, where: c.slug == ^slug)

    base =
      case Keyword.get(opts, :workspace_id) do
        nil -> base
        wid -> where(base, [c], c.workspace_id == ^wid)
      end

    case Keyword.get(opts, :scope) do
      nil ->
        base

      {scope_type, nil} ->
        where(base, [c], c.scope_type == ^to_string(scope_type) and is_nil(c.scope_id))

      {scope_type, scope_id} ->
        where(base, [c], c.scope_type == ^to_string(scope_type) and c.scope_id == ^scope_id)
    end
  end

  # ── Private: Access Control ──────────────────────────────────────────────────

  # `permission` is one of :use | :rotate | :revoke. See the moduledoc for the
  # shared vocabulary; grant_permission/1 maps it to the AccessGrant string.

  # Platform-scoped reads: accessible by any accessor. Unchanged — the shared
  # provider credentials every agent reads live at this scope.
  defp check_access(%Credential{scope_type: "platform"}, _accessor, :use), do: :ok

  # Platform-scoped writes: privileged accessors, or an explicit grant carrying
  # the permission. A nil/unknown accessor falls through to the catch-all deny —
  # {:system, nil} must be stated to be honoured, it is not the default.
  defp check_access(
         %Credential{scope_type: "platform"} = cred,
         {accessor_type, accessor_id},
         permission
       )
       when permission in [:rotate, :revoke] do
    if to_string(accessor_type) in @privileged_accessor_types do
      :ok
    else
      check_explicit_grant(cred, to_string(accessor_type), accessor_id, permission)
    end
  end

  # Shared-scoped reads: an explicit "use" grant, and nothing else. There is
  # deliberately NO privileged bypass — {:system, _} and {:platform, _} cannot
  # read a shared secret without a grant (the admin page never reads values).
  # Nothing here reads `metadata`, so no metadata write can widen this. A nil
  # or shapeless accessor does not match and falls to the deny-all below.
  defp check_access(
         %Credential{scope_type: "shared"} = cred,
         {accessor_type, accessor_id},
         :use
       ) do
    check_explicit_grant(cred, to_string(accessor_type), accessor_id, :use)
  end

  # Shared-scoped writes: same rule as the platform write clause above.
  defp check_access(
         %Credential{scope_type: "shared"} = cred,
         {accessor_type, accessor_id},
         permission
       )
       when permission in [:rotate, :revoke] do
    if to_string(accessor_type) in @privileged_accessor_types do
      :ok
    else
      check_explicit_grant(cred, to_string(accessor_type), accessor_id, permission)
    end
  end

  # Workspace-scoped: deny by default, for every permission and every accessor
  # type. There is no membership to evaluate — no `workspaces` table was ever
  # created, `workspace_id` has no foreign key anywhere, and org membership
  # (ADR-0042) relates users to orgs while vault accessors are agents and
  # integrations. An explicit AccessGrant is the only authorization signal that
  # actually exists at this scope, so it is the only open path. See the moduledoc:
  # the column is slated for deletion and this clause is the interim state.
  defp check_access(
         %Credential{scope_type: "workspace"} = cred,
         {accessor_type, accessor_id},
         permission
       ) do
    case check_explicit_grant(cred, to_string(accessor_type), accessor_id, permission) do
      :ok ->
        :ok

      {:error, :access_denied} ->
        workspace_escape_hatch(cred, {accessor_type, accessor_id}, permission)
    end
  end

  # Workspace-scoped with a nil or otherwise shapeless accessor: no grant row can
  # match it, so the escape hatch is all that is left. Matching on the accessor
  # SHAPE rather than on `parse_accessor/1`'s output is deliberate — parsing maps
  # nil to the same "system" string as {:system, nil} and would quietly make an
  # absent accessor privileged.
  defp check_access(%Credential{scope_type: "workspace"} = cred, accessor, permission) do
    workspace_escape_hatch(cred, accessor, permission)
  end

  # Agent-scoped: the owner holds full authority over its own credential.
  defp check_access(
         %Credential{scope_type: "agent", scope_id: scope_id} = cred,
         {:agent, accessor_id},
         permission
       ) do
    if scope_id == accessor_id do
      :ok
    else
      check_explicit_grant(cred, "agent", accessor_id, permission)
    end
  end

  # Integration-scoped: the owner holds full authority over its own credential.
  defp check_access(
         %Credential{scope_type: "integration", scope_id: scope_id} = cred,
         {:integration, accessor_id},
         permission
       ) do
    if scope_id == accessor_id do
      :ok
    else
      check_explicit_grant(cred, "integration", accessor_id, permission)
    end
  end

  # Cross-type access to restricted scopes: check explicit grants only.
  defp check_access(
         %Credential{scope_type: type} = cred,
         {accessor_type, accessor_id},
         permission
       )
       when type in ["agent", "integration"] do
    check_explicit_grant(cred, to_string(accessor_type), accessor_id, permission)
  end

  # All other cases (nil accessor, unknown accessor type): deny.
  defp check_access(_credential, _accessor, _permission), do: {:error, :access_denied}

  # A named system reader matches grant rows by its fixed uuid.
  defp check_explicit_grant(cred, "system", name, permission)
       when is_binary(name) and is_map_key(@system_principals, name) do
    check_explicit_grant(cred, "system", Map.fetch!(@system_principals, name), permission)
  end

  defp check_explicit_grant(%Credential{id: credential_id}, grantee_type, grantee_id, permission) do
    # A grantee_id that is not a UUID can never match a grant row, and handing it
    # to the query would raise rather than deny. Fail closed instead.
    #
    # Platform.UUID.cast/1, NOT Ecto.UUID.cast/1: a bare cast hex-encodes any
    # 16-byte binary into a well-formed but INVENTED uuid, which is then
    # COMPARED against real grant rows. Fail-closed only actually fails closed
    # with the strict predicate.
    case Platform.UUID.cast(grantee_id) do
      :error ->
        {:error, :access_denied}

      {:ok, grantee_uuid} ->
        required = grant_permission(permission)

        grant =
          from(g in AccessGrant,
            where:
              g.credential_id == ^credential_id and
                g.grantee_type == ^grantee_type and
                g.grantee_id == ^grantee_uuid and
                fragment("? = ANY(?)", ^required, g.permissions),
            limit: 1
          )
          |> Repo.one()

        if grant, do: :ok, else: {:error, :access_denied}
    end
  end

  # Temporary rollback switch for the workspace deny-by-default clause above.
  # Off by default; when on it restores the old permissive behaviour verbatim and
  # says so loudly, once per allowed access, naming the slug and the accessor so
  # the exception is greppable in logs. Expected to be deleted along with the
  # `workspace_id` column — see the moduledoc.
  defp workspace_escape_hatch(%Credential{} = cred, accessor, permission) do
    if Application.get_env(:platform, __MODULE__, [])[:allow_unscoped_workspace_access] do
      Logger.warning(
        "vault: allowing #{permission} on workspace-scoped credential #{cred.slug} for " <>
          "accessor #{inspect(accessor)} because :allow_unscoped_workspace_access is enabled. " <>
          "This escape hatch is temporary and goes away with the workspace_id column."
      )

      :ok
    else
      {:error, :access_denied}
    end
  end

  # Permission atom -> AccessGrant.permissions string. Deliberately shares the
  # dictionary with Platform.Vault.AccessLog's action strings.
  defp grant_permission(:use), do: "use"
  defp grant_permission(:rotate), do: "rotate"
  defp grant_permission(:revoke), do: "revoke"

  # ── Private: Audit Logging ───────────────────────────────────────────────────

  # Single refusal path shared by get/2, rotate/3 and delete/2. A refused
  # destructive attempt that leaves no trace would be a second bug, so every
  # denial emits telemetry AND writes a "denied" access-log row before returning.
  defp deny(%Credential{} = cred, slug, accessor) do
    :telemetry.execute(
      [:platform, :vault, :access_denied],
      %{system_time: System.system_time()},
      %{credential_id: cred.id, slug: slug, accessor: accessor}
    )

    log_access(cred, accessor, "denied", %{})

    {:error, :access_denied}
  end

  # Takes the whole credential, not just its id, so slug and scope can be
  # denormalised onto the row. The FK is ON DELETE SET NULL, so credential_id is
  # gone the moment the credential is destroyed and these copies are the only
  # thing that keeps a retained entry readable.
  #
  # Synchronous for v1 simplicity. Can be made async with Task.start + Sandbox.allow
  # for production hardening.
  defp log_access(%Credential{} = credential, accessor, action, metadata) do
    {accessor_type, accessor_id} = parse_accessor(accessor)

    Repo.insert(%AccessLog{
      credential_id: credential.id,
      credential_slug: credential.slug,
      credential_scope_type: credential.scope_type,
      accessor_type: accessor_type,
      accessor_id: accessor_id,
      action: action,
      metadata: metadata
    })
  end

  # Converts accessor tuple to {type_string, id_string}.
  # Falls back to a sentinel UUID for system/nil access (accessor_id NOT NULL in DB).
  defp parse_accessor({type, name})
       when type in [:system, "system"] and is_binary(name) and
              is_map_key(@system_principals, name),
       do: {"system", Map.fetch!(@system_principals, name)}

  defp parse_accessor({type, nil}) when is_atom(type), do: {to_string(type), @system_accessor_id}
  defp parse_accessor({type, id}) when is_atom(type), do: {to_string(type), normalize_uuid(id)}
  defp parse_accessor({type, nil}), do: {to_string(type), @system_accessor_id}
  defp parse_accessor({type, id}), do: {to_string(type), normalize_uuid(id)}
  defp parse_accessor(nil), do: {"system", @system_accessor_id}

  # Ensures accessor_id is a valid UUID. Non-UUID strings (test stubs, opaque IDs)
  # fall back to the system sentinel so the NOT NULL constraint is satisfied.
  #
  # Platform.UUID.cast/1, NOT Ecto.UUID.cast/1. This is a FABRICATED-VALUE
  # site, not a raise site: a bare cast turns a 16-byte accessor id into an
  # invented uuid that is then WRITTEN to the audit event's accessor_id
  # column — a real-looking actor belonging to nobody. Nothing raises, so an
  # assert_raise-shaped test cannot catch a regression; assert the sentinel.
  defp normalize_uuid(id) when is_binary(id) do
    case Platform.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> @system_accessor_id
    end
  end

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

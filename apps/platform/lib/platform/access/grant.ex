defmodule Platform.Access.Grant do
  @moduledoc """
  One explicit allow or deny of one permission on one resource for one
  principal (task 01a1386d-e528 stage 2,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`).

    * `principal_type` — `"user"` or `"agent"` (with `principal_id`) or
      `"role"` (with `principal_role_key`, a key of `access_roles`). A role
      row applies to every holder of that role key in the row's `org_id`.
    * `resource_type` — `"project"`, `"space"`, `"canvas"` or
      `"memory_node"`. A memory row names an `org_memory_nodes.id`, never a
      path (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`).
    * `effect` — `"allow"` or `"deny"`.

  ## Module locks (task 01a14721 stage 2)

  A row with `resource_type: "module"` is a MODULE LOCK: it locks its
  principal out of a whole module. Its `permission` is a `Registry.modules/0`
  `:module` name (`"tasks"`, `"files"`), not a `module.action`; its
  `resource_id` is the org the lock is scoped to and equals its `org_id`; its
  `effect` is always `"deny"` (an allow on a module would widen past role
  rules, so the changeset and the `access_grants_module_deny_check` CHECK
  refuse it). Every permission of a locked module evaluates false for the
  principal everywhere (`Platform.Access.locked?/2`). `install`, `orgs` and
  `mcp` are not lockable (not grantable, or derived), nor is `access`
  (locking it would bypass the last-manager guard): `lockable_modules/0`.

  `permission` must be declared in `Platform.Access.Registry`. Install-level
  permissions (`install.admin`) and derived permissions (`orgs.read`) are
  refused: no grant may name either.

  This schema compares nothing. Precedence lives only in `Platform.Access`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Access.Registry

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @principal_types ~w(user role agent)
  @resource_types ~w(project space canvas memory_node module)
  @unlockable_modules ~w(install orgs mcp access)
  @effects ~w(allow deny)

  @type t :: %__MODULE__{}

  schema "access_grants" do
    belongs_to(:org, Platform.Tenancy.Org)
    field(:principal_type, :string)
    field(:principal_id, :binary_id)
    field(:principal_role_key, :string)
    field(:permission, :string)
    field(:resource_type, :string)
    field(:resource_id, :binary_id)
    field(:effect, :string)
    field(:granted_by, :binary_id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The principal types a grant may name."
  @spec principal_types() :: [String.t()]
  def principal_types, do: @principal_types

  @doc "The resource types a grant may name."
  @spec resource_types() :: [String.t()]
  def resource_types, do: @resource_types

  @doc """
  The module names a module lock may name: every `Registry.modules/0`
  `:module` (extensions included, read per call) except `install`, `orgs`,
  `mcp` and `access`.
  """
  @spec lockable_modules() :: [String.t()]
  def lockable_modules do
    for %{module: module} <- Registry.modules(),
        module not in @unlockable_modules,
        uniq: true,
        do: module
  end

  @doc "May a module lock name `module`?"
  @spec lockable_module?(term()) :: boolean()
  def lockable_module?(module) when is_binary(module), do: module in lockable_modules()
  def lockable_module?(_), do: false

  @doc "Is `grant` (a struct or a `snapshot/1` map) a module lock?"
  @spec module_lock?(t() | map()) :: boolean()
  def module_lock?(%__MODULE__{resource_type: "module"}), do: true
  def module_lock?(%{"resource_type" => "module"}), do: true
  def module_lock?(_), do: false

  @doc "The grant's resource as `{type_atom, id}` (a module lock: `{:module, org_id}`)."
  @spec target(t()) :: {atom(), binary()}
  def target(%__MODULE__{resource_type: type, resource_id: id}),
    do: {String.to_existing_atom(type), id}

  @snapshot_fields ~w(id org_id principal_type principal_id principal_role_key permission
                      resource_type resource_id effect granted_by inserted_at)a

  @doc """
  Every column of `grant` as a JSON-safe, string-keyed map (task
  01a1386e-30bd stage 1). `Platform.Access.Changes` stores these in the
  ledger's `before` / `after`, and `from_snapshot/1` restores one losslessly:
  the same id, effect, principal, resource, `granted_by` and `inserted_at`
  (microseconds included).
  """
  @spec snapshot(t()) :: %{String.t() => term()}
  def snapshot(%__MODULE__{} = grant) do
    Map.new(@snapshot_fields, fn
      :inserted_at -> {"inserted_at", grant.inserted_at && DateTime.to_iso8601(grant.inserted_at)}
      field -> {Atom.to_string(field), Map.fetch!(grant, field)}
    end)
  end

  @doc """
  The `Repo.insert_all/3` row for a `snapshot/1` map: every column, typed.
  The inverse of `snapshot/1`.
  """
  @spec from_snapshot(%{String.t() => term()}) :: keyword()
  def from_snapshot(%{} = snapshot) do
    Enum.map(@snapshot_fields, fn
      :inserted_at ->
        {:ok, at, 0} = DateTime.from_iso8601(Map.fetch!(snapshot, "inserted_at"))
        {:inserted_at, at}

      field ->
        {field, Map.fetch!(snapshot, Atom.to_string(field))}
    end)
  end

  @doc """
  The (principal, permission, resource) tuple of a grant or a `snapshot/1`
  map, as the string the ledger's `tuple_keys` stores. The access_grants
  unique index is over exactly this tuple, so one key names at most one row.
  """
  @spec tuple_key(t() | map()) :: String.t()
  def tuple_key(%__MODULE__{} = grant), do: grant |> snapshot() |> tuple_key()

  def tuple_key(%{"principal_type" => type} = snap) do
    principal = snap["principal_id"] || snap["principal_role_key"]

    Enum.join(
      [type, principal, snap["permission"], snap["resource_type"], snap["resource_id"]],
      "|"
    )
  end

  @doc false
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :org_id,
      :principal_type,
      :principal_id,
      :principal_role_key,
      :permission,
      :resource_type,
      :resource_id,
      :effect,
      :granted_by
    ])
    |> validate_required([:org_id, :principal_type, :permission, :resource_type, :resource_id])
    |> validate_required([:effect])
    |> validate_inclusion(:principal_type, @principal_types)
    |> validate_inclusion(:resource_type, @resource_types)
    |> validate_inclusion(:effect, @effects)
    |> validate_principal()
    |> validate_permission()
    |> validate_module_lock()
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:principal_role_key)
    |> check_constraint(:principal_id, name: :access_grants_principal_check)
    |> check_constraint(:resource_type, name: :access_grants_resource_type_check)
    |> check_constraint(:effect, name: :access_grants_module_deny_check)
    |> unique_constraint([:principal_type, :principal_id, :permission, :resource_id],
      name: :access_grants_tuple_index,
      message: "this principal already holds a grant or deny for this permission and resource"
    )
  end

  defp validate_principal(changeset) do
    case get_field(changeset, :principal_type) do
      "role" ->
        changeset
        |> validate_required([:principal_role_key])
        |> validate_absent(:principal_id)

      type when type in ["user", "agent"] ->
        changeset
        |> validate_required([:principal_id])
        |> validate_absent(:principal_role_key)

      _ ->
        changeset
    end
  end

  defp validate_absent(changeset, field) do
    if is_nil(get_field(changeset, field)),
      do: changeset,
      else: add_error(changeset, field, "must be empty for this principal type")
  end

  defp validate_permission(changeset) do
    module? = get_field(changeset, :resource_type) == "module"

    validate_change(changeset, :permission, fn :permission, permission ->
      cond do
        module? and lockable_module?(permission) ->
          []

        module? ->
          [permission: "is not a lockable module"]

        not Registry.permission?(permission) ->
          [permission: "is not a declared permission"]

        Registry.install_level?(permission) ->
          [permission: "is install-level and cannot be granted"]

        Registry.derived?(permission) ->
          [permission: "is derived from memberships and cannot be granted"]

        true ->
          []
      end
    end)
  end

  # A module lock is a deny scoped to its own org: `resource_id` is the org
  # and equals `org_id`.
  defp validate_module_lock(changeset) do
    if get_field(changeset, :resource_type) == "module" do
      changeset
      |> then(fn cs ->
        if get_field(cs, :effect) in [nil, "deny"],
          do: cs,
          else: add_error(cs, :effect, "a module lock must be a deny")
      end)
      |> then(fn cs ->
        if get_field(cs, :resource_id) == get_field(cs, :org_id),
          do: cs,
          else: add_error(cs, :resource_id, "a module lock names its own org")
      end)
    else
      changeset
    end
  end
end

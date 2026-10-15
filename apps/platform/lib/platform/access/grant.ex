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
  @resource_types ~w(project space canvas memory_node)
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

  @doc "The grant's resource as `{type_atom, id}`."
  @spec target(t()) :: {atom(), binary()}
  def target(%__MODULE__{resource_type: type, resource_id: id}),
    do: {String.to_existing_atom(type), id}

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
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:principal_role_key)
    |> check_constraint(:principal_id, name: :access_grants_principal_check)
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
    validate_change(changeset, :permission, fn :permission, permission ->
      cond do
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
end

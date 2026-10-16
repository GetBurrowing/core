defmodule Platform.Access.RoleAssignment do
  @moduledoc """
  Ecto schema for `access_role_assignments` (task `01a1386e-59d1` stage 1,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`): one
  principal holding one CUSTOM role in one org.

    * `principal_type` — `user` or `agent`; `principal_id` is the user id or
      the agent id (not the runtime id).
    * `role_key` — a custom `access_roles.key`. Built-in roles are never
      assigned here: the base role comes from the membership's generated
      `access_role_key`.
    * `source` — `manual` (written through `Platform.Access.Roles.assign/1`)
      or `idp` (written by the IdP group sync, stage 3). The sync never
      touches `manual` rows.

  Written through `Platform.Access.Roles` only. Read by
  `Platform.Access.Scope` (in the same query as the actor's grants) and
  nowhere outside `Platform.Access`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @principal_types ~w(user agent)
  @sources ~w(manual idp)

  @type t :: %__MODULE__{}

  schema "access_role_assignments" do
    belongs_to(:org, Platform.Tenancy.Org)
    field(:principal_type, :string)
    field(:principal_id, :binary_id)
    field(:role_key, :string)
    field(:source, :string, default: "manual")

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The principal types an assignment may name."
  @spec principal_types() :: [String.t()]
  def principal_types, do: @principal_types

  @doc "The sources an assignment may carry."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Changeset."
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:org_id, :principal_type, :principal_id, :role_key, :source])
    |> validate_required([:org_id, :principal_type, :principal_id, :role_key, :source])
    |> validate_inclusion(:principal_type, @principal_types)
    |> validate_inclusion(:source, @sources)
    |> unique_constraint([:org_id, :principal_type, :principal_id, :role_key, :source],
      name: :access_role_assignments_tuple_index
    )
    |> foreign_key_constraint(:role_key)
    |> foreign_key_constraint(:org_id)
  end
end

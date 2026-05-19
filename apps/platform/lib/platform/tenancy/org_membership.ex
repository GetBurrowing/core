defmodule Platform.Tenancy.OrgMembership do
  @moduledoc """
  Ecto schema for `org_memberships` — joins a user to an org with a role.

  See `Platform.Tenancy` for the context module.

  ## Roles

  `role` is a string with values constrained at the DB level (CHECK
  constraint `org_memberships_role_check`) and at the changeset level
  (`validate_inclusion`). Canonical values:

    * `"admin"` — full admin within the org.
    * `"member"` — default. Read/write within the org, no admin ops.

  Edit `@roles` here and the CHECK constraint in
  `priv/repo/migrations/.._create_org_memberships.exs` together — they
  must stay in sync.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(admin member)

  schema "org_memberships" do
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:org, Platform.Tenancy.Org)

    field(:role, :string)

    timestamps()
  end

  @doc "Canonical list of role values (mirrors the DB CHECK constraint)."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :org_id, :role])
    |> validate_required([:user_id, :org_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :org_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:org_id)
  end
end

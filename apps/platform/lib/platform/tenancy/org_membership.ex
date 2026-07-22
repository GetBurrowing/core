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

  ## External marker (orthogonal to role)

  `external` is an ADDITIVE boolean flag, **not** a third role value. It
  is the privilege-orthogonal segregation marker for external users:

    * `role` answers "how much privilege?" (`admin | member`).
    * `external` answers "is this an external (non-tenant-native)
      participant?" (`true | false`, default `false`).

  A scoped external user is a `member`-level participant in allowlisted
  spaces that additionally carries `external: true`; downstream stack
  members (M6/M7/M8) enforce the segregation. Modelling the two axes
  independently keeps 'external admin' expressible and avoids widening
  `org_memberships_role_check`. The self-healing email-domain machinery
  (`derive_role_from_email/1`, `apply_derived_role/1`) never touches
  `external` — it is set only via `Platform.Tenancy.mark_membership_external/1`
  and the pending-grant apply path.
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
    # Orthogonal external-user marker (stack member 1, rbac-external-users).
    # NOT a role value — see the "External marker" section in @moduledoc.
    field(:external, :boolean, default: false)
    # When set, the self-healing hook in `Platform.Accounts` skips
    # evaluation for this row — manual grant wins. See Stage 3 migration
    # `20260519220000_add_roles_locked_at_to_org_memberships.exs`.
    field(:roles_locked_at, :utc_datetime_usec)

    timestamps()
  end

  @doc "Canonical list of role values (mirrors the DB CHECK constraint)."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :org_id, :role, :external, :roles_locked_at])
    |> validate_required([:user_id, :org_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :org_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:org_id)
  end
end

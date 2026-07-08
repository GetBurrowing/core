defmodule Platform.Roles.Role do
  @moduledoc """
  Schema for the `roles` table — the platform-fixed registry of agent
  roles (M4 stage 1 of task 019ef65b-a361).

  A role pins together a stable identifier, presentation metadata, and
  (via `role_responsibilities`) the bundle of responsibility keys the
  role fulfills.

    * `key` — the natural primary key. One of the closed enum
      `designer | historian | meeting_scribe | meeting_producer |
      triage_officer | security_guard | architect` (stack decision #2:
      role roster is fixed by the platform, not user-extensible).
      Enforced by both the changeset and a DB CHECK constraint,
      mirroring `org_memberships.role`. `architect` was added in
      ADR-0044 stage 1 (task `019f3da3`) as the closed-roster owner of
      the three `architecture.*` responsibility keys.
    * `name` — human-presentable label.
    * `description` — one-line explanation of what the role owns.
    * `icon` — hero-icon slug (e.g. `hero-paint-brush`).

  `has_many :role_responsibilities` exposes the bundle for callers that
  want the join rows directly; the `Platform.Roles` context (Stage 3)
  is the canonical surface for `bundle_for/1` lookups.

  Only the schema and changeset live here — the context module,
  resolver, and seeding all land in later stages of M4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Roles.RoleResponsibility

  @primary_key {:key, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :key}
  @foreign_key_type :string

  @valid_keys ~w(designer historian meeting_scribe meeting_producer triage_officer security_guard architect)

  schema "roles" do
    field(:name, :string)
    field(:description, :string)
    field(:icon, :string)

    has_many(:role_responsibilities, RoleResponsibility,
      foreign_key: :role_key,
      references: :key
    )

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid `key` values. Exposed for use by stage 4's
  seed module so the canonical roster isn't string-duplicated.
  """
  def valid_keys, do: @valid_keys

  @cast_fields ~w(key name description icon)a
  @required_fields ~w(key name description icon)a

  @doc """
  Changeset for inserting or updating a role.

  Validates required fields, `key` membership in the closed enum, and
  attaches a unique constraint on `key` so duplicate inserts surface as
  a changeset error rather than a Postgrex raise.
  """
  def changeset(role, attrs) do
    role
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:key, @valid_keys)
    |> unique_constraint(:key, name: :roles_pkey)
  end
end

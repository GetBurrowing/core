defmodule Platform.Roles.RoleResponsibility do
  @moduledoc """
  Schema for the `role_responsibilities` join table — pairs a
  `Platform.Roles.Role` (by natural key) with a responsibility key drawn
  from the M1 `responsibilities` registry.

  Decision context (M4 stage 1, task 019ef65b-a361):

    * `responsibility_key` is intentionally a bare string column rather
      than a hard FK to `responsibilities(key)`. M1 has shipped on main,
      but seeding ordering between M4 and M1 is fragile during fresh
      rebuilds; a follow-up can layer the FK once M1's seed list is
      canonized.
    * Stage 4's seeds use `on_conflict: :nothing, conflict_target:
      [:role_key, :responsibility_key]` against the
      `role_responsibilities_pair_idx` unique index so re-runs are
      idempotent.

  The changeset validates required keys plus the `role_key` enum so
  bad data can't slip in through callers that don't go through
  `Platform.Roles` (the context module lands in Stage 3).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Roles.Role

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "role_responsibilities" do
    field(:responsibility_key, :string)

    belongs_to(:role, Role,
      foreign_key: :role_key,
      references: :key,
      type: :string
    )

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(role_key responsibility_key)a
  @required_fields ~w(role_key responsibility_key)a

  @doc """
  Changeset for inserting a role↔responsibility pair.

  Validates required fields, `role_key` membership in the closed
  `Role.valid_keys/0` enum, and attaches the unique constraint on the
  `(role_key, responsibility_key)` pair so duplicate inserts surface as
  a changeset error.
  """
  def changeset(role_responsibility, attrs) do
    role_responsibility
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role_key, Role.valid_keys())
    |> unique_constraint([:role_key, :responsibility_key],
      name: :role_responsibilities_pair_idx
    )
    |> foreign_key_constraint(:role_key)
  end
end

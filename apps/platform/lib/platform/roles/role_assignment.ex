defmodule Platform.Roles.RoleAssignment do
  @moduledoc """
  Schema for the `role_assignments` table — pins exactly one agent to
  each platform-defined role (M4 stage 2 of task 019ef65b-a361).

  Decision context:

    * `role_key` is a natural FK against `roles(key)` (the stage-1
      table uses the closed-enum text as its primary key). A unique
      index on `role_key` enforces Decision 1 from the stack: a role
      maps 1:1 to an agent, no shared ownership. Re-assigning a role
      is therefore an update of the existing row, not an insert of a
      second one.

    * `agent_id` is a hard FK to `agents(id)` with delete-cascade so
      removing an agent transparently clears its assignment.

  The `unique_constraint/3` on `role_key` surfaces a duplicate-insert
  attempt as a changeset error (rather than a Postgrex raise) which
  the stage-3 resolver / context module will translate into
  `{:error, :already_assigned}`.

  Only the schema and changeset live here — the `Platform.Roles`
  context module + resolver land in stage 3.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Agents.Agent
  alias Platform.Roles.Role

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "role_assignments" do
    belongs_to(:role, Role,
      foreign_key: :role_key,
      references: :key,
      type: :string
    )

    belongs_to(:agent, Agent)

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(role_key agent_id)a
  @required_fields ~w(role_key agent_id)a

  @doc """
  Changeset for inserting or updating a role assignment.

  Validates required fields, the `role_key` enum, and attaches both
  unique + FK constraints so DB-level errors come back as changeset
  errors rather than raises.
  """
  def changeset(role_assignment, attrs) do
    role_assignment
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role_key, Role.valid_keys())
    |> unique_constraint(:role_key,
      name: :role_assignments_role_key_index,
      message: "role already assigned"
    )
    |> foreign_key_constraint(:role_key)
    |> foreign_key_constraint(:agent_id)
  end
end

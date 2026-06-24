defmodule Platform.Roles.ResponsibilityOverride do
  @moduledoc """
  Schema for the `responsibility_overrides` table — per-responsibility
  deviation from the role-bundle defaults (M4 stage 2 of task
  019ef65b-a361).

  Decision context:

    * Decision 3 from the stack: at most one override per
      responsibility key. Enforced by `unique_constraint(:responsibility_key)`
      against the `responsibility_overrides_responsibility_key_index`
      DB unique index.

    * Mirroring `role_responsibilities` from stage 1, the
      `responsibility_key` column stays a bare string with no hard FK
      against M1's `responsibilities(key)`. M1 has shipped but the
      seed-ordering coupling is deferred until M1's roster is
      canonized; the stage-3 resolver returns the override agent
      whenever the row exists and falls back to the role bundle
      otherwise.

    * `agent_id` is a hard FK to `agents(id)` with delete-cascade so
      removing an agent transparently clears any overrides it owned.

  Only the schema and changeset live here — the `Platform.Roles`
  context + resolver land in stage 3.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Agents.Agent

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "responsibility_overrides" do
    field(:responsibility_key, :string)

    belongs_to(:agent, Agent)

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(responsibility_key agent_id)a
  @required_fields ~w(responsibility_key agent_id)a

  @doc """
  Changeset for inserting or updating a responsibility override.

  Validates required fields and attaches both unique and FK
  constraints so DB-level errors surface as changeset errors.
  """
  def changeset(override, attrs) do
    override
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:responsibility_key,
      name: :responsibility_overrides_responsibility_key_index,
      message: "responsibility already overridden"
    )
    |> foreign_key_constraint(:agent_id)
  end
end

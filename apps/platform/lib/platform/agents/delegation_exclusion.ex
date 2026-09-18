defmodule Platform.Agents.DelegationExclusion do
  @moduledoc """
  Schema for `agent_delegation_exclusions` — a stored REASON an agent is
  not delegated work (task `01a0b491-0718-7001-8bba-bf50f119bb13` stage 2).

  ## The row is the reason, not the exclusion

  There is no boolean anywhere in this table. The presence of a row is
  the exclusion; `reason_kind` and `reason` are why. The two agents
  excluded today are excluded for different causes — one a capability
  judgement, one a role conflict — and a flag that merged them would
  answer "is this agent delegatable" while destroying the only thing a
  future reader needs in order to change the answer responsibly.

  ## `reason_kind` is an open column with a closed validation

  The DB column is a plain `:string` with no CHECK constraint;
  `validate_inclusion/3` here pins it to `@reason_kinds`. A third cause is
  therefore a code change somebody has to justify in review rather than
  free text that drifts, and it is never a prod insert that blows up
  against a constraint nobody can amend without a migration.

  `validate_length(:reason, min: 20)` exists so nobody stores "no". A
  reason short enough to be a verdict is a verdict, and a verdict is the
  boolean this table refuses to keep.

  `decided_by` records WHO made the judgement, in the same row. An
  exclusion whose author is unknown cannot be appealed to anybody.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @reason_kinds ~w(capability_judgement role_conflict)

  schema "agent_delegation_exclusions" do
    field(:agent_id, :binary_id)
    field(:reason_kind, :string)
    field(:reason, :string)
    field(:decided_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The closed set of causes an exclusion may name.

  Exposed so callers and tests assert against this list rather than
  re-spelling the strings — a test that hard-codes the pair keeps passing
  after a third kind is added, which is the one change this set exists to
  make visible.
  """
  @spec reason_kinds() :: [String.t()]
  def reason_kinds, do: @reason_kinds

  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(exclusion, attrs) do
    exclusion
    |> cast(attrs, [:agent_id, :reason_kind, :reason, :decided_by])
    |> validate_required([:agent_id, :reason_kind, :reason, :decided_by])
    |> validate_inclusion(:reason_kind, @reason_kinds)
    |> validate_length(:reason, min: 20)
    |> unique_constraint(:agent_id)
    |> foreign_key_constraint(:agent_id)
  end
end

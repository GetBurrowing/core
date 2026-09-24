defmodule Platform.Experiments.SurfaceDefault do
  @moduledoc """
  One row of a surface's default history. Task 01a0d415, the
  experimentation-layer ADR-0052.

  For non-prompt surfaces, promotion does not rewrite a template row; it
  APPENDS a row here. The table is append-only: nothing updates a row in
  place, and a revert is a NEW row (`kind: "revert"`, `reverts_seq`) whose
  `payload` is the effective payload after the revert. `payload` NULL means
  "no default — use the surface's control".

  ## "The current default" is structural, not an ordering guess

  The current default for `(surface_key, surface_target, org_id)` is the row
  with MAX(`seq`). The unique index over
  `(surface_key, surface_target, org_id, seq)` is `NULLS NOT DISTINCT`, so two
  concurrent writers computing the same next `seq` for the install-wide key
  (`org_id` NULL) collide on the index instead of both inserting. Ordering by
  `inserted_at` instead would make two rows written in the same microsecond a
  tie broken by the planner.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(promote revert)
  @unique_index_name :experiment_surface_defaults_key_seq_index

  @type t :: %__MODULE__{}

  schema "experiment_surface_defaults" do
    field(:surface_key, :string)
    field(:surface_target, :string)
    belongs_to(:org, Platform.Tenancy.Org)
    field(:seq, :integer)
    field(:kind, :string)
    field(:payload, :map)
    belongs_to(:source_experiment, Platform.Experiments.Experiment)
    field(:reverts_seq, :integer)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Name of the NULLS NOT DISTINCT history index."
  @spec unique_index_name() :: atom()
  def unique_index_name, do: @unique_index_name

  @doc "Builds a changeset for a history row. Rows are inserted, never updated."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :surface_key,
      :surface_target,
      :org_id,
      :seq,
      :kind,
      :payload,
      :source_experiment_id,
      :reverts_seq
    ])
    |> validate_required([:surface_key, :surface_target, :seq, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:seq, greater_than: 0)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:source_experiment_id)
    |> unique_constraint(:seq, name: @unique_index_name)
  end
end

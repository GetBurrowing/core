defmodule Platform.Experiments.Assignment do
  @moduledoc """
  Which variant a subject got, and when. Task 019fe6b9, ADR-0048.

  ## Written once, never recomputed

  The unique index on `(experiment_id, subject_type, subject_id)` is what
  makes an assignment sticky, and stickiness is the whole point of storing
  assignments at all. Without it a single task gets variant A at planning
  and variant B at execution — a contamination NO downstream metric can
  detect, because both rows look perfectly legitimate on their own.

  `changeset/2` carries the matching `unique_constraint/3` so a racing
  insert surfaces as a changeset error rather than a raised
  `Ecto.ConstraintError`, letting the writer re-read and return the winning
  row.

  ## Exclusions carry a reason and are NEVER deleted

  There is no `delete_assignment` in this codebase and none may be added. A
  subject that must leave the analysis sets `excluded_reason` and the ROW
  STAYS. A subject dropped from the denominator with no record is how a
  result quietly becomes wrong: the numbers still add up, the exclusion is
  invisible, and nobody can tell an honest filter from a thumb on the scale.

  ## `subject_id` is a plain `:uuid`

  Deliberately not a foreign key. The subject is a `task_id` today, but
  dispatch-level subjects must work later without a migration, so
  `subject_type` stays generic and there is no single parent table to
  constrain against. Same reasoning as `inbox_items.source_id`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Platform.Experiments.Experiment

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  # Must match the explicitly-pinned index name in the migration. Ecto's
  # derived default for these three columns is 66 bytes and Postgres truncates
  # identifiers at 63, so the derived name does not exist in the database and a
  # constraint declared under it would never match.
  @unique_index_name :experiment_assignments_subject_unique_index

  @type t :: %__MODULE__{}

  schema "experiment_assignments" do
    field(:subject_type, :string)
    field(:subject_id, Ecto.UUID)
    field(:variant_slug, :string)
    field(:assigned_at, :utc_datetime_usec)
    field(:excluded_reason, :string)

    belongs_to(:experiment, Experiment)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Name of the stickiness index, so writers can match on it explicitly."
  @spec unique_index_name() :: atom()
  def unique_index_name, do: @unique_index_name

  @doc """
  Builds a changeset for an assignment.

  `excluded_reason` is castable but never required: an assignment is created
  without one and gains one only if the subject is later excluded.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :experiment_id,
      :subject_type,
      :subject_id,
      :variant_slug,
      :assigned_at,
      :excluded_reason
    ])
    |> validate_required([
      :experiment_id,
      :subject_type,
      :subject_id,
      :variant_slug,
      :assigned_at
    ])
    |> foreign_key_constraint(:experiment_id)
    |> unique_constraint(:subject_id, name: @unique_index_name)
  end
end

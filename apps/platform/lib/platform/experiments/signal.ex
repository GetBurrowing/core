defmodule Platform.Experiments.Signal do
  @moduledoc """
  One observed outcome for an experiment. Task 01a0d415, the
  experimentation-layer ADR-0052.

  A signal is what an outcome metric counts: a labelled reading of some
  source (a reply, an event) for one subject. Three facts about the shape are
  load-bearing:

    * `subject_id` is NULLABLE. A source that could not be matched to a
      subject is RECORDED, not dropped — an unmatched reply is evidence about
      the matcher, and dropping it would make the matcher's failure rate
      invisible.
    * `label` NULL means unlabelled. `status` says why:
      `labelled | unlabelled | rejected_output` (the last is a labeler output
      that failed validation and was refused, not coerced).
    * The unique index on `(experiment_id, source_type, source_id)` makes
      recording idempotent. None of those columns is nullable, so the NULLS
      DISTINCT hazard does not arise here.

  There is no delete function for signals anywhere, and none may be added.

  `inserted_at` is castable so an importer can record WHEN a source was
  observed rather than when it was written; outcome windows count from it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Platform.Experiments.Experiment

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(labelled unlabelled rejected_output)
  @unique_index_name :experiment_signals_source_unique_index

  @type t :: %__MODULE__{}

  schema "experiment_signals" do
    belongs_to(:experiment, Experiment)
    field(:subject_type, :string)
    field(:subject_id, Ecto.UUID)
    field(:label, :string)
    field(:confidence, :float)
    field(:reason, :string)
    field(:source_type, :string)
    field(:source_id, :string)
    field(:labeler, :string)
    field(:status, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Valid signal statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Name of the idempotency index."
  @spec unique_index_name() :: atom()
  def unique_index_name, do: @unique_index_name

  @doc """
  Builds a changeset for a signal.

  A `labelled` signal must carry a label; an `unlabelled` one must not.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(signal, attrs) do
    signal
    |> cast(attrs, [
      :experiment_id,
      :subject_type,
      :subject_id,
      :label,
      :confidence,
      :reason,
      :source_type,
      :source_id,
      :labeler,
      :status,
      :inserted_at
    ])
    |> validate_required([:experiment_id, :subject_type, :source_type, :source_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_label_matches_status()
    |> foreign_key_constraint(:experiment_id)
    |> unique_constraint([:experiment_id, :source_type, :source_id], name: @unique_index_name)
  end

  defp validate_label_matches_status(changeset) do
    case {get_field(changeset, :status), get_field(changeset, :label)} do
      {"labelled", nil} ->
        add_error(changeset, :label, "is required for a labelled signal")

      {"unlabelled", label} when not is_nil(label) ->
        add_error(changeset, :label, "must be empty for an unlabelled signal")

      _ ->
        changeset
    end
  end
end

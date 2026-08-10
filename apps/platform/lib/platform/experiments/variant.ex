defmodule Platform.Experiments.Variant do
  @moduledoc """
  One arm of an experiment: a slug, a traffic weight, and the prompt itself.
  Task 019fe6b9, ADR-0048.

  ## Variants carry the FULL prompt blob, not a structured overlay

  Recorded here so it is not re-litigated. `content` is the entire prompt as
  it would be dispatched, not a patch, diff, or set of field overrides
  applied to some base template at read time.

  Why the blob wins: it is exactly what was dispatched, so a result stays
  reproducible from the row alone, months later, by anyone. An overlay
  reconstructs the prompt at read time from whatever the composition rules
  say *then* — so any later change to those rules silently rewrites the
  history of every finished experiment, and every past result quietly
  becomes a claim about a prompt that was never actually sent. The overlay
  form was considered and rejected deliberately per ADR-0048.

  The cost is duplication between variants. That is the intended trade: disk
  is cheap and an unreproducible experiment is worthless.

  ## The control is a row here

  The variant with slug `"control"` holds a SNAPSHOT of
  `prompt_templates.content` taken at activation. It is not a pointer at the
  live template. Editing the template mid-experiment must not be able to
  move the control out from under a running comparison.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Platform.Experiments.Experiment

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "experiment_variants" do
    field(:slug, :string)
    field(:content, :string)
    field(:weight, :integer, default: 1)

    belongs_to(:experiment, Experiment)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds a changeset for a variant."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(variant, attrs) do
    variant
    |> cast(attrs, [:experiment_id, :slug, :content, :weight])
    |> validate_required([:experiment_id, :slug, :content, :weight])
    |> validate_number(:weight, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:experiment_id)
    |> unique_constraint([:experiment_id, :slug],
      name: :experiment_variants_experiment_id_slug_index
    )
  end
end

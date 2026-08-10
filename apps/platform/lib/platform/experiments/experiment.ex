defmodule Platform.Experiments.Experiment do
  @moduledoc """
  A prompt experiment: a hypothesis, the metric that decides it, and a
  lifecycle. Task 019fe6b9, ADR-0048.

  ## Status is a real lifecycle, and `stopped` is not `concluded`

  The four statuses are `draft | running | stopped | concluded`, and
  **`stopped` and `concluded` are DIFFERENT statuses that both stay
  visible.** Nothing — no query, no changeset, no default, no listing —
  may collapse one onto the other or filter `stopped` out.

  An experiment that made things worse is a row worth keeping; it is often
  the most instructive one on the page. A codebase that quietly drops its
  failures keeps only the results that flattered it, and the record stops
  being evidence.

  ## The control-variant guard lives here, not in the context

  `changeset/2` REFUSES a transition to `running` unless a variant row with
  slug `"control"` already exists for the experiment. This is enforced in
  Elixir at the changeset rather than by convention in
  `Platform.Experiments`, so that calling the changeset directly and
  inserting via `Repo` cannot produce a running experiment without a
  control.

  The reason it must hold at this level: per ADR-0048 the control is a
  variant ROW carrying a snapshot of the prompt, not an implicit pointer at
  the live `prompt_templates.content`. A running experiment with no control
  row has nothing to compare against, and the comparison degrades with no
  error anywhere — exactly the failure this guard exists to make loud.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Platform.Experiments.Variant

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft running stopped concluded)
  @control_slug "control"

  @type t :: %__MODULE__{}

  schema "experiments" do
    field(:slug, :string)
    field(:name, :string)
    field(:hypothesis, :string)
    field(:primary_metric, :string)
    field(:status, :string, default: "draft")
    field(:stop_rule, :map, default: %{})

    has_many(:variants, Variant, foreign_key: :experiment_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "All four valid statuses, in lifecycle order."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The slug that identifies the control variant."
  @spec control_slug() :: String.t()
  def control_slug, do: @control_slug

  @doc """
  Builds a changeset for an experiment.

  Refuses a transition to `running` when the experiment has no `control`
  variant row. See the moduledoc for why that guard lives here.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(experiment, attrs) do
    experiment
    |> cast(attrs, [:slug, :name, :hypothesis, :primary_metric, :status, :stop_rule])
    |> validate_required([:slug, :name, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:slug)
    |> validate_control_variant_for_running()
  end

  # The guard. Fires only when this changeset is the thing that moves the
  # experiment INTO `running`; re-saving an already-running experiment for an
  # unrelated field change is not a transition and is not blocked.
  defp validate_control_variant_for_running(changeset) do
    if get_change(changeset, :status) == "running" do
      if has_control_variant?(changeset.data) do
        changeset
      else
        add_error(
          changeset,
          :status,
          "cannot move to running without a control variant; " <>
            "activation must snapshot the current prompt into a #{@control_slug} variant first"
        )
      end
    else
      changeset
    end
  end

  # Prefers an already-loaded association so a caller that preloaded pays no
  # second query; falls back to a direct count so the guard still holds when
  # the changeset is built from an unloaded struct. An experiment with no id
  # has not been inserted and therefore cannot have variants.
  defp has_control_variant?(%__MODULE__{variants: variants}) when is_list(variants) do
    Enum.any?(variants, &(&1.slug == @control_slug))
  end

  defp has_control_variant?(%__MODULE__{id: nil}), do: false

  defp has_control_variant?(%__MODULE__{id: id}) do
    Platform.Repo.exists?(
      from(v in Variant, where: v.experiment_id == ^id and v.slug == ^@control_slug)
    )
  end
end

defmodule Platform.Experiments.Goal do
  @moduledoc """
  A standing goal experiments are proposed against. Task 01a0d415, the
  experimentation-layer ADR-0052.

  `org_id` NULL is an install-wide goal; `project_id` NULL is org-wide. Many
  goals per org, and many install-wide goals, are legal — this is NOT a
  singleton table and carries no uniqueness on `org_id`. The
  install-wide-singleton rule (NULLS NOT DISTINCT) applies to
  `experiment_guardrails` and `experiment_surface_defaults` only; applying it
  here would make a second install-wide goal impossible.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Platform.Experiments.MetricKind

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active paused retired)

  @type t :: %__MODULE__{}

  schema "experiment_goals" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:project, Platform.Tasks.Project)
    field(:statement, :string)
    field(:metric_spec, :map, default: %{})
    field(:status, :string, default: "active")

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Valid goal statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Builds a changeset for a goal."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [:org_id, :project_id, :statement, :metric_spec, :status])
    |> validate_required([:statement, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_metric_spec()
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:project_id)
  end

  defp validate_metric_spec(changeset) do
    case get_change(changeset, :metric_spec) do
      nil ->
        changeset

      spec ->
        case MetricKind.validate_spec(spec) do
          :ok -> changeset
          {:error, reasons} -> Enum.reduce(reasons, changeset, &add_error(&2, :metric_spec, &1))
        end
    end
  end
end

defmodule Platform.Experiments.MetricKind do
  @moduledoc """
  A PARAMETERISED metric, instantiated as data. Task 01a0d415, the
  experimentation-layer ADR-0052.

  ADR-0048 made every metric a module in the `@registry` of
  `Platform.Experiments.Metrics`, so a new measurement needed a deploy. A
  metric kind is a module written once; an experiment instantiates it with
  parameters in `experiments.metric_spec`:

      %{"kind" => "registered", "slug" => "cycle_time"}
      %{"kind" => "outcome_rate", "labels" => ["positive"], "window_days" => 7,
        "anchor" => "assigned_at"}
      %{"kind" => "duration_between", "from_status" => "planning",
        "to_status" => "in_progress"}

  The existing module registry IS the `registered` kind, so an experiment
  with an empty `metric_spec` and a `primary_metric` slug keeps computing
  exactly what it computed before (`Platform.Experiments.Metrics.compute_spec/2`).

  ## Parameters are validated when the spec is WRITTEN

  `validate_spec/1` runs from the experiment and goal changesets. An unknown
  kind or a bad parameter is a changeset error, never a runtime surprise on
  the results page.

  ## The ADR-0048 rules bind every kind

  Every kind returns `{:ok, %Platform.Experiments.Metric.Result{}}` — `n`
  always present — or `:insufficient_data`. An empty eligible population is
  `:insufficient_data`, never `0.0`. Excluded subjects leave both sides of
  every ratio.

  A kind with an observation window may instead return
  `{:insufficient_data, %{pending: k}}`, so the subjects still inside the
  window are reported on the insufficient row rather than dropped.
  """

  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Metric

  @doc "The kind name stored in `metric_spec[\"kind\"]`."
  @callback kind() :: String.t()

  @doc "Validates and normalises the spec's parameters (every key but `kind`)."
  @callback validate_params(params :: map()) :: {:ok, map()} | {:error, [String.t()]}

  @doc "Computes the metric for one variant, with validated parameters."
  @callback compute(Experiment.t(), variant_slug :: String.t(), params :: map()) ::
              result()

  @type result ::
          Metric.result() | {:insufficient_data, %{pending: non_neg_integer()}}

  @kinds [
    Platform.Experiments.MetricKinds.Registered,
    Platform.Experiments.MetricKinds.OutcomeRate,
    Platform.Experiments.MetricKinds.DurationBetween,
    # Task 01a114a8 stage 4: per-dispatch usage from DispatchMetrics.
    Platform.Experiments.MetricKinds.DispatchUsage
  ]

  @doc "Every registered metric kind module."
  @spec list() :: [module()]
  def list, do: @kinds

  @doc "The kind module for a name, or nil."
  @spec get(String.t() | nil) :: module() | nil
  def get(name) when is_binary(name), do: Enum.find(@kinds, &(&1.kind() == name))
  def get(_name), do: nil

  @doc """
  Parses a spec into `{:ok, module, params}` or `{:error, reasons}`. An empty
  spec is `:none`.
  """
  @spec parse(map() | nil) :: {:ok, module(), map()} | :none | {:error, [String.t()]}
  def parse(nil), do: :none
  def parse(spec) when is_map(spec) and map_size(spec) == 0, do: :none

  def parse(spec) when is_map(spec) do
    spec = Map.new(spec, fn {k, v} -> {to_string(k), v} end)
    {name, params} = Map.pop(spec, "kind")

    case get(name) do
      nil ->
        {:error,
         [
           "unknown metric kind #{inspect(name)}; known: " <>
             Enum.map_join(@kinds, ", ", & &1.kind())
         ]}

      module ->
        case module.validate_params(params) do
          {:ok, normalized} -> {:ok, module, normalized}
          {:error, reasons} -> {:error, reasons}
        end
    end
  end

  def parse(_other), do: {:error, ["metric_spec must be a map"]}

  @doc "`:ok` for an empty or valid spec, `{:error, reasons}` otherwise."
  @spec validate_spec(map() | nil) :: :ok | {:error, [String.t()]}
  def validate_spec(spec) do
    case parse(spec) do
      {:error, reasons} -> {:error, reasons}
      _ -> :ok
    end
  end

  @doc false
  # Shared by the kinds: refuses keys a kind does not know.
  @spec only_keys(String.t(), map(), [String.t()]) :: :ok | {:error, [String.t()]}
  def only_keys(kind, params, allowed) do
    case Map.keys(params) -- allowed do
      [] -> :ok
      unknown -> {:error, ["unknown #{kind} parameters: #{Enum.join(unknown, ", ")}"]}
    end
  end
end

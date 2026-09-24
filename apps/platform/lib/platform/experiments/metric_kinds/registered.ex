defmodule Platform.Experiments.MetricKinds.Registered do
  @moduledoc """
  The `registered` metric kind: one of the ADR-0048 metric modules, by slug.
  Task 01a0d415, the experimentation-layer ADR-0052.

  `%{"kind" => "registered", "slug" => slug}` delegates to
  `Platform.Experiments.Metrics.metric_module/1`. This is how the module
  registry becomes one kind among several without any existing experiment
  changing what it computes.
  """

  @behaviour Platform.Experiments.MetricKind

  alias Platform.Experiments.MetricKind
  alias Platform.Experiments.Metrics

  @impl true
  def kind, do: "registered"

  @impl true
  def validate_params(params) do
    with :ok <- MetricKind.only_keys(kind(), params, ["slug"]) do
      slug = Map.get(params, "slug")

      if is_binary(slug) and Metrics.metric_module(slug) != nil do
        {:ok, %{"slug" => slug}}
      else
        {:error,
         [
           "registered needs a known slug; got #{inspect(slug)}; known: " <>
             Enum.join(Metrics.known_metrics(), ", ")
         ]}
      end
    end
  end

  @impl true
  def compute(experiment, variant_slug, %{"slug" => slug}) do
    Metrics.metric_module(slug).compute(experiment.id, variant_slug)
  end
end

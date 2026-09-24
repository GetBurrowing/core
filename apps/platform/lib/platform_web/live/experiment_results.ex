defmodule PlatformWeb.ExperimentResults do
  @moduledoc """
  The web layer's name for `Platform.Experiments.Results`. Task 019fe6ba,
  ADR-0048; moved into the context by task 01a0d415 stage 2.

  Every function delegates. The implementation moved to core so the MCP tool
  `experiment_results` can serve the rows the page renders without core
  depending on the web layer; keeping this module as a pure delegate means
  `PlatformWeb.ExperimentsLive` and its tests call the same names they always
  did, and there is still exactly ONE definition of "earned".
  """

  alias Platform.Experiments.Results

  @doc "The metric slugs this UI can compute. Delegates to the context."
  defdelegate known_metrics(), to: Platform.Experiments.Metrics

  @doc "Resolves `primary_metric` to a module, or nil when unrecognised."
  defdelegate metric_module(slug), to: Platform.Experiments.Metrics

  @doc "See `Platform.Experiments.Results.min_subjects/1`."
  defdelegate min_subjects(experiment), to: Results

  @doc "See `Platform.Experiments.Results.stop_rule_label/1`."
  defdelegate stop_rule_label(experiment), to: Results

  @doc "See `Platform.Experiments.Results.rows/1`."
  defdelegate rows(experiment), to: Results

  @doc "See `Platform.Experiments.Results.headline_row/1`."
  defdelegate headline_row(experiment), to: Results

  @doc "See `Platform.Experiments.Results.confound/1`."
  defdelegate confound(row), to: Results

  @doc "See `Platform.Experiments.Results.figure/1`."
  defdelegate figure(row), to: Results

  @doc "See `Platform.Experiments.Results.unit_label/1`."
  defdelegate unit_label(unit), to: Results
end

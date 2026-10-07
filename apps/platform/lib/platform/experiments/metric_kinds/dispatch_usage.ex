defmodule Platform.Experiments.MetricKinds.DispatchUsage do
  @moduledoc """
  The `dispatch_usage` metric kind (task 01a114a8 stage 4): one per-dispatch
  field from `Platform.Orchestration.DispatchMetrics`, aggregated over every
  dispatch of an arm's assigned, non-excluded tasks.

      %{"kind" => "dispatch_usage", "field" => "suite_tool_calls", "agg" => "median"}

  ## Fields

    * `suite_tool_calls` — model-issued Suite tool calls (server-side, exact).
    * `client_turns`, `client_tokens_in`, `client_tokens_out` — client
      self-report from `agent_usage_events`. A dispatch with no report has
      nil here and is LEFT OUT of both the value and `n`; it is never read
      as 0.
    * `wall_ms` — dispatch wall time. A still-running dispatch has nil.
    * `outcome_first_pass` — 1.0 when the dispatch's stage `passed` with no
      `failed` validation and no re-dispatch, 0.0 when its stage ended any
      other way, nil while the stage is still running. A `stage_row`
      dispatch (a runtime that never acked) has a nil `re_dispatch_count`,
      so a re-dispatch of it cannot be seen; its outcome rests on the stage
      and validation status alone. `agg: mean` is the first-pass rate.

  ## What `n` counts

  DISPATCHES carrying the field, not tasks: a task with three stages
  contributes up to three. `n` travels with every result, and an arm where
  no dispatch carries the field is `:insufficient_data`, never `0.0`
  (ADR 0052 section 7).

  ## The population

  Every dispatch of every task the arm assigned, whoever the dispatched
  agent was: `Platform.Experiments.Results.by_agent/1` is the per-agent
  split. Planning dispatches are not units in `DispatchMetrics` (they carry
  no stage and arm no lease), so they are not counted.
  """

  @behaviour Platform.Experiments.MetricKind

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.MetricKind
  alias Platform.Orchestration.DispatchMetrics
  alias Platform.Repo

  @fields ~w(suite_tool_calls client_turns client_tokens_in client_tokens_out wall_ms outcome_first_pass)
  @aggs ~w(mean median)

  @doc "The fields this kind can aggregate."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @impl true
  def kind, do: "dispatch_usage"

  @impl true
  def validate_params(params) do
    with :ok <- MetricKind.only_keys(kind(), params, ["field", "agg"]) do
      field = Map.get(params, "field")
      agg = Map.get(params, "agg", "mean")

      errors =
        if(field in @fields,
          do: [],
          else: ["dispatch_usage field must be one of: #{Enum.join(@fields, ", ")}"]
        ) ++
          if(agg in @aggs,
            do: [],
            else: ["dispatch_usage agg must be one of: #{Enum.join(@aggs, ", ")}"]
          )

      case errors do
        [] -> {:ok, %{"field" => field, "agg" => agg}}
        errors -> {:error, errors}
      end
    end
  end

  @impl true
  def compute(experiment, variant_slug, %{"field" => field, "agg" => agg}) do
    task_ids =
      Repo.all(
        from(a in Assignment,
          where:
            a.experiment_id == ^experiment.id and a.variant_slug == ^variant_slug and
              a.subject_type == "task" and is_nil(a.excluded_reason),
          select: a.subject_id
        )
      )

    task_ids
    |> DispatchMetrics.for_tasks()
    |> aggregate(field, agg)
  end

  @doc """
  Aggregates `field` over enriched dispatch rows. Pure: shared with
  `Platform.Experiments.Results.by_agent/1`, so the per-agent figures and
  the arm figure are one computation.

  Returns `{:ok, %Result{}}` or `:insufficient_data` when no row carries the
  field.
  """
  @spec aggregate([map()], String.t(), String.t()) ::
          {:ok, Result.t()} | :insufficient_data
  def aggregate(dispatches, field, agg) when field in @fields and agg in @aggs do
    case dispatches |> Enum.map(&value(&1, field)) |> Enum.filter(&is_number/1) do
      [] ->
        :insufficient_data

      values ->
        {:ok, %Result{value: reduce(values, agg), n: length(values), unit: unit(field)}}
    end
  end

  @doc "One dispatch row's value for `field`, or nil when it is not measured."
  @spec value(map(), String.t()) :: number() | nil
  def value(dispatch, "outcome_first_pass"), do: first_pass(dispatch)
  def value(dispatch, field) when field in @fields, do: Map.get(dispatch, String.to_atom(field))

  defp first_pass(%{stage_status: "passed"} = dispatch) do
    failed = dispatch |> Map.get(:validations, %{}) |> Map.get("failed", 0)

    if failed == 0 and (Map.get(dispatch, :re_dispatch_count) || 0) == 0, do: 1.0, else: 0.0
  end

  defp first_pass(%{stage_status: status}) when status in ~w(failed skipped), do: 0.0
  defp first_pass(_dispatch), do: nil

  defp reduce(values, "mean"), do: Enum.sum(values) / length(values)

  defp reduce(values, "median") do
    sorted = Enum.sort(values)
    count = length(sorted)
    mid = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, mid) / 1,
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp unit("outcome_first_pass"), do: :ratio
  defp unit("wall_ms"), do: :milliseconds
  defp unit(_field), do: :count
end

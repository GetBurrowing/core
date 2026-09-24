defmodule Platform.Experiments.MetricKinds.DurationBetween do
  @moduledoc """
  The `duration_between` metric kind. Task 01a0d415, the experimentation-layer
  ADR-0052.

      %{"kind" => "duration_between", "from_status" => "planning",
        "to_status" => "in_progress"}

  Mean seconds from the moment a task ENTERED `from_status` to the first
  later moment it entered `to_status`, read from `task_phase_transitions`,
  over a variant's non-excluded subjects.

  Mirrors `Platform.Experiments.Metrics.CycleTime`:

    * a subject with NO transition rows is dropped from the sample, not
      counted as zero seconds (older, uninstrumented tasks would otherwise
      make whichever arm holds more of them look faster);
    * an OPEN interval — entered `from_status`, never reached `to_status` —
      is excluded, because it would be measured against the clock and drift
      between two reads.

  ## What `n` counts: TASKS with a closed interval

  An empty sample is `:insufficient_data`, never `0.0`.
  """

  @behaviour Platform.Experiments.MetricKind

  import Ecto.Query

  alias Platform.Experiments.MetricKind
  alias Platform.Experiments.Metrics
  alias Platform.Repo
  alias Platform.Tasks.PhaseTransition

  @impl true
  def kind, do: "duration_between"

  @impl true
  def validate_params(params) do
    with :ok <- MetricKind.only_keys(kind(), params, ["from_status", "to_status"]) do
      from = Map.get(params, "from_status")
      to = Map.get(params, "to_status")

      cond do
        not (is_binary(from) and from != "" and is_binary(to) and to != "") ->
          {:error, ["duration_between needs non-empty from_status and to_status"]}

        from == to ->
          {:error, ["duration_between from_status and to_status must differ"]}

        true ->
          {:ok, %{"from_status" => from, "to_status" => to}}
      end
    end
  end

  @impl true
  def compute(experiment, variant_slug, %{"from_status" => from, "to_status" => to}) do
    case Metrics.subject_ids(experiment.id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        subject_ids
        |> Enum.flat_map(&interval_seconds(&1, from, to))
        |> Metrics.mean(:seconds)
    end
  end

  # A list of nought or one element: a task with no closed interval
  # disappears from the sample rather than contributing a value.
  defp interval_seconds(task_id, from, to) do
    rows =
      Repo.all(
        from(t in PhaseTransition,
          where: t.task_id == ^task_id and t.to_status in [^from, ^to],
          order_by: [asc: t.occurred_at],
          select: {t.to_status, t.occurred_at}
        )
      )

    with {entered_at, rest} <- first_entry(rows, from),
         {_status, reached_at} <- Enum.find(rest, fn {status, _at} -> status == to end) do
      [DateTime.diff(reached_at, entered_at, :microsecond) / 1_000_000]
    else
      _ -> []
    end
  end

  defp first_entry(rows, from) do
    case Enum.drop_while(rows, fn {status, _at} -> status != from end) do
      [{_status, at} | rest] -> {at, rest}
      [] -> nil
    end
  end
end

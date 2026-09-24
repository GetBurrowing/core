defmodule Platform.Experiments.MetricKinds.OutcomeRate do
  @moduledoc """
  The `outcome_rate` metric kind. Task 01a0d415, the experimentation-layer ADR-0052.

      %{"kind" => "outcome_rate", "labels" => ["positive"], "window_days" => 7,
        "anchor" => "assigned_at"}

  The share of ELIGIBLE, non-excluded subjects in a variant with at least one
  `labelled` signal whose label is in `labels`, observed within
  `window_days` of the subject's anchor.

  ## The observation window: young subjects are PENDING, not failures

  A subject is eligible only once its anchor is older than `window_days`.
  Younger subjects have not had the chance to produce an outcome, so they are
  counted in `Result.pending` and are in NEITHER the numerator NOR `n`.
  Scoring them as non-responses would bias every rate toward zero, and most
  strongly for the arm that was assigned most recently — an effect that looks
  exactly like the treatment doing worse.

  An empty eligible set is insufficient data, never `0.0` — including when
  every subject is still pending. It is returned as
  `{:insufficient_data, %{pending: k}}` so the pending count survives to the
  results row: an arm whose only subjects are inside the window must read
  "k pending", not "0 pending".

  `anchor` is `"assigned_at"` (the assignment row's timestamp) and nothing
  else today; the parameter exists so a later anchor is a new value, not a
  new kind.

  ## What `n` counts: eligible, non-excluded SUBJECTS

  Excluded subjects leave both sides of the ratio, as in every ADR-0048
  metric.
  """

  @behaviour Platform.Experiments.MetricKind

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.MetricKind
  alias Platform.Experiments.Signal
  alias Platform.Repo

  @anchors ["assigned_at"]

  @impl true
  def kind, do: "outcome_rate"

  @impl true
  def validate_params(params) do
    with :ok <- MetricKind.only_keys(kind(), params, ["labels", "window_days", "anchor"]) do
      labels = Map.get(params, "labels")
      window = Map.get(params, "window_days")
      anchor = Map.get(params, "anchor", "assigned_at")

      errors =
        []
        |> check(
          is_list(labels) and labels != [] and Enum.all?(labels, &is_binary/1),
          "outcome_rate needs a non-empty labels list of strings"
        )
        |> check(
          is_integer(window) and window > 0,
          "outcome_rate needs a positive integer window_days"
        )
        |> check(
          anchor in @anchors,
          "outcome_rate anchor must be one of: #{Enum.join(@anchors, ", ")}"
        )

      case errors do
        [] -> {:ok, %{"labels" => labels, "window_days" => window, "anchor" => anchor}}
        errors -> {:error, Enum.reverse(errors)}
      end
    end
  end

  defp check(errors, true, _message), do: errors
  defp check(errors, false, message), do: [message | errors]

  @impl true
  def compute(experiment, variant_slug, %{"labels" => labels, "window_days" => window}) do
    cutoff = DateTime.add(DateTime.utc_now(), -window * 86_400, :second)

    assignments =
      Repo.all(
        from(a in Assignment,
          where:
            a.experiment_id == ^experiment.id and a.variant_slug == ^variant_slug and
              is_nil(a.excluded_reason),
          select: {a.subject_type, a.subject_id, a.assigned_at}
        )
      )

    {eligible, pending} =
      Enum.split_with(assignments, fn {_type, _id, at} -> DateTime.compare(at, cutoff) != :gt end)

    case eligible do
      [] ->
        {:insufficient_data, %{pending: length(pending)}}

      eligible ->
        positives = Enum.count(eligible, &positive?(experiment.id, &1, labels, window))
        n = length(eligible)

        {:ok, %Result{value: positives / n, n: n, unit: :ratio, pending: length(pending)}}
    end
  end

  defp positive?(experiment_id, {subject_type, subject_id, assigned_at}, labels, window) do
    window_end = DateTime.add(assigned_at, window * 86_400, :second)

    Repo.exists?(
      from(s in Signal,
        where:
          s.experiment_id == ^experiment_id and s.subject_type == ^subject_type and
            s.subject_id == ^subject_id and s.status == "labelled" and s.label in ^labels and
            s.inserted_at >= ^assigned_at and s.inserted_at <= ^window_end
      )
    )
  end
end

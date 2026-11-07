defmodule Platform.Experiments.Metrics.PrefillAcceptRate do
  @moduledoc """
  Share of JUDGED pre-fills a user accepted rather than overrode, over a
  variant's assigned users. Task 01a1b6a1 stage 1, for the
  `habits.learned_defaults` surface (`0061-learned-defaults.md` § 6).

  `accepted / (accepted + overridden)`, over `habit_signals` rows at rung
  `prefill` for the surface's target action, written by the arm's assigned
  users at or after their assignment.

  ## What `n` counts: judged PRE-FILLS

  `n` is accepted + overridden pre-fill signals. An `ignored` pre-fill (the
  picker closed with no pick) is in neither side: nobody judged it, and
  counting it as a rejection would drag the rate toward zero for whichever
  arm pre-fills more often. `chosen` signals had no pre-fill shown and are
  not at rung `prefill`.

  ## `pending` (ADR 0052 rules 6 and 7)

  An assigned user who has not yet judged a pre-fill has not had the chance
  to produce an outcome. Such users are reported as `pending` and are in
  neither the value nor `n`. With no judged pre-fill at all the result is
  `{:insufficient_data, %{pending: k}}` (or bare `:insufficient_data` when
  the arm has no assigned users), never `0.0`.

  ## Subjects

  The variant's `"user"` assignments, not task assignments, so this does not
  use `Metrics.subject_ids/2` (task-only by design). Excluded subjects leave
  both sides.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.MetricKind
  alias Platform.Habits.Signal
  alias Platform.Repo

  @subject_type "user"
  @action "chat.message_attention"
  @judged ~w(accepted overridden)

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: MetricKind.result()
  def compute(experiment_id, variant_slug) do
    assignments =
      Repo.all(
        from(a in Assignment,
          where:
            a.experiment_id == ^experiment_id and a.variant_slug == ^variant_slug and
              a.subject_type == ^@subject_type and is_nil(a.excluded_reason),
          select: {a.subject_id, a.assigned_at}
        )
      )

    case assignments do
      [] -> :insufficient_data
      assignments -> assignments |> judged_outcomes() |> rate(length(assignments))
    end
  end

  # {user_id, outcome} for every judged pre-fill signal written by an
  # assigned user at or after that user's assignment.
  defp judged_outcomes(assignments) do
    ids = Enum.map(assignments, &elem(&1, 0))
    assigned_at = Map.new(assignments)

    Repo.all(
      from(s in Signal,
        where:
          s.actor_user_id in ^ids and s.action == ^@action and s.rung == "prefill" and
            s.outcome in ^@judged,
        select: {s.actor_user_id, s.outcome, s.inserted_at}
      )
    )
    |> Enum.filter(fn {user_id, _outcome, at} ->
      case Map.get(assigned_at, user_id) do
        nil -> false
        assigned -> DateTime.compare(at, assigned) != :lt
      end
    end)
    |> Enum.map(fn {user_id, outcome, _at} -> {user_id, outcome} end)
  end

  defp rate(outcomes, assigned_count) do
    judging_users = outcomes |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()
    pending = assigned_count - judging_users

    case length(outcomes) do
      0 ->
        {:insufficient_data, %{pending: pending}}

      n ->
        accepted = Enum.count(outcomes, fn {_user, outcome} -> outcome == "accepted" end)
        {:ok, %Result{value: accepted / n, n: n, unit: :ratio, pending: pending}}
    end
  end
end

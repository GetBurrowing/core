defmodule Platform.Experiments.Metrics.ManualGateRejectionRate do
  @moduledoc """
  Share of RESOLVED review requests in which a human asked for a revision,
  over a variant's subjects. Task 01a00b91.

  `requests with at least one needs_revision item / all resolved requests`.

  A request counts ONCE toward the numerator however many of its items were
  rejected: the unit is "a human looked at this submission and sent it back",
  not "an item was rejected". Counting items instead would let one
  submission carrying ten screenshots outweigh ten separate gates.

  ## What `n` counts: RESOLVED review requests

  Not tasks, not validations, not all review requests — the number of
  requests that actually received a human verdict and therefore contributed
  to the ratio.

  ## `pending` and `superseded` are both unreviewed, and leave BOTH sides

  `Platform.Tasks.ReviewRequest` declares statuses `pending | resolved |
  superseded`, and it spells the last two differently on purpose: a
  `resolved` request is the record of a verdict, a `superseded` one is the
  record of evidence replaced before anyone acted on it. Neither `pending`
  nor `superseded` is an answer, so both are excluded from the numerator AND
  the denominator.

  Counting either as an approval is the more natural-looking mistake — the
  denominator grows, the rate falls, and the number stays inside its
  plausible range the whole time. A variant that merely files more evidence
  than reviewers get through, or that keeps replacing its own submissions,
  would then appear to be a variant humans wave through, which is the
  opposite of the truth.

  PROBE RECORD (01a00b91 stage 5). PROBE D widened the resolved filter to count
  `superseded` requests as resolved-and-approved. Predicted: the
  superseded-exclusion test detonates on `n`, not on `value`. Confirmed
  exactly — that test held `value` at 0.0 and moved `n` from 1 to 2. The
  companion numerator test moved on both (1.0 -> 0.5, n 1 -> 2), because it
  pins the ratio as well; the prediction was about the exclusion test alone and
  is the sharper statement of the two. Assert only `value` in these tests and
  the exclusion becomes invisible: a superseded request miscounted as an
  approval leaves a ratio that still reads plausible. The denominator is the
  observable.

  A subject set whose requests are ALL still pending yields
  `:insufficient_data`, not `0.0`. Reporting a perfect wave-through rate for
  requests nobody has answered is the exact failure this metric exists to
  detect.

  ## Direction is `:neutral`, and that is a judgement, not an oversight

  Neither a rise nor a fall in this rate is a win on its own, because both
  ends are gameable in opposite ways. The COUNT of rejections is gameable
  toward zero by never asking for a review at all — attach no manual gate
  and nothing can ever be sent back. The RATE is gameable upward by asking
  less often — keep only the submissions most likely to be rejected and the
  ratio climbs while review coverage collapses. A UI that colours a movement
  here as good or bad is asserting a conclusion the number cannot support,
  which is why the registry records `:neutral`.

  ## This rate CANNOT be read alone — it needs a guard metric

  Read on its own, a rising rejection rate looks like reviewers doing their
  job. Paired with escaped post-merge UI defects reported by a human, the
  same rise reads the other way: if rejection rate goes UP at the same time
  as post-merge UI defects go UP, the system has not got stricter, it has
  simply STOPPED ASKING — fewer gates, on riskier changes, with the
  regressions landing anyway. That is a regression wearing a green badge,
  and only the PAIR of numbers can see it. Either number alone is consistent
  with a healthy system.

  There is NO automatic data source for escaped post-merge UI defects in
  this repository today. Nothing here counts them, and no table stands in
  for them. That guard number is recorded by a human, out of band, and this
  module deliberately does not derive, infer, or proxy it from any existing
  table — a fabricated guard metric would be worse than an absent one,
  because it would look like coverage while measuring something else.
  """

  @behaviour Platform.Experiments.Metric

  import Ecto.Query

  alias Platform.Experiments.Metric
  alias Platform.Experiments.Metric.Result
  alias Platform.Experiments.Metrics
  alias Platform.Repo
  alias Platform.Tasks.ReviewItem
  alias Platform.Tasks.ReviewRequest

  @resolved "resolved"
  @rejected "needs_revision"

  @impl Platform.Experiments.Metric
  @spec compute(Ecto.UUID.t(), String.t()) :: Metric.result()
  def compute(experiment_id, variant_slug) do
    case Metrics.subject_ids(experiment_id, variant_slug) do
      [] ->
        :insufficient_data

      subject_ids ->
        subject_ids
        |> resolved_request_rejection_counts()
        |> rate()
    end
  end

  defp rate([]), do: :insufficient_data

  defp rate(counts) do
    n = length(counts)
    rejected = Enum.count(counts, &(&1 > 0))

    {:ok, %Result{value: rejected / n, n: n, unit: :ratio}}
  end

  # One row per RESOLVED request, carrying how many of its items were
  # rejected. The left join is what keeps a fully approved request in the
  # denominator: an inner join on rejected items would drop it entirely and
  # every variant would report a rejection rate of 1.0.
  defp resolved_request_rejection_counts(subject_ids) do
    ReviewRequest
    |> join(:left, [r], i in ReviewItem,
      on: i.review_request_id == r.id and i.status == ^@rejected
    )
    |> where([r], r.task_id in ^subject_ids)
    |> where([r], r.status == ^@resolved)
    |> group_by([r], r.id)
    |> select([r, i], count(i.id))
    |> Repo.all()
  end
end

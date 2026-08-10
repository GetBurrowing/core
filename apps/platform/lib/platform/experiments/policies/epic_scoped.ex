defmodule Platform.Experiments.Policies.EpicScoped do
  @moduledoc """
  Restricts an experiment to a named set of epics. Task 019fe6b9, ADR-0048.

  Assigns only when `subject.attributes[:epic_id]` is in `opts[:epic_ids]`.
  Every other subject gets `:no_opinion` — not an exclusion.

  The distinction is the whole reason this policy is separate from the
  exclusion filter. A subject outside the epic scope was never a candidate,
  so there is nothing to record about it; an excluded subject WAS a
  candidate and was deliberately removed, which must leave a reason behind.
  Returning `{:excluded, _}` here would write an exclusion row for every
  subject in the system that the experiment simply was not about.

  In-scope subjects are bucketed by
  `Platform.Experiments.Policies.RandomBuckets`, so scoping and bucketing
  compose rather than each reimplementing the other.
  """

  @behaviour Platform.Experiments.Policy

  alias Platform.Experiments.Policies.RandomBuckets
  alias Platform.Experiments.Policy
  alias Platform.Experiments.Subject

  @doc """
  Buckets in-scope subjects; defers on everything else.

  Options: `:epic_ids` (the scope), plus whatever `RandomBuckets` needs, plus
  `:exclude`. Exclusion is checked BEFORE scope, so an excluded subject is
  reported as excluded even when it was also out of scope — the exclusion is
  the fact worth recording.

  A subject with no `:epic_id` attribute is out of scope, never in it.
  """
  @impl Platform.Experiments.Policy
  @spec assign(Subject.t(), keyword()) :: Policy.result()
  def assign(%Subject{attributes: attributes} = subject, opts) do
    case Policy.excluded?(subject, opts) do
      {:excluded, _reason} = excluded ->
        excluded

      false ->
        epic_ids = Keyword.get(opts, :epic_ids, [])
        epic_id = attributes[:epic_id]

        if not is_nil(epic_id) and epic_id in epic_ids do
          RandomBuckets.assign(subject, opts)
        else
          :no_opinion
        end
    end
  end
end

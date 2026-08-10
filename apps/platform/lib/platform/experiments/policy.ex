defmodule Platform.Experiments.Policy do
  @moduledoc """
  How a subject gets a variant. Task 019fe6b9, ADR-0048.

  A policy is a pure decision: given a `Platform.Experiments.Subject` and
  options, it either names a variant slug, excludes the subject with a
  recorded reason, or declines to have an opinion. It performs no database
  work and writes nothing; persisting the decision is
  `Platform.Experiments.Assignments`' job.

  ## The three returns are three different answers

  - `{:ok, slug}` — this subject belongs in that variant.
  - `{:excluded, reason}` — this subject must not take part, and here is why.
    This is a FIRST-CLASS RETURN, not an error. The reason string is what
    `Assignments.exclude/3` writes into `experiment_assignments.excluded_reason`.
    A subject dropped from the denominator with no recorded reason is how a
    result quietly becomes wrong: the arithmetic still works, the exclusion
    is invisible, and nobody downstream can tell an honest filter from a
    thumb on the scale.
  - `:no_opinion` — this policy has nothing to say about this subject. It is
    NOT an exclusion and NOT a failure. It exists so
    `Platform.Experiments.Policies.Composite` can chain: a scope-limited
    policy defers to the next member instead of inventing a bucket for a
    subject it was never meant to judge.

  Collapsing `:no_opinion` into `{:excluded, _}` would be the same class of
  mistake as collapsing `stopped` into `concluded`: two states with different
  meanings sharing one value, so the difference becomes unrecoverable the
  moment it is written down.

  ## The engine stays ignorant of tasks

  Nothing in this module or under `policies/` may reference
  the tasks context, accept a task struct, or read a
  task-specific field off anything other than `subject.attributes`. See
  `Platform.Experiments.Subject`. A source-level test enforces it, because
  the compiler cannot.

  ## The exclusion filter ships now, not when it is needed

  `excluded?/2` is applied by every policy BEFORE it buckets. It is here on
  day one rather than when the first bad variant appears, for a specific
  reason worth restating: these experiments run on the planner that plans
  this stack's own tasks. A degraded variant therefore degrades the work
  building the thing that measures it, and the moment you want to pull a
  project or an epic out of the experiment you want it *immediately* — not
  after writing, reviewing and shipping a migration.

  It lives in the POLICY layer precisely so no schema change is involved,
  which is exactly why it is cheap enough to add today rather than argue
  about later.
  """

  alias Platform.Experiments.Subject

  @type result :: {:ok, String.t()} | {:excluded, String.t()} | :no_opinion

  @doc """
  Decides which variant, if any, this subject belongs in.

  Implementations must call `excluded?/2` before bucketing and return its
  `{:excluded, _}` unchanged.
  """
  @callback assign(subject :: Subject.t(), opts :: keyword()) :: result()

  @doc """
  The shared exclusion filter, applied by every policy before it buckets.

  `opts[:exclude]` is `[project_ids: [uuid], epic_ids: [uuid]]`; either key
  may be absent. Returns `{:excluded, reason}` when the subject's
  `:project_id` or `:epic_id` attribute is listed, and `false` otherwise —
  so a caller reads as `case excluded?(subject, opts) do {:excluded, _} = e -> e ...`.

  Project exclusion is checked first and reported as such; a subject in both
  an excluded project and an excluded epic is reported as project-excluded,
  which is arbitrary but fixed, so the reason string is stable.

  An empty or absent `:exclude` excludes nothing. There is deliberately no
  "exclude everything" default: a filter that silently excluded on a
  malformed option would empty an experiment with no error anywhere.
  """
  @spec excluded?(Subject.t(), keyword()) :: {:excluded, String.t()} | false
  def excluded?(%Subject{attributes: attributes}, opts) when is_list(opts) do
    exclude = Keyword.get(opts, :exclude, [])

    project_ids = Keyword.get(exclude, :project_ids, [])
    epic_ids = Keyword.get(exclude, :epic_ids, [])

    cond do
      member?(attributes[:project_id], project_ids) -> {:excluded, "project excluded"}
      member?(attributes[:epic_id], epic_ids) -> {:excluded, "epic excluded"}
      true -> false
    end
  end

  # A subject with no project_id is not excluded by a project list. nil must
  # never match, or a list containing nil would exclude every unscoped
  # subject in the experiment.
  defp member?(nil, _ids), do: false
  defp member?(value, ids) when is_list(ids), do: value in ids
  defp member?(_value, _ids), do: false
end

defmodule Platform.Experiments.Policies.TaskCohort do
  @moduledoc """
  Restricts an experiment to subjects matching an attribute predicate.
  Task 019fe6b9, ADR-0048.

  `opts[:cohort]` is an ordered list of `{key, values}` pairs. A subject is
  in the cohort when, for EVERY pair, `subject.attributes[key]` is a member
  of `values`. Anything else is `:no_opinion`.

  ## The name says task; the code does not

  This policy reads `subject.attributes` and nothing else. It does not
  reference the tasks context, does not accept a task struct, and has no
  knowledge of what a task is — the cohort keys are supplied by the caller,
  which is the layer that does know. The name describes the intended USE,
  not a dependency, and a source-level test enforces the difference.

  That is what keeps a `"dispatch"` subject working here later with no
  change: this module already cannot tell the difference.

  ## An empty cohort matches nothing

  A predicate with no clauses is vacuously true for every subject, which
  would turn a misconfigured option into a silent 100% rollout. So an empty
  or absent `:cohort` returns `:no_opinion` instead. A policy that assigns
  everything when its configuration is missing is indistinguishable from one
  that is working.
  """

  @behaviour Platform.Experiments.Policy

  alias Platform.Experiments.Policies.RandomBuckets
  alias Platform.Experiments.Policy
  alias Platform.Experiments.Subject

  @doc """
  Buckets subjects matching every cohort clause; defers on everything else.

  Options: `:cohort` (`[{key, values}]`), plus whatever `RandomBuckets`
  needs, plus `:exclude`. Exclusion is checked first.

  A subject missing a key named by the cohort does not match: `nil` is never
  a member of the allowed values, even if the values list contains `nil`.
  """
  @impl Platform.Experiments.Policy
  @spec assign(Subject.t(), keyword()) :: Policy.result()
  def assign(%Subject{attributes: attributes} = subject, opts) do
    case Policy.excluded?(subject, opts) do
      {:excluded, _reason} = excluded ->
        excluded

      false ->
        cohort = Keyword.get(opts, :cohort, [])

        if cohort != [] and Enum.all?(cohort, &matches?(attributes, &1)) do
          RandomBuckets.assign(subject, opts)
        else
          :no_opinion
        end
    end
  end

  defp matches?(attributes, {key, values}) when is_list(values) do
    value = Map.get(attributes, key)
    not is_nil(value) and value in values
  end

  defp matches?(attributes, {key, value}) do
    actual = Map.get(attributes, key)
    not is_nil(actual) and actual == value
  end
end

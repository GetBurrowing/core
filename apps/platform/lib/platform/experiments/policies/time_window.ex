defmodule Platform.Experiments.Policies.TimeWindow do
  @moduledoc """
  Restricts an experiment to subjects created inside a time window.
  Task 019fe6b9, ADR-0048.

  Assigns only when `subject.attributes[:inserted_at]` falls within
  `opts[:from]..opts[:until]`, inclusive of both ends. Everything else is
  `:no_opinion`.

  ## A missing timestamp is `:no_opinion`, never `now`

  Defaulting an absent `:inserted_at` to the current time would put every
  subject the caller failed to describe inside any window that includes
  today. The experiment would then be running on a population nobody
  selected, and the defect is invisible: the assignments look ordinary, the
  window looks respected, and the only symptom is a result about the wrong
  subjects.

  So an absent, `nil`, or non-datetime `:inserted_at` defers. The same
  reasoning applies to the bounds — an absent `:from` or `:until` means that
  side is unbounded, which is a deliberate choice a caller makes, not a
  fabricated value.
  """

  @behaviour Platform.Experiments.Policy

  alias Platform.Experiments.Policies.RandomBuckets
  alias Platform.Experiments.Policy
  alias Platform.Experiments.Subject

  @doc """
  Buckets subjects inside the window; defers on everything else.

  Options: `:from` and `:until` (`DateTime`, either may be omitted for an
  unbounded side), plus whatever `RandomBuckets` needs, plus `:exclude`.
  Exclusion is checked first.
  """
  @impl Platform.Experiments.Policy
  @spec assign(Subject.t(), keyword()) :: Policy.result()
  def assign(%Subject{attributes: attributes} = subject, opts) do
    case Policy.excluded?(subject, opts) do
      {:excluded, _reason} = excluded ->
        excluded

      false ->
        if within?(attributes[:inserted_at], Keyword.get(opts, :from), Keyword.get(opts, :until)) do
          RandomBuckets.assign(subject, opts)
        else
          :no_opinion
        end
    end
  end

  defp within?(%DateTime{} = at, from, until), do: after?(at, from) and before?(at, until)
  defp within?(_at, _from, _until), do: false

  defp after?(_at, nil), do: true
  defp after?(at, %DateTime{} = from), do: DateTime.compare(at, from) != :lt
  defp after?(_at, _from), do: false

  defp before?(_at, nil), do: true
  defp before?(at, %DateTime{} = until), do: DateTime.compare(at, until) != :gt
  defp before?(_at, _until), do: false
end

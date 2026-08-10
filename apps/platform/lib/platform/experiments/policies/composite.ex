defmodule Platform.Experiments.Policies.Composite do
  @moduledoc """
  Chains policies, returning the first one with an opinion.
  Task 019fe6b9, ADR-0048.

  `opts[:policies]` is an ORDERED list of `{module, opts}`. Each member is
  asked in turn; the first result that is not `:no_opinion` is returned. If
  every member defers, so does the composite.

  ## An exclusion short-circuits, and the check happens here too

  An `{:excluded, reason}` from any member is returned as-is and no later
  member is consulted. An exclusion that a subsequent policy could override
  is not an exclusion — it is a suggestion, and the subject ends up in the
  experiment it was deliberately removed from, with an assignment row that
  looks entirely legitimate.

  This module ALSO applies `Platform.Experiments.Policy.excluded?/2` itself,
  before consulting any member, rather than relying on the members to do it.
  Every policy in this library does check, so that call is redundant today —
  deliberately. `opts[:policies]` accepts any module implementing the
  behaviour, including ones written later or elsewhere, and the composite is
  the layer that promises the exclusion list is honoured. Leaving the
  guarantee to the members would make it hold only for as long as every
  member happens to be well-behaved, and the failure would be silent.

  ## Order is the mechanism

  Members are consulted in list order and the first opinion wins. Putting a
  broad policy before a narrow one makes the narrow one unreachable, and
  nothing here will warn about it: an unreachable policy returns no error,
  it simply never runs.
  """

  @behaviour Platform.Experiments.Policy

  alias Platform.Experiments.Policy
  alias Platform.Experiments.Subject

  @doc """
  Asks each member in `opts[:policies]` in order.

  Member options are used as given, so a member's `:exclude`, `:variants`
  and scope options travel with it. Returns `:no_opinion` when the list is
  empty or every member defers.
  """
  @impl Platform.Experiments.Policy
  @spec assign(Subject.t(), keyword()) :: Policy.result()
  def assign(%Subject{} = subject, opts) do
    case Policy.excluded?(subject, opts) do
      {:excluded, _reason} = excluded ->
        excluded

      false ->
        opts
        |> Keyword.get(:policies, [])
        |> chain(subject)
    end
  end

  defp chain([], _subject), do: :no_opinion

  defp chain([{module, member_opts} | rest], subject) do
    case module.assign(subject, member_opts) do
      :no_opinion -> chain(rest, subject)
      result -> result
    end
  end
end

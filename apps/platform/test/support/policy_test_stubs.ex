defmodule Platform.Experiments.PolicyTestStubs.AlwaysBuckets do
  @moduledoc """
  A policy that buckets every subject and deliberately IGNORES `:exclude`.

  It exists so `Platform.Experiments.Policies.Composite` can be tested
  against a member that does not honour the exclusion list — which is the
  only way to show that the composite's own `Policy.excluded?/2` call is
  load-bearing. Every policy shipped in this library checks exclusion itself,
  so with a well-behaved member the composite's check is invisible: removing
  it would leave the tests green while the guarantee moved from the composite
  to the goodwill of whatever module a caller passes in.
  """

  @behaviour Platform.Experiments.Policy

  @impl Platform.Experiments.Policy
  def assign(_subject, _opts), do: {:ok, "always"}
end

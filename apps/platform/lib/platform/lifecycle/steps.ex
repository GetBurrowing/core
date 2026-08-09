defmodule Platform.Lifecycle.Steps do
  @moduledoc """
  Bodies of the built-in lifecycle hook steps declared in
  `Platform.Lifecycle.StepRegistry` (ADR-0046, task 019fe1b6 stage 1).

  Every entry in the registry's `@built_in_steps` allowlist must resolve
  to a real arity-1 function, otherwise the allowlist names something
  uncallable. This module supplies those functions and nothing else.

  Nothing in this stack member invokes them. The pipeline runner that
  calls a step, decides what a return value means, and applies budgets
  or halting is a later member; until it lands these are pure,
  side-effect-free, and return the context unchanged.
  """

  @doc """
  Deterministic no-op notify step.

  Placeholder body: takes the pipeline context and returns it unchanged.
  The runner member replaces this with the real emit once it defines
  what a step is allowed to return.
  """
  @spec notify(map()) :: {:ok, map()}
  def notify(context) when is_map(context), do: {:ok, context}
end

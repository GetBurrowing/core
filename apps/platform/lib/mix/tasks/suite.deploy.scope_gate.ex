defmodule Mix.Tasks.Suite.Deploy.ScopeGate do
  @moduledoc """
  Legacy name of `mix burrow.deploy.scope_gate`
  (`Mix.Tasks.Burrow.Deploy.ScopeGate`), kept so scripts and runbooks that
  still type the old name keep working (task 01a14b9e-50a4 stage 1).

  It carries no `@shortdoc`, so `mix help` lists only the Burrow name.
  Every argument is passed through unchanged.
  """

  use Mix.Task

  alias Mix.Tasks.Burrow.Deploy.ScopeGate

  @impl Mix.Task
  defdelegate run(args), to: ScopeGate

  @doc "See `Mix.Tasks.Burrow.Deploy.ScopeGate.scope/1`."
  defdelegate scope(args), to: ScopeGate
end

defmodule Mix.Tasks.Suite.ResponsibilityReachability do
  @moduledoc """
  Legacy name of `mix burrow.responsibility_reachability`
  (`Mix.Tasks.Burrow.ResponsibilityReachability`), kept so scripts that
  still type the old name keep working (task 01a14b9e-50a4 stage 1).

  It carries no `@shortdoc`, so `mix help` lists only the Burrow name.
  """

  use Mix.Task

  @impl Mix.Task
  defdelegate run(args), to: Mix.Tasks.Burrow.ResponsibilityReachability
end

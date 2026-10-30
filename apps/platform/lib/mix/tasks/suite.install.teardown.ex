defmodule Mix.Tasks.Suite.Install.Teardown do
  @moduledoc """
  Legacy name of `mix burrow.install.teardown`
  (`Mix.Tasks.Burrow.Install.Teardown`), the command task 01a10315's plan and
  runbooks type. It carries no `@shortdoc`, so `mix help` lists only the
  Burrow name. Every argument is passed through unchanged.
  """

  use Mix.Task

  @impl Mix.Task
  defdelegate run(args), to: Mix.Tasks.Burrow.Install.Teardown
end

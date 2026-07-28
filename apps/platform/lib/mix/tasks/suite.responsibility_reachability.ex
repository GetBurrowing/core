defmodule Mix.Tasks.Suite.ResponsibilityReachability do
  @moduledoc """
  Print `Platform.Responsibilities.Reachability.report/0` as a fixed-width
  table plus one machine-readable `REACH ...` line per row (task `019fa510`
  stage 1).

  ## Usage

      mix suite.responsibility_reachability

  From a release, where Mix is not available, call the module directly via
  an RPC console — this task is a thin `IO.puts` wrapper and all logic lives
  in `Platform.Responsibilities.Reachability`:

      IO.puts(Platform.Responsibilities.Reachability.render())

  ## Read the output's own caveat before quoting it

  `:broadcastable` means the **server** would broadcast. It says nothing
  about whether the receiving client parses the envelope — that is the
  precise gap the 2026-07-27 empty-envelope defect lived in, and every
  affected key read `:broadcastable` throughout. The rendered output repeats
  this at the bottom on purpose; do not strip it when pasting the table
  somewhere else.
  """

  use Mix.Task

  alias Platform.Responsibilities.Reachability

  @shortdoc "Print responsibility dispatch-reachability classes"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts(Reachability.render())

    :ok
  end
end

defmodule Mix.Tasks.Platform.OpenQuestionPilot.Rescore do
  @shortdoc "Re-scores the pilot's artefact-level privacy by replaying its cassettes (no model calls)"

  @moduledoc """
  Re-score `results.json`'s artefact-level privacy for every recorded arm
  by replaying the checked-in TEST cassettes through the current
  `gather_context/2` floor. Makes NO model call and does not modify the
  cassettes. See `Platform.Meetings.OpenQuestionPilot.Runner.rescore_replay!/3`.

      mix platform.open_question_pilot.rescore --reason "why" [--dir priv/imp_pilot/open_question]
  """

  use Mix.Task

  alias Platform.Meetings.OpenQuestionPilot.Runner

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [dir: :string, reason: :string])
    reason = opts[:reason] || Mix.raise("--reason is required")
    dir = opts[:dir] || "priv/imp_pilot/open_question"

    Mix.Task.run("app.start")
    Mix.Tasks.Platform.OpenQuestionPilot.Run.own_repo_connection()

    results = Runner.rescore_replay!(dir, reason)

    for {name, block} when is_map(block) <- results["arms"] do
      Mix.shell().info("#{name}: privacy #{inspect(block["privacy"])}")
    end
  end
end

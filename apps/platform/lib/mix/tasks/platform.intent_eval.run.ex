defmodule Mix.Tasks.Platform.IntentEval.Run do
  @moduledoc """
  Score a prompt config against the labelled intent-eval set
  (task `01a03fbb` stage 4).

      mix platform.intent_eval.run --config off_topic_default
      mix platform.intent_eval.run --config off_topic_default --slice negatives_102
      mix platform.intent_eval.run --config off_topic_default --record

  ## Modes

    * `--replay` — read only `priv/intent_eval/cassettes/<config>.jsonl`.
      **The default whenever a cassette exists.** No network.
    * `--record` — call the live endpoint named by the config and append
      every response to that cassette.

  Without access to the classifier endpoint you can still `--replay` any
  committed cassette and reproduce every published number. You cannot
  produce fresh numbers for a config that has no cassette; see
  `priv/intent_eval/README.md`.

  A `--replay` run that misses a key FAILS, naming the missing keys and the
  count. It never falls through to a live call and never scores the missing
  row as an error.

  All numbers land in `priv/intent_eval/runs/<utc-timestamp>-<config>.json`
  next to the run manifest, which records the resolved prompt source and
  `sha256(rendered_prompt)` — so two runs that disagree can be told apart in
  one diff.
  """

  use Mix.Task

  alias Platform.Meetings.IntentEval
  alias Platform.Meetings.IntentEval.Harness

  @shortdoc "Score a prompt config against the labelled intent-eval set"

  @switches [
    config: :string,
    slice: :string,
    record: :boolean,
    replay: :boolean,
    root: :string,
    repo_root: :string,
    write: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    config = parsed[:config] || Mix.raise("--config <name> is required")
    root = IntentEval.root(Keyword.take(parsed, [:root]))

    opts =
      [
        root: root,
        mode: mode(parsed),
        slice: parsed[:slice],
        repo_root: parsed[:repo_root] || File.cwd!(),
        write: Keyword.get(parsed, :write, true)
      ]

    case Harness.run(config, opts) do
      {:ok, result} ->
        Mix.shell().info(Harness.report(result))
        :ok

      {:error, {:cassette_miss, details}} ->
        Mix.raise(Harness.miss_report(details))
    end
  end

  # `--record` and `--replay` together is a contradiction, not a preference
  # order: silently picking one is how a run ends up unattributable.
  defp mode(parsed) do
    case {parsed[:record], parsed[:replay]} do
      {true, true} -> Mix.raise("--record and --replay are mutually exclusive")
      {true, _} -> :record
      {_, true} -> :replay
      _ -> :auto
    end
  end
end

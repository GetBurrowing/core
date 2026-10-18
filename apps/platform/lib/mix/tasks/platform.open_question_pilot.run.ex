defmodule Mix.Tasks.Platform.OpenQuestionPilot.Run do
  @shortdoc "Runs the open_question pilot once: baseline A, GEPA once, select, compare, save"

  @moduledoc """
  The open_question pilot's measured run (task 01a0e8b5 stage 4). See
  `Platform.Meetings.OpenQuestionPilot.Runner` for the steps. They always
  run in the same order, and none can be skipped.

      mix platform.open_question_pilot.run [--out-dir DIR] [--base-url URL] [--model NAME]
          [--max-metric-calls 300] [--hard-call-cap 400] [--reflection-cap 40]
          [--selection-cap 120] [--seed N]

  The default provider is the classifier endpoint `INTENT_EVAL_BASE_URL`
  names, else `http://localhost:8085/v1` (model `classifier`). It is used for both
  the task model and GEPA's reflection model. No other provider is wired.

  This task makes model calls, and it writes to `--out-dir` (default
  `priv/imp_pilot/open_question`, relative to `apps/platform`). It never
  creates an experiment, a variant or a surface default: production stays
  on the prompt arm.
  """

  use Mix.Task

  alias Platform.Meetings.OpenQuestionPilot.Runner

  @switches [
    out_dir: :string,
    base_url: :string,
    model: :string,
    max_metric_calls: :integer,
    hard_call_cap: :integer,
    reflection_cap: :integer,
    selection_cap: :integer,
    seed: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    opts = parse_args!(argv)
    Mix.Task.run("app.start")
    own_repo_connection()

    results = Runner.run(opts)
    arms = results["arms"]

    Mix.shell().info("""
    open_question pilot: stop_reason=#{results["optimiser"]["stop_reason"]} \
    admissible=#{results["selection"]["admissible"]}
      A prompt:      #{summary(arms["prompt"])}
      B imp_program: #{summary(arms["imp_program"])}
    results: #{Path.join(opts[:out_dir], "results.json")}
    """)
  end

  @doc "Parse argv into runner options, with the runner's defaults filled in."
  @spec parse_args!([String.t()]) :: keyword()
  def parse_args!(argv) do
    {parsed, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("unexpected arguments: #{inspect(rest ++ invalid)}")
    end

    Runner.defaults()
    |> Keyword.merge(parsed)
    |> Keyword.put_new(:out_dir, "priv/imp_pilot/open_question")
  end

  # The test rig runs this task under MIX_ENV=test against a scratch
  # database, where the Repo pool is the SQL sandbox. A sandboxed checkout
  # lives inside a transaction that is rolled back when its 120 s ownership
  # expires, taking the artefact room with it mid-run (seen on the first
  # attempt, 2026-09-29). Check out a REAL connection with no ownership
  # timeout and share it. Under any other pool this is a no-op.
  @doc false
  def own_repo_connection do
    repo = Platform.Repo

    if repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo, sandbox: false, ownership_timeout: :infinity)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
    end

    :ok
  end

  defp summary(nil), do: "not scored (no admissible B)"

  defp summary(arm) do
    "precision=#{inspect(arm["precision"])} recall=#{inspect(arm["recall"])} " <>
      "privacy output=#{arm["privacy"]["output_routable"]} " <>
      "artefact=#{arm["privacy"]["artefact_not_refused"]} errors=#{inspect(arm["errors"])}"
  end
end

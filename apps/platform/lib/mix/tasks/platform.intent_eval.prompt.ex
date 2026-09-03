defmodule Mix.Tasks.Platform.IntentEval.Prompt do
  @moduledoc """
  Render — and diff — the prompt a config actually sends
  (task `01a06575` stage 4).

      mix platform.intent_eval.prompt --config off_topic_default
      mix platform.intent_eval.prompt --config off_topic_default --exemplars-only
      mix platform.intent_eval.prompt --config off_topic_default \\
        --diff off_topic_default_prod_exemplars

  ## Why a prompt-only task exists

  `platform.intent_eval.run` needs a cassette or an endpoint. When there
  is neither — the normal case for this eval, and the case at the time
  this task was written — a prompt change cannot be priced in f1. It can
  still be READ, and reading it is not a consolation prize: the specific
  defect this task was written to expose is that the harness rendered
  `{{correction_exemplars}}` as the sentinel `(no prior corrections)` on
  every run ever published, while production renders up to ten of the
  org's most recent producer corrections there. That is a difference in
  the prompt, visible with no model at all.

  ## What it will NOT do

  It will not score. In particular it will not let you replay one
  config's cassette against another config's prompt: the cassette holds
  the model's answers to the body it was recorded against, and scoring
  those against a different body produces numbers that look like an
  answer and mean nothing. `Harness.run/2` refuses that with a cassette
  miss; this task simply does not offer it.
  """

  use Mix.Task

  alias Platform.Meetings.IntentEval
  alias Platform.Meetings.IntentEval.Harness

  @shortdoc "Render or diff the prompt an intent-eval config sends"

  @switches [
    config: :string,
    diff: :string,
    root: :string,
    repo_root: :string,
    exemplars_only: :boolean,
    full: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    config = parsed[:config] || Mix.raise("--config <name> is required")

    opts = [
      root: IntentEval.root(Keyword.take(parsed, [:root])),
      repo_root: parsed[:repo_root] || File.cwd!()
    ]

    left = Harness.render_prompt(config, opts)

    case parsed[:diff] do
      nil -> Mix.shell().info(render_one(left, parsed))
      other -> Mix.shell().info(render_diff(left, Harness.render_prompt(other, opts), parsed))
    end
  end

  defp render_one(rendered, parsed) do
    [
      header(rendered),
      "",
      "CORRECTION EXEMPLAR BLOCK (#{rendered["exemplar_bytes"]} bytes)",
      indent(rendered["exemplar_block"]),
      body(rendered, parsed)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp render_diff(left, right, parsed) do
    [
      "PROMPT DIFF  #{left["config"]}  vs  #{right["config"]}",
      "",
      header(left),
      "",
      header(right),
      "",
      "SAME PROMPT BODY? #{left["template_sha256"] == right["template_sha256"]}",
      "SAME RENDERED PROMPT? #{left["rendered_sha256"] == right["rendered_sha256"]}",
      "EXEMPLAR BLOCK DELTA: #{right["exemplar_bytes"] - left["exemplar_bytes"]} bytes",
      "",
      # The whole point of the task, stated where it cannot be missed.
      """
      These two arms send DIFFERENT prompts, so their cassettes are not
      interchangeable and neither is scoreable against the other's
      recording. The score delta between them is NOT MEASURABLE without a
      reachable classifier endpoint. What is measurable, and printed
      below, is exactly what one sends that the other does not.\
      """,
      "",
      "── #{left["config"]} exemplar block (#{left["exemplar_bytes"]} bytes) ──",
      indent(left["exemplar_block"]),
      "",
      "── #{right["config"]} exemplar block (#{right["exemplar_bytes"]} bytes) ──",
      indent(right["exemplar_block"]),
      body(right, parsed)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp header(rendered) do
    [
      "CONFIG #{rendered["config"]}",
      "  prompt source   : #{inspect(rendered["prompt_source"])}",
      "  exemplar source : #{inspect(rendered["exemplar_source"])}",
      "  template sha256 : #{rendered["template_sha256"]}",
      "  rendered sha256 : #{rendered["rendered_sha256"]}"
    ]
  end

  defp body(rendered, parsed) do
    cond do
      parsed[:exemplars_only] ->
        []

      parsed[:full] ->
        ["", "FULL RENDERED PROMPT (#{rendered["config"]})", "", rendered["rendered"]]

      true ->
        ["", "(pass --full to print the whole rendered prompt)"]
    end
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end

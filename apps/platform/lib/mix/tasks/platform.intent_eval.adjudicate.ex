defmodule Mix.Tasks.Platform.IntentEval.Adjudicate do
  @moduledoc """
  The human adjudication round-trip for the intent evaluation set
  (task `01a03fbb` stage 3).

      mix platform.intent_eval.adjudicate --emit
      # ... a human fills the human_label column ...
      mix platform.intent_eval.adjudicate --ingest priv/intent_eval/adjudication/open.csv --by alex

  `--emit` writes `priv/intent_eval/adjudication/open.csv` with the columns
  `id,text,prior_context,model_label,model_rationale,human_label,note`, holding
  ONLY the rows where the strong model's pre-label disagrees with an existing
  slice label or its confidence is below `--threshold` (default 0.75). The
  confident agreements never reach a person; that is the whole point of the
  pre-label pass.

  ## There is no screen, deliberately

  A CSV in a spreadsheet is a worse interface than a keyboard-driven
  agree/disagree LiveView — and a LiveView is a real design surface that has
  had no design pass, on a ticket framed as days rather than weeks. The
  deliverable is the harness and the labelled set. If a screen proves necessary
  it is a separate ticket, with a design pass and a `manual_approval` gate.

  ## `--by` is required and may not be the pre-labeller

  `--ingest` refuses, writing nothing, if `--by` matches the agent slug that
  produced the pre-label for any filled row: an agent confirming its own labels
  produces a set that agrees with the model by construction.

  ## An ingest is all-or-nothing

  `--ingest` also refuses, writing nothing, while any open row still has a
  blank `human_label`. The CSV is your own working file on disk, so a refusal
  costs nothing — keep editing and ingest when it is complete. The point is
  that both refusal paths obey the same contract; before stage 6 a partial CSV
  half-applied while a self-adjudicating one wrote nothing.

  A pre-labels file whose rows do not each carry `agent_slug` is refused too:
  the self-adjudication check compares per row, so a header-only slug would
  disable it silently.

  `--refresh-digests` recomputes the slice sha256s in `manifest.json`. Editing a
  slice is legal; editing one without running this leaves the manifest
  disagreeing with the file, which `IntentEvalTest` fails on.
  """

  use Mix.Task

  alias Platform.Meetings.IntentEval

  @shortdoc "Emit or ingest the intent-eval human adjudication CSV"

  @switches [
    emit: :boolean,
    ingest: :string,
    by: :string,
    root: :string,
    threshold: :float,
    refresh_digests: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} = OptionParser.parse(args, strict: @switches)
    root = IntentEval.root(Keyword.take(parsed, [:root]))
    opts = threshold_opts(parsed)

    cond do
      parsed[:refresh_digests] -> refresh(root)
      parsed[:emit] -> emit(root, opts)
      is_binary(parsed[:ingest]) -> ingest(root, parsed[:ingest], parsed[:by], opts)
      true -> Mix.raise("one of --emit, --ingest <file> or --refresh-digests is required")
    end
  end

  defp threshold_opts(parsed) do
    case parsed[:threshold] do
      value when is_number(value) -> [threshold: value]
      _ -> []
    end
  end

  defp refresh(root) do
    manifest = IntentEval.refresh_digests!(root)

    Mix.shell().info(
      "INTENT_EVAL_DIGESTS " <>
        Enum.map_join(manifest["slices"], " ", &"#{&1["name"]}=#{&1["sha256"]}")
    )
  end

  defp emit(root, opts) do
    {:ok, path, count} = IntentEval.emit_open(root, opts)
    Mix.shell().info("INTENT_EVAL_ADJUDICATE_EMIT out=#{path} open=#{count}")
  end

  defp ingest(_root, _file, nil, _opts),
    do: Mix.raise("--by <identity> is required: an adjudication with no author is unauditable")

  defp ingest(root, file, by, opts) do
    case IntentEval.ingest(root, file, by, opts) do
      {:ok, summary} ->
        Mix.shell().info(
          "INTENT_EVAL_ADJUDICATE_INGEST merged=#{summary.merged} open=#{summary.open} " <>
            "outstanding=#{summary.outstanding} adjudicated=#{summary.adjudicated}"
        )

      {:error, {:self_adjudication, slug, ids}} ->
        Mix.raise(
          "refusing ingest: #{slug} produced the pre-labels for #{length(ids)} of these rows " <>
            "(#{Enum.join(Enum.take(ids, 5), ", ")}). An agent may not adjudicate its own labels."
        )

      {:error, {:incomplete, ids}} ->
        Mix.raise(
          "refusing ingest: #{length(ids)} open row(s) still have a blank human_label " <>
            "(#{Enum.join(Enum.take(ids, 5), ", ")}). An ingest is all-or-nothing — finish " <>
            "the CSV and run this again. Nothing has been written."
        )
    end
  end
end

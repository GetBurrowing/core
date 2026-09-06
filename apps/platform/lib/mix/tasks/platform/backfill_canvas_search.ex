defmodule Mix.Tasks.Platform.BackfillCanvasSearch do
  @moduledoc """
  CLI wrapper around `Platform.Chat.CanvasSearchBackfill.run/1` — writes
  `chat_canvas_search` rows for canvases saved before stage 2's write path
  existed (task `01a07402` stage 3).

  The logic lives in `Platform.Chat.CanvasSearchBackfill` so it can also be
  invoked from a release via `bin/platform eval`, which is the same split
  `mix platform.backfill_mentions` and `mix platform.backfill_file_cards`
  use. Normally nobody has to run this at all: `Platform.Application` starts
  a one-shot at boot. This is the handle for re-running it — after a partial
  run, or to re-drive the rows a previous run skipped.

  ## Usage

      mix platform.backfill_canvas_search                # everything
      mix platform.backfill_canvas_search --batch 50     # smaller queries
      mix platform.backfill_canvas_search --limit 100    # stop after 100 rows

  Idempotent: it only ever looks at canvases with no index row, so a second
  run finds nothing. Re-running is also the retry for any row a previous run
  skipped — those rows still have no index row, so they come back round.

  An unrecognised option is a hard error rather than a shrug: `--limt 10`
  with a typo would parse as "no limit" and walk the whole corpus.
  """

  use Mix.Task

  alias Platform.Chat.CanvasSearchBackfill

  @shortdoc "Index canvas bodies that predate the search-index write path"

  @impl Mix.Task
  def run(args) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [batch: :integer, limit: :integer],
        aliases: [b: :batch, l: :limit]
      )

    abort_on_bad_args!(rest, invalid)

    Mix.Task.run("app.start")

    opts =
      []
      |> put_if(parsed, :batch)
      |> put_if(parsed, :limit)

    {:ok, report} = CanvasSearchBackfill.run(opts)

    Mix.shell().info(
      "canvas search backfill: processed=#{report.processed} failed=#{report.failed} " <>
        "batches=#{report.batches} remaining=#{report.remaining}"
    )

    if report.failed > 0 do
      Mix.shell().info(
        "  ! #{report.failed} canvas(es) skipped and still unindexed: " <>
          Enum.join(report.failed_ids, ", ") <>
          "\n    (re-running this task is the retry)"
      )
    end

    :ok
  end

  defp abort_on_bad_args!([], []), do: :ok

  defp abort_on_bad_args!(rest, invalid) do
    Mix.raise(
      "unrecognised arguments: " <>
        Enum.map_join(rest ++ Enum.map(invalid, &elem(&1, 0)), " ", &inspect/1) <>
        "\n\nUsage: mix platform.backfill_canvas_search [--batch N] [--limit N]"
    )
  end

  defp put_if(opts, parsed, key) do
    case Keyword.fetch(parsed, key) do
      {:ok, value} -> Keyword.put(opts, key, value)
      :error -> opts
    end
  end
end

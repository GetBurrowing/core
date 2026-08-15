defmodule Mix.Tasks.Platform.BackfillFileCards do
  @moduledoc """
  Writes catalog cards for files that were ingested before the emitter
  existed (task 01a0008c stage 3).

  `Platform.Files.CatalogEmitter` only sees future ingests. Everything
  already at `ingest_status: "ingested"` — which is the entire current
  corpus, including both order forms the supersession example is built on
  — needs this once.

  ## Dry-run is the default

      mix platform.backfill_file_cards              # census only, spends nothing
      mix platform.backfill_file_cards --write      # actually catalogs

  A bare run enumerates, prints every bucket and returns. It makes no
  provider call and writes no wiki page. `--write` is the only thing that
  spends money, and this loop spends it per file.

  ## Options

    * `--write` — catalog for real. Absent = dry run.
    * `--dry-run` — accepted and redundant, because the sibling task
      `mix platform.backfill_html_ingest` makes it opt-in and the muscle
      memory is worth honouring. If both are passed the dry run wins:
      between two readings of an ambiguous command line, take the one
      that spends nothing.
    * `--project-id UUID` — restrict to one project.
    * `--limit N` — cap the number of candidates catalogued. The census
      counts stay true; only the work list is trimmed, so this is the way
      to buy one file's worth of output before committing to the corpus.

  An unrecognised option is a hard error rather than a shrug. Silently
  dropping one is not a cosmetic bug here: `--write --projct-id <uuid>`
  with a typo'd scope would parse as "write, no scope" and catalog the
  entire corpus instead of one project.

  Serial by design — see `Platform.Files.CardBackfill`. Runs synchronously
  so `mix` cannot halt the VM out from under in-flight work.

  Re-runnable: rows that already have a `card_file_key` are skipped, and
  rows a provider error left uncatalogued become candidates again. That
  re-run *is* the retry strategy for the whole subsystem; there is no
  retry queue.
  """
  use Mix.Task

  alias Platform.Files.CardBackfill

  @shortdoc "Catalog cards for already-ingested files (dry run unless --write)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [write: :boolean, dry_run: :boolean, project_id: :string, limit: :integer]
      )

    abort_on_bad_args!(rest, invalid)

    opts =
      [dry_run: dry_run?(parsed)]
      |> put_if(parsed, :project_id)
      |> put_if(parsed, :limit)

    report = CardBackfill.run(opts)

    Mix.shell().info(CardBackfill.format_report(report))

    if report.dry_run do
      Mix.shell().info("  (dry run — re-run with --write to catalog these)")
    end
  end

  # Absent means dry run. `--dry-run` is honoured explicitly so it is not
  # merely tolerated, and it beats `--write` when both appear.
  defp dry_run?(parsed) do
    Keyword.get(parsed, :dry_run, not Keyword.get(parsed, :write, false))
  end

  defp abort_on_bad_args!([], []), do: :ok

  defp abort_on_bad_args!(rest, invalid) do
    Mix.raise(
      "unrecognised arguments: " <>
        Enum.map_join(rest ++ Enum.map(invalid, &elem(&1, 0)), " ", &inspect/1) <>
        "\n\nRefusing to run rather than guess. A dropped `--project-id` would " <>
        "widen a one-project run to the whole corpus.\n" <>
        "Usage: mix platform.backfill_file_cards [--write] [--project-id UUID] [--limit N]"
    )
  end

  defp put_if(opts, parsed, key) do
    case Keyword.fetch(parsed, key) do
      {:ok, value} -> Keyword.put(opts, key, value)
      :error -> opts
    end
  end
end

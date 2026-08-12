defmodule Mix.Tasks.Platform.BackfillHtmlIngest do
  @moduledoc """
  Re-ingests already-uploaded HTML files now that the extractor covers
  `text/html` (task 019ff1ab).

  Measures first and prints the census — including the rows it
  deliberately leaves alone — then re-ingests only the covered ones.
  Idempotent: a second run reports `re-ingested: 0`.

  The re-ingest is synchronous on purpose. `mix` halts the VM as soon as
  this function returns, which takes `Platform.TaskSupervisor` and any
  in-flight child with it; the printed counts would then describe work
  that was killed mid-extract. Every number below is a finished outcome.

  ## Usage

      mix platform.backfill_html_ingest --dry-run
      mix platform.backfill_html_ingest

  """
  use Mix.Task

  alias Platform.Files.HTMLBackfill

  @shortdoc "Re-ingest uploaded HTML files the extractor now covers"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = if "--dry-run" in args, do: [dry_run: true], else: []

    report = HTMLBackfill.run(opts)

    Mix.shell().info(HTMLBackfill.format_report(report))

    if opts[:dry_run], do: Mix.shell().info("  (dry run — nothing was written)")
  end
end

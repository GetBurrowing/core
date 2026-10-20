defmodule Mix.Tasks.ParallelUi.Report do
  @moduledoc """
  Print the `Platform.ParallelUI` ledger: every legacy surface kept alive for
  the old UI, grouped by kind, with its marker locations and the cutover steps
  (task 01a156cb).

  The final cutover task is planned from this output: one stage per kind, each
  step copied verbatim from the `Cutover steps` list.

  The exit code is non-zero when `Platform.ParallelUI.check/2` fails, that is
  when an entry has no marker (`unmarked`) or a marker names no entry
  (`unregistered`), so a wrapper can act on it without parsing output.

  ## DB-free

  The report reads only the ledger and the marker scan of the source tree. It
  does not start the application or touch Postgres, so it runs in a bare
  container. Column labels (`COMMENT ON COLUMN ... IS 'parallel-ui: ...'`) are
  therefore NOT checked here; `test/platform/parallel_ui_columns_test.exs`
  enforces them.

  ## Usage

      mix parallel_ui.report

  ## Example output

  With zero entries (main before the first rung lands):

      Parallel-UI ledger: 0 entries
      files scanned: 1551

  With one `:event` entry:

      Parallel-UI ledger: 1 entries
      files scanned: 1551

      ## event

      - task-board-probe
          legacy:        the {:probe, _} broadcast the old task board listens for
          replacement:   the {:task_changed, _} broadcast
          introduced_by: 01a156cb-71f8-7000-89f2-7842bacbdbf1
          markers:       lib/platform/tasks.ex:120

      Cutover steps — event

      - task-board-probe: stop broadcasting {:probe, _}

  On failure the report ends with an `UNMARKED` and/or `UNREGISTERED` list
  (the latter with `path:line`) and the task exits 1.

  Paths are relative to `apps/platform`.
  """
  use Mix.Task

  alias Platform.ParallelUI
  alias Platform.ParallelUI.Markers

  @shortdoc "Print the parallel-UI debt ledger and its cutover steps."

  @requirements ["compile"]

  @impl true
  def run(_args) do
    entries = ParallelUI.entries()
    scan = Markers.scan()

    Mix.shell().info(IO.iodata_to_binary(render(entries, scan)))

    case ParallelUI.check(entries, scan.markers) do
      :ok -> :ok
      {:error, _} -> exit({:shutdown, 1})
    end
  end

  @doc """
  Renders the report for `entries` and a `Markers.scan/1` result. Pure, so
  tests can feed synthetic entries. Includes the failure lists when
  `ParallelUI.check/2` fails; `run/1` decides the exit code.
  """
  @spec render([ParallelUI.entry()], Markers.scan_result()) :: iodata()
  def render(entries, %{markers: markers, files_scanned: files_scanned}) do
    by_kind = Enum.group_by(entries, & &1.kind)
    kinds = Enum.filter(ParallelUI.kinds(), &Map.has_key?(by_kind, &1))

    header = [
      "Parallel-UI ledger: #{length(entries)} entries\n",
      "files scanned: #{files_scanned}\n"
    ]

    groups =
      Enum.map(kinds, fn kind ->
        ["\n## #{kind}\n\n", Enum.map(by_kind[kind], &render_entry(&1, markers))]
      end)

    cutover =
      Enum.map(kinds, fn kind ->
        [
          "\nCutover steps — #{kind}\n\n",
          Enum.map(by_kind[kind], &"- #{&1.id}: #{&1.cutover}\n")
        ]
      end)

    [header, groups, cutover, render_failure(ParallelUI.check(entries, markers))]
  end

  defp render_entry(entry, markers) do
    locations =
      case Enum.filter(markers, &(&1.id == entry.id)) do
        [] -> "(none)"
        found -> Enum.map_join(found, ", ", &"#{&1.path}:#{&1.line}")
      end

    [
      "- #{entry.id}\n",
      "    legacy:        #{entry.legacy}\n",
      "    replacement:   #{entry.replacement}\n",
      "    introduced_by: #{entry.introduced_by}\n",
      "    markers:       #{locations}\n"
    ]
  end

  defp render_failure(:ok), do: []

  defp render_failure({:error, %{unmarked: unmarked, unregistered: unregistered}}) do
    [
      "\nFAILED: the ledger and the markers disagree.\n",
      if(unmarked == [],
        do: [],
        else: ["\nUNMARKED (entry with no marker)\n", Enum.map(unmarked, &"- #{&1}\n")]
      ),
      if(unregistered == [],
        do: [],
        else: [
          "\nUNREGISTERED (marker with no entry)\n",
          Enum.map(unregistered, &"- #{&1.id} at #{&1.path}:#{&1.line}\n")
        ]
      )
    ]
  end
end

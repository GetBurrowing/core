defmodule Mix.Tasks.ParallelUi.ReportTest do
  @moduledoc """
  Tests for `mix parallel_ui.report` (task 01a156cb).

  `render/2` is driven with one synthetic entry per kind, declared in REVERSE
  `kinds/0` order, so a report that grouped in declaration order instead of
  `kinds/0` order would fail. `run/1` is driven once against the live tree:
  main carries zero entries, so it must print the 0-entries line and return
  without exiting.

  `async: false`: `run/1` writes through `Mix.shell()`, which is global.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ParallelUi.Report
  alias Platform.ParallelUI

  @introduced_by "01a156cb-71f8-7000-89f2-7842bacbdbf1"

  defp entry(kind) do
    id = "probe-#{kind |> Atom.to_string() |> String.replace("_", "-")}"

    base = %{
      id: id,
      kind: kind,
      legacy: "legacy #{kind}",
      replacement: "replacement #{kind}",
      introduced_by: @introduced_by,
      cutover: "remove the #{kind} shim {#{id}, _} — step for #{kind}"
    }

    if kind == :column, do: Map.merge(base, %{table: "tasks", column: "title"}), else: base
  end

  defp marker(entry, line), do: %{id: entry.id, path: "lib/platform/probe.ex", line: line}

  defp positions(out, needles), do: Enum.map(needles, &(:binary.match(out, &1) |> elem(0)))

  describe "render/2" do
    test "groups in kinds/0 order and copies cutover strings verbatim" do
      entries = ParallelUI.kinds() |> Enum.reverse() |> Enum.map(&entry/1)
      markers = entries |> Enum.with_index(10) |> Enum.map(fn {e, l} -> marker(e, l) end)

      out = IO.iodata_to_binary(Report.render(entries, %{markers: markers, files_scanned: 7}))

      assert out =~ "Parallel-UI ledger: 5 entries\n"
      assert out =~ "files scanned: 7\n"

      group_heads = Enum.map(ParallelUI.kinds(), &"\n## #{&1}\n")
      group_pos = positions(out, group_heads)
      assert group_pos == Enum.sort(group_pos)

      step_heads = Enum.map(ParallelUI.kinds(), &"\nCutover steps — #{&1}\n")
      step_pos = positions(out, step_heads)
      assert step_pos == Enum.sort(step_pos)
      assert List.last(group_pos) < hd(step_pos)

      for e <- entries do
        assert out =~ "- #{e.id}: #{e.cutover}\n"
        assert out =~ "    legacy:        #{e.legacy}\n"
        assert out =~ "    replacement:   #{e.replacement}\n"
        assert out =~ "    introduced_by: #{@introduced_by}\n"
      end

      for m <- markers do
        assert out =~ "- #{m.id}\n" <> "    legacy:"
        assert out =~ "markers:       lib/platform/probe.ex:#{m.line}\n"
      end

      refute out =~ "FAILED"
    end

    test "each entry sits under its own kind's group" do
      entries = Enum.map(ParallelUI.kinds(), &entry/1)
      markers = Enum.map(entries, &marker(&1, 1))
      out = IO.iodata_to_binary(Report.render(entries, %{markers: markers, files_scanned: 1}))

      for {e, next} <- Enum.zip(entries, tl(ParallelUI.kinds()) ++ [:cutover]) do
        [_, after_head] = String.split(out, "\n## #{e.kind}\n", parts: 2)

        section =
          case next do
            :cutover -> after_head |> String.split("\nCutover steps") |> hd()
            kind -> after_head |> String.split("\n## #{kind}\n") |> hd()
          end

        assert section =~ "- #{e.id}\n"
      end
    end

    test "zero entries prints the 0-entries line and no groups" do
      out = IO.iodata_to_binary(Report.render([], %{markers: [], files_scanned: 3}))

      assert out == "Parallel-UI ledger: 0 entries\nfiles scanned: 3\n"
    end

    test "an unmarked entry and an unregistered marker are listed as failures" do
      e = entry(:event)
      orphan = %{id: "orphan-probe", path: "lib/platform/other.ex", line: 42}

      out = IO.iodata_to_binary(Report.render([e], %{markers: [orphan], files_scanned: 2}))

      assert out =~ "markers:       (none)\n"
      assert out =~ "FAILED"
      assert out =~ "UNMARKED (entry with no marker)\n- probe-event\n"

      assert out =~
               "UNREGISTERED (marker with no entry)\n- orphan-probe at lib/platform/other.ex:42\n"
    end
  end

  describe "run/1" do
    # On main the ledger is empty, so this is the 0-entries line. Written
    # against the live count so the first rung's entry does not break it.
    test "on the live tree prints the entry count and does not exit" do
      out = capture_io(fn -> assert Report.run([]) == :ok end)

      assert out =~ "Parallel-UI ledger: #{length(ParallelUI.entries())} entries\n"
      refute out =~ "FAILED"
    end
  end
end

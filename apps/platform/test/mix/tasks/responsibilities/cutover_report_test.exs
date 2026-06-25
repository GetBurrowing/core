defmodule Mix.Tasks.Responsibilities.CutoverReportTest do
  @moduledoc """
  Tests for the M8 stage 6 `mix responsibilities.cutover_report` task.
  We focus on the `format_report/1` helper because driving the full
  `run/1` requires `Application.ensure_all_started(:platform)` which is
  expensive and orthogonal to what the task actually owes operators —
  legible, divergence-aware formatting.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Responsibilities.CutoverReport

  describe "format_report/1" do
    test "renders the header, as_of line, and one block per key in sorted order" do
      report = %{
        as_of: ~D[2026-06-24],
        keys: %{
          "memory.daily_summary" => %{router: 1, legacy: 1, divergence_count: 0},
          "memory.dreaming" => %{router: 2, legacy: 2, divergence_count: 0}
        }
      }

      out = CutoverReport.format_report(report)

      assert out =~ "Responsibilities cutover report"
      assert out =~ "as_of: 2026-06-24"
      assert out =~ "memory.daily_summary"
      assert out =~ "memory.dreaming"
      assert out =~ "router:           1"
      assert out =~ "router:           2"
      assert out =~ "legacy:           1"
      assert out =~ "divergence_count: 0"

      # Sort ordering — daily_summary comes before dreaming.
      assert :binary.match(out, "memory.daily_summary") <
               :binary.match(out, "memory.dreaming")
    end

    test "surfaces non-zero divergence in the rendered output" do
      report = %{
        as_of: ~D[2026-06-24],
        keys: %{
          "memory.daily_summary" => %{router: 0, legacy: 1, divergence_count: 1}
        }
      }

      out = CutoverReport.format_report(report)

      assert out =~ "divergence_count: 1"
    end

    test "tolerates empty key maps" do
      report = %{as_of: ~D[2026-06-24], keys: %{}}
      out = CutoverReport.format_report(report)

      assert out =~ "Responsibilities cutover report"
      assert out =~ "as_of: 2026-06-24"
    end

    test "non-conforming input renders the empty fallback" do
      assert CutoverReport.format_report(%{}) == "(empty report)\n"
      assert CutoverReport.format_report(nil) == "(empty report)\n"
    end
  end
end

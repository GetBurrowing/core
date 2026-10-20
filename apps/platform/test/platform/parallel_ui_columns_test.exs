defmodule Platform.ParallelUI.ColumnsTest do
  @moduledoc """
  Column-label guard for `:column` entries of `Platform.ParallelUI` (task
  01a156cb).

  Main carries zero entries and zero labels, so the live check alone would be
  green whether or not `Columns.labelled/1` can find anything. The probe tests
  are the control: inside the sandbox transaction they create their own table,
  comment its columns, and assert the reader returns exactly the
  `parallel-ui:` column comment on it, and not the table-level comment, the
  ordinary column comment, or the same label in a schema outside the search
  path.

  The probe uses a table created in the transaction, never a comment on a
  shared table such as `tasks`: `COMMENT ON` locks its target, and main has
  just fixed a lock wait under concurrent tests (#1287). Everything rolls back
  with the sandbox.
  """

  use Platform.DataCase, async: true

  alias Platform.ParallelUI
  alias Platform.ParallelUI.Columns

  @probe_entry %{
    id: "probe-col",
    kind: :column,
    legacy: "parallel_ui_probe.x, still read by the old UI",
    replacement: "parallel_ui_probe.y",
    introduced_by: "01a156cb-71f8-7000-89f2-7842bacbdbf1",
    cutover: "drop column parallel_ui_probe.x",
    table: "parallel_ui_probe",
    column: "x"
  }

  @probe_label %{table: "parallel_ui_probe", column: "x", id: "probe-col"}

  defp create_probe!(comment) do
    Repo.query!("CREATE TABLE parallel_ui_probe (x int, y int, z int)")
    Repo.query!("COMMENT ON COLUMN parallel_ui_probe.x IS '#{comment}'")
    # Decoys: a table-level comment that carries the prefix, and a column
    # comment that does not.
    Repo.query!("COMMENT ON TABLE parallel_ui_probe IS 'parallel-ui: probe-table'")
    Repo.query!("COMMENT ON COLUMN parallel_ui_probe.y IS 'ordinary column comment'")
    # Decoy: the same label on a column outside current_schemas(false).
    Repo.query!("CREATE SCHEMA parallel_ui_probe_other")
    Repo.query!("CREATE TABLE parallel_ui_probe_other.parallel_ui_probe (x int)")

    Repo.query!(
      "COMMENT ON COLUMN parallel_ui_probe_other.parallel_ui_probe.x IS 'parallel-ui: other-schema'"
    )
  end

  # Labels on the probe table only, so a real `:column` entry landing later
  # does not break the exact-row assertion.
  defp probe_labels do
    Enum.filter(Columns.labelled(), &String.starts_with?(&1.table, "parallel_ui_probe"))
  end

  describe "check/2" do
    test "an entry labelled on its exact column passes" do
      assert Columns.check([@probe_entry], [@probe_label]) == :ok
    end

    test "an entry with no label anywhere is unlabelled" do
      assert {:error, %{unlabelled: ["probe-col"], unregistered: [], mismatched: []}} =
               Columns.check([@probe_entry], [])
    end

    test "a label naming no registered :column entry is unregistered" do
      label = %{table: "tasks", column: "title", id: "unregistered-col"}

      assert {:error, %{unlabelled: [], unregistered: [^label], mismatched: []}} =
               Columns.check([], [label])
    end

    test "a label naming an entry of another kind is unregistered" do
      event = %{@probe_entry | kind: :event} |> Map.drop([:table, :column])
      label = %{@probe_label | id: "probe-col"}

      assert {:error, %{unregistered: [^label]}} = Columns.check([event], [label])
    end

    test "a label on the wrong column is mismatched" do
      label = %{@probe_label | column: "y"}

      assert {:error, %{unlabelled: [], unregistered: [], mismatched: [mismatch]}} =
               Columns.check([@probe_entry], [label])

      assert mismatch == %{
               id: "probe-col",
               expected: %{table: "parallel_ui_probe", column: "x"},
               actual: %{table: "parallel_ui_probe", column: "y"}
             }
    end

    test "non-column entries are ignored" do
      event = %{@probe_entry | kind: :event} |> Map.drop([:table, :column])
      assert Columns.check([event], []) == :ok
    end

    test "nothing on either side passes" do
      assert Columns.check([], []) == :ok
    end
  end

  describe "labelled/1 (positive control)" do
    test "returns exactly the parallel-ui column comment on the probe table" do
      create_probe!("parallel-ui: probe-col")

      assert probe_labels() == [@probe_label]
      assert Columns.check([@probe_entry], probe_labels()) == :ok
    end

    test "an unregistered label on the probe table is reported" do
      create_probe!("parallel-ui: unregistered-col")

      label = %{@probe_label | id: "unregistered-col"}
      assert probe_labels() == [label]

      assert {:error, %{unlabelled: [], unregistered: [^label], mismatched: []}} =
               Columns.check([], probe_labels())
    end
  end

  describe "live" do
    test "every :column entry is labelled and every label is registered" do
      assert Columns.check(ParallelUI.entries(), Columns.labelled()) == :ok
    end
  end
end

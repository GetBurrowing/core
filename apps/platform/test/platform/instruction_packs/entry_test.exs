defmodule Platform.InstructionPacks.EntryTest do
  use ExUnit.Case, async: true
  alias Platform.InstructionPacks.Entry

  test "local collision remains local even if byte-identical to vendor" do
    assert {:keep, "same", %{effective_version: nil, conflict: %{"local" => "same"}}} =
             Entry.reconcile(nil, "same", "same", 1)
  end

  test "local-hash guard preserves changed and deleted content" do
    baseline = %Entry{
      vendor_content: "old",
      vendor_hash: Entry.hash("old"),
      applied_hash: Entry.hash("old"),
      effective_version: 1
    }

    for local <- ["my edit", nil] do
      assert {:keep, ^local, %{effective_version: 1, conflict: %{"base" => "old"}}} =
               Entry.reconcile(baseline, local, "new", 2)
    end

    assert {:write, "new", %{effective_version: 2, conflict: nil}} =
             Entry.reconcile(baseline, "old", "new", 2)
  end

  test "retirement preserves local data and only retires owned values" do
    baseline = %Entry{
      vendor_content: "old",
      applied_hash: Entry.hash("old"),
      effective_version: 1
    }

    assert {:write, "", %{retired: true, conflict: nil}} =
             Entry.reconcile(baseline, "old", nil, 2)

    assert {:keep, "my edit", %{retired: true}} = Entry.reconcile(baseline, "my edit", nil, 2)
  end
end

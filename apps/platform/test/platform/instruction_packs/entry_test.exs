defmodule Platform.InstructionPacks.EntryTest do
  use ExUnit.Case, async: true
  alias Platform.InstructionPacks.Entry

  test "conflict token binds the exact base, local, incoming and version shown to the owner" do
    entry = %Entry{
      conflict: %{
        "base" => "old",
        "local" => "mine",
        "incoming" => "new",
        "incoming_version" => 2
      }
    }

    assert Entry.conflict_token(entry) ==
             "ff146a6975c2662c4064f90bf401d5ba1f769b122079c916140f907f22965ea0"

    changed = %{entry | conflict: Map.put(entry.conflict, "incoming", "unseen")}
    refute Entry.conflict_token(changed) == Entry.conflict_token(entry)
  end

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

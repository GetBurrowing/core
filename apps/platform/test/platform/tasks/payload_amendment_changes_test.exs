defmodule Platform.Tasks.PayloadAmendmentChangesTest do
  @moduledoc """
  The pure changed-fields helper the execution-space notice (stage 2) and the
  task page's amended-case marker (stage 3) both read (task 01a0e266).
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks.PayloadAmendmentChanges, as: C
  alias Platform.Tasks.PayloadAmendmentNotice

  @v0 %{"setup" => "s0", "actions" => "a0", "expected" => "e0"}
  @v1 %{"setup" => "s0", "actions" => "a1", "expected" => "e0"}
  @v2 %{"setup" => "s0", "actions" => "a1", "expected" => "e2"}

  defp validation(entries, current),
    do: %{payload_amendments: entries, evaluation_payload: current}

  defp entry(prior, by \\ "p-agent", type \\ "agent"),
    do: %{"prior_payload" => prior, "amended_by" => by, "actor_type" => type, "reason" => "r"}

  test "each entry is compared against the text that replaced it, oldest first" do
    v = validation([entry(@v0), entry(@v1)], @v2)

    assert [%{number: 1, changed: ["actions"]}, %{number: 2, changed: ["expected"]}] =
             C.history(v)
  end

  test "amended_fields is the union over ALL entries, in setup/actions/expected order" do
    assert C.amended_fields(validation([entry(@v0), entry(@v1)], @v2)) == ["actions", "expected"]
  end

  test "a field changed and later changed back still counts as amended" do
    back = %{"setup" => "s0", "actions" => "a0", "expected" => "e0"}
    assert C.amended_fields(validation([entry(@v0), entry(@v1)], back)) == ["actions"]
  end

  test "a never-amended validation has no history and no amended fields" do
    assert C.history(validation([], @v0)) == []
    assert C.history(validation(nil, @v0)) == []
    assert C.amended_fields(validation([], @v0)) == []
  end

  test "atom and string keys compare equal; a missing key compares as nil" do
    assert C.changed_fields(%{setup: "s", actions: "a"}, %{"setup" => "s", "actions" => "a"}) ==
             []

    assert C.changed_fields(%{"setup" => "s"}, %{"setup" => "s", "expected" => "e"}) == [
             "expected"
           ]
  end

  test "the notice lists exactly the fields the page marks for the same entry" do
    # The notice for amendment n compares the entry's prior_payload with the
    # payload the row held right after that amendment; history/1 recomputes it
    # from the next entry. Both must name the same fields.
    entries = [entry(@v0), entry(@v1)]
    [first, second] = C.history(validation(entries, @v2))

    assert PayloadAmendmentNotice.changed_fields(@v0, @v1) == first.changed
    assert PayloadAmendmentNotice.changed_fields(@v1, @v2) == second.changed
  end

  test "amended_by_label names the operator path, else the amender label" do
    assert C.amended_by_label(entry(@v0, "operator:test", "system")) == "system (no agent)"
    assert C.amended_by_label(entry(@v0, "p-agent", "agent")) == "p-agent"
    assert C.amended_by_label(%{}) == "system (no agent)"
  end
end

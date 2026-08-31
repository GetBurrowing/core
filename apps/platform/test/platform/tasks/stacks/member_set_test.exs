defmodule Platform.Tasks.Stacks.MemberSetTest do
  @moduledoc """
  Pure unit tests — no Repo, no fixtures. Every "satisfied" case here has
  its "not satisfied" twin, because a predicate exercised only where it
  returns true documents nothing about where it returns false.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks.Stacks.MemberSet

  # Minimal member shape: the predicates read only these three fields.
  defp member(status, opts \\ []) do
    %{
      status: status,
      deleted_at: Keyword.get(opts, :deleted_at),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  describe "excluded_statuses/0" do
    test "is exactly cancelled and done" do
      assert MemberSet.excluded_statuses() == ["cancelled", "done"]
    end

    test "CommencementGate's member queries are driven by this same list" do
      # The gate no longer holds its own copy; if this file stops matching
      # the gate's source the delegation was undone.
      source = File.read!("lib/platform/tasks/stacks/commencement_gate.ex")

      assert String.contains?(source, "^MemberSet.excluded_statuses()")
      refute String.contains?(source, "@excluded_member_statuses ~w(")
    end
  end

  describe "counts_as_gate_member?/1" do
    test "true for a live member in a working status" do
      assert MemberSet.counts_as_gate_member?(member("in_progress"))
      assert MemberSet.counts_as_gate_member?(member("stack_pending"))
      assert MemberSet.counts_as_gate_member?(member("blocked"))
      assert MemberSet.counts_as_gate_member?(member("backlog"))
    end

    test "false for each excluded status" do
      refute MemberSet.counts_as_gate_member?(member("cancelled"))
      refute MemberSet.counts_as_gate_member?(member("done"))
    end

    test "false for a soft-deleted member even in a counting status" do
      live = member("in_progress")
      deleted = member("in_progress", deleted_at: ~U[2026-08-30 00:00:00Z])

      # Both sides asserted: the only difference between them is deleted_at.
      assert MemberSet.counts_as_gate_member?(live)
      refute MemberSet.counts_as_gate_member?(deleted)
    end
  end

  describe "counts_as_pending?/1" do
    test "true for a member that still owes work" do
      assert MemberSet.counts_as_pending?(member("in_progress"))
      assert MemberSet.counts_as_pending?(member("stack_pending"))
      assert MemberSet.counts_as_pending?(member("in_review"))
      assert MemberSet.counts_as_pending?(member("blocked"))
    end

    test "false for done" do
      refute MemberSet.counts_as_pending?(member("done"))
    end

    test "false for cancelled — this is the half pending_members/1 gets wrong today" do
      refute MemberSet.counts_as_pending?(member("cancelled"))
    end

    test "false for a soft-deleted member" do
      assert MemberSet.counts_as_pending?(member("in_review"))

      refute MemberSet.counts_as_pending?(
               member("in_review", deleted_at: ~U[2026-08-30 00:00:00Z])
             )
    end

    test "agrees with counts_as_gate_member?/1 on every status it is given" do
      for status <- ~w(backlog planning stack_pending in_progress blocked in_review deploying
                       done cancelled) do
        m = member(status)

        assert MemberSet.counts_as_pending?(m) == MemberSet.counts_as_gate_member?(m),
               "gate and completion disagree about #{status} — that disagreement IS the bug " <>
                 "this module exists to remove"
      end
    end
  end

  describe "dependency_satisfied?/1 — the cancelled arm" do
    test "a cancelled dependency is satisfied: it can never acquire a stamp" do
      assert MemberSet.dependency_satisfied?(member("cancelled"))
    end

    test "a cancelled dependency is satisfied even with no metadata at all" do
      assert MemberSet.dependency_satisfied?(%{status: "cancelled", metadata: nil})
    end

    test "a blocked dependency is NOT satisfied — it is still expected to run" do
      refute MemberSet.dependency_satisfied?(member("blocked"))
    end

    test "an in_progress dependency is NOT satisfied" do
      refute MemberSet.dependency_satisfied?(member("in_progress"))
    end

    test "cancelled is the ONLY status that releases without a stamp" do
      # Without this the cancelled arm is indistinguishable from
      # "everything clears".
      for status <-
            ~w(backlog planning stack_pending in_progress blocked in_review deploying done) do
        refute MemberSet.dependency_satisfied?(member(status)),
               "#{status} released a dependent without a rollup stamp"
      end

      assert MemberSet.dependency_satisfied?(member("cancelled"))
    end
  end

  describe "dependency_satisfied?/1 — the landed arm" do
    test "done WITHOUT a rollup stamp is NOT satisfied" do
      # Deliberate: `member_landed_on_rollup?/1` is also StackDeployer's
      # merge predicate. Accepting done-without-a-stamp there would let the
      # rollup merge past a branch that was never merged in.
      refute MemberSet.dependency_satisfied?(member("done"))
      refute MemberSet.dependency_satisfied?(member("done", metadata: %{}))
      refute MemberSet.dependency_satisfied?(member("done", metadata: %{"other" => "x"}))
    end

    test "done WITH a stamp IS satisfied — the stamp is the whole difference" do
      refute MemberSet.dependency_satisfied?(member("done"))

      assert MemberSet.dependency_satisfied?(
               member("done", metadata: %{"merged_into_rollup_at" => "2026-08-30T00:00:00Z"})
             )
    end

    test "in_review with a MAP stamp is satisfied" do
      assert MemberSet.dependency_satisfied?(
               member("in_review",
                 metadata: %{
                   "merged_into_rollup_at" => %{
                     "at" => "2026-08-30T00:00:00Z",
                     "sha" => "deadbeef"
                   }
                 }
               )
             )
    end

    test "in_review with a bare ISO8601-string stamp is satisfied (permissive shape)" do
      assert MemberSet.dependency_satisfied?(
               member("in_review", metadata: %{"merged_into_rollup_at" => "2026-08-30T00:00:00Z"})
             )
    end

    test "in_review WITHOUT a stamp is NOT satisfied" do
      refute MemberSet.dependency_satisfied?(member("in_review"))
    end

    test "a stamp on a status outside in_review|deploying|done does not satisfy" do
      stamped = %{"merged_into_rollup_at" => "2026-08-30T00:00:00Z"}

      refute MemberSet.dependency_satisfied?(member("in_progress", metadata: stamped))
      refute MemberSet.dependency_satisfied?(member("blocked", metadata: stamped))
      assert MemberSet.dependency_satisfied?(member("deploying", metadata: stamped))
    end

    test "a nil-valued stamp key does not satisfy" do
      refute MemberSet.dependency_satisfied?(
               member("done", metadata: %{"merged_into_rollup_at" => nil})
             )
    end
  end
end

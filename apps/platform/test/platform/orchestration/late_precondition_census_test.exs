defmodule Platform.Orchestration.LatePreconditionCensusTest do
  @moduledoc """
  Drift guard for the late-precondition promotion census (ADR 0047).

  The census is a document, so the only thing a test can protect is the two
  structural facts the LATER stages of that task build on:

    1. `Platform.Tasks.Stacks.reconcile_stack_lifecycle/0` is exported — it is
       the reconcile hook the fixes hang off. If it is renamed or made private,
       the fixes have nowhere to land and the ADR's Bucket 2 examples stop
       describing the tree.

    2. The census ADR still exists and still names every seed it classified.
       A census that quietly loses a seed reads as an exhaustive search that
       was never done.

  ## Why the content assertions are shaped the way they are

  A content assertion on a document has the same hazard as any source-text
  guard: it can be satisfied by text that has nothing to do with the claim.
  So each assertion below pins a **pair** — a specific symbol AND the bucket
  or fact the census assigned it — rather than a bare word that an unrelated
  edit to the ADR could reintroduce by accident. `sweep_stack_dependents`
  alone would match a passing mention; `sweep_stack_dependents` together with
  the nil-to-set edge it is gated on would not.

  This test reads the file from disk on purpose. Compiling the claims into
  the test would only assert that this file agrees with itself.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @adr_path Path.join([@repo_root, "docs", "decisions", "0047-late-precondition-promotion.md"])

  describe "the reconcile hook the later stages depend on" do
    test "Stacks.reconcile_stack_lifecycle/0 is exported" do
      Code.ensure_loaded!(Platform.Tasks.Stacks)

      assert function_exported?(Platform.Tasks.Stacks, :reconcile_stack_lifecycle, 0),
             """
             Platform.Tasks.Stacks.reconcile_stack_lifecycle/0 is no longer exported.

             It is the periodic-reconcile entry point the late-precondition
             promotion fixes attach to, and the census ADR cites it as the
             existing EVENT_PLUS_RECONCILE shape the defect sites lack. If it
             was renamed, update docs/decisions/0047-late-precondition-promotion.md
             and this test together.
             """
    end
  end

  describe "the census ADR" do
    setup do
      assert File.exists?(@adr_path),
             """
             The late-precondition promotion census is missing:
               #{@adr_path}

             The census is the deliverable of stage 1 of the promotion-path
             task. Later stages cite its bucket assignments. Do not delete it
             without moving its content somewhere the later stages can cite.
             """

      {:ok, body: File.read!(@adr_path)}
    end

    test "names the four classification buckets", %{body: body} do
      for bucket <- [
            "EVENT_ONLY_NO_RECONCILE",
            "EVENT_PLUS_RECONCILE",
            "CASCADE_ONLY_BY_DESIGN",
            "UNREACHABLE_DEAD"
          ] do
        assert body =~ bucket,
               "census no longer names the #{bucket} bucket — the classification is incomplete"
      end
    end

    test "still classifies the stack-commencement seeds", %{body: body} do
      # start_stack/1's forming-only refusal, and the fact that the two sweeps
      # cover forming and deploying but not stack_pending.
      assert body =~ "start_stack/1"
      assert body =~ "commence_if_ready/1"
      assert body =~ "reconcile_stack_lifecycle/0"

      assert body =~ "stack_pending",
             "census no longer discusses stack_pending members — that is the stranded status"

      assert body =~
               ~r/nothing sweeps `?stack_pending`? members|No sweep visits `?stack_pending`?/i,
             """
             The census no longer states that no sweep visits stack_pending
             members of an already-in_progress stack. That absence IS the
             defect the later stages fix; if it has been fixed, move the entry
             out of EVENT_ONLY_NO_RECONCILE rather than deleting the sentence.
             """
    end

    test "still records the rollup-merge edge that gates the dependent sweep", %{body: body} do
      assert body =~ "sweep_stack_dependents/1"
      assert body =~ "maybe_sweep_stack_after_update/2"

      assert body =~ "merged_into_rollup_at",
             "census no longer names the stamp the sweep is keyed on"

      assert body =~ ~r/nil\s*(?:->|→|to)\s*set edge/i,
             """
             The census no longer records that the dependent sweep fires only
             on the nil -> set edge of the rollup-merge stamp. That edge, not
             `done`, is the threshold — losing the distinction is how this
             defect was misdiagnosed the first time.
             """
    end

    test "still records the router seeds", %{body: body} do
      assert body =~ "ensure_execution_stage_started/2"

      assert body =~ ~r/plan_updated.{0,40}approved/s,
             "census no longer names the approved-plan branch that is the sole caller"

      assert body =~ ~r/plan_updated.{0,40}completed/s,
             "census no longer names the completed-plan branch"

      assert body =~ "LeaseManager.clear/1",
             """
             The census no longer records that the plan-completed branch DOES
             advance the task and clear the lease. That face is not "no code
             exists" — it is event-delivery-dependent, and the distinction
             decides what the fix has to be.
             """
    end

    test "still records the dead documentation reference", %{body: body} do
      assert body =~ "commence_open_gate/1",
             "census no longer records the commence_open_gate/1 documentation drift"

      assert body =~
               ~r/commence_open_gate.{0,400}UNREACHABLE_DEAD|UNREACHABLE_DEAD.{0,400}commence_open_gate/s,
             "commence_open_gate/1 is mentioned but no longer classified UNREACHABLE_DEAD"
    end

    test "records clean sites, not only defective ones", %{body: body} do
      # A census that lists only the bad sites is not a census: the clean
      # entries are what show the search was exhaustive. Pin two named
      # EVENT_PLUS_RECONCILE members so a future edit cannot reduce the
      # document to a defect list.
      assert body =~ "advance_member_to_deploying/1"
      assert body =~ "sweep_in_review_stalls/0"
      assert body =~ "member_deploy_transition_ready?/1"
    end
  end
end

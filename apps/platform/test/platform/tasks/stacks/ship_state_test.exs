defmodule Platform.Tasks.Stacks.ShipStateTest do
  @moduledoc """
  Pure unit tests for the ADR 0045 decision 7 predicates. No DB — every
  fixture is a struct built in memory.

  The load-bearing cases are the NEGATIVE ones: a `done` stack with no
  `rollup_pr` at all (the manual-ship lane, `stack_deployer.ex:1608-1621`)
  and a `done` stack whose rollup PR is open but unmerged must both be
  NOT shipped. A predicate tested only where it fires is half a test.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks.Stack
  alias Platform.Tasks.Stacks.ShipState

  defp stack(status, metadata) do
    %Stack{
      id: "01a05393-0000-7000-0000-000000000001",
      slug: "auth-hardening",
      status: status,
      metadata: metadata
    }
  end

  describe "shipped?/1" do
    test "TRUE for a done stack whose rollup PR carries merged_at" do
      s =
        stack("done", %{
          "rollup_pr" => %{"number" => 123, "merged_at" => "2026-08-01T00:00:00Z"}
        })

      assert s.status == "done"
      assert ShipState.shipped?(s)
    end

    test "TRUE for a done stack carrying a rollup_merge stamp and no rollup_pr" do
      s = stack("done", %{"rollup_merge" => %{"sha" => "abc123", "at" => "2026-08-01T00:00:00Z"}})

      assert s.status == "done"
      refute Map.has_key?(s.metadata, "rollup_pr")
      assert ShipState.shipped?(s)
    end

    test "FALSE for a done stack with empty metadata (the manual-ship lane)" do
      s = stack("done", %{})

      assert s.status == "done"
      refute ShipState.shipped?(s)
    end

    test "FALSE for a done stack whose rollup PR is open but not merged" do
      s = stack("done", %{"rollup_pr" => %{"number" => 123, "merged_at" => nil}})

      assert s.status == "done"
      assert get_in(s.metadata, ["rollup_pr", "number"]) == 123
      refute ShipState.shipped?(s)
    end

    test "FALSE for an empty rollup_merge map — the stamp must carry content" do
      refute ShipState.shipped?(stack("done", %{"rollup_merge" => %{}}))
    end

    test "FALSE for an in_progress stack, and TRUE for a merged one regardless of status" do
      refute ShipState.shipped?(stack("in_progress", %{}))

      assert ShipState.shipped?(
               stack("in_review", %{"rollup_pr" => %{"merged_at" => "2026-08-01T00:00:00Z"}})
             )
    end

    test "tolerates nil metadata and a nil subject" do
      refute ShipState.shipped?(stack("done", nil))
      refute ShipState.shipped?(nil)
    end

    test "accepts a plain metadata map" do
      assert ShipState.shipped?(%{"rollup_merge" => %{"sha" => "abc"}})
      refute ShipState.shipped?(%{})
    end
  end

  describe "conflict_held?/1" do
    test "TRUE for a blocked stack with a recorded conflict" do
      s =
        stack("blocked", %{
          "conflict" => %{"member_task_id" => "t1", "files" => ["apps/x.ex"]}
        })

      assert s.status == "blocked"
      assert ShipState.conflict_held?(s)
    end

    test "FALSE for a blocked stack with no conflict metadata" do
      s = stack("blocked", %{})

      assert s.status == "blocked"
      refute ShipState.conflict_held?(s)
    end

    test "FALSE for an empty conflict map, a nil conflict, and a non-map conflict" do
      refute ShipState.conflict_held?(stack("blocked", %{"conflict" => %{}}))
      refute ShipState.conflict_held?(stack("blocked", %{"conflict" => nil}))
      refute ShipState.conflict_held?(stack("blocked", %{"conflict" => "yes"}))
    end

    test "FALSE for a shipped stack — the two predicates are independent" do
      s = stack("done", %{"rollup_pr" => %{"merged_at" => "2026-08-01T00:00:00Z"}})

      assert ShipState.shipped?(s)
      refute ShipState.conflict_held?(s)
    end
  end

  describe "ship_refusal_message/1" do
    test "states ADR 0045 decision 7 verbatim and names the slug and PR number" do
      msg =
        ShipState.ship_refusal_message(
          stack("done", %{
            "rollup_pr" => %{"number" => 123, "merged_at" => "2026-08-01T00:00:00Z"}
          })
        )

      assert msg =~ "post-ship changes are new individual tasks"
      assert msg =~ "auth-hardening"
      assert msg =~ "#123"
    end

    test "still names the slug and the decision when there is no rollup PR" do
      msg = ShipState.ship_refusal_message(stack("done", %{"rollup_merge" => %{"sha" => "abc"}}))

      assert msg =~ "post-ship changes are new individual tasks"
      assert msg =~ "auth-hardening"
      refute msg =~ "rollup PR #"
    end
  end
end

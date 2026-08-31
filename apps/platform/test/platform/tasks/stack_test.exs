defmodule Platform.Tasks.StackTest do
  @moduledoc """
  Changeset-level tests for `Platform.Tasks.Stack.changeset/2`'s
  status-regression guard (task 01a05393 stage 2, ADR 0045 decision 7).
  No DB — every fixture is a struct built in memory, and every test first
  asserts the fixture IS in the state the rule keys on, so "ends done"
  cannot be satisfied by a stack that was never done.

  Each arm is paired: where it FIRES and where it LOSES. A guard that
  froze every status forever would pass the fire-side assertions alone.
  """
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Platform.Tasks.Stack
  alias Platform.Tasks.Stacks.ShipState

  @stack_id "01a05393-0000-7000-0000-000000000002"

  defp stack(status, metadata) do
    %Stack{
      id: @stack_id,
      project_id: "01a05393-0000-7000-0000-0000000000aa",
      slug: "auth-hardening",
      name: "Auth hardening",
      rollup_branch: "stack/auth-hardening",
      status: status,
      metadata: metadata
    }
  end

  @shipped_meta %{
    "rollup_pr" => %{"number" => 123, "merged_at" => "2026-08-01T00:00:00Z"}
  }

  @conflict_meta %{
    "rollup_pr" => %{"number" => 123},
    "conflict" => %{"member_task_id" => "t1", "files" => ["lib/a.ex"], "at" => "2026-08-02"}
  }

  defp attach_telemetry(test_pid) do
    handler = "stack-test-#{inspect(test_pid)}-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :stacks, :status_regression_blocked],
        fn _event, measurements, meta, _ ->
          send(test_pid, {:regression_blocked, measurements, meta})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "arm A — a shipped done stack is terminal" do
    test "drops done -> in_progress on a shipped stack, with telemetry naming the reason" do
      attach_telemetry(self())
      s = stack("done", @shipped_meta)
      assert s.status == "done"
      assert ShipState.shipped?(s)

      cs = Stack.changeset(s, %{status: "in_progress"})

      assert cs.valid?
      refute Map.has_key?(cs.changes, :status)
      assert get_field(cs, :status) == "done"

      assert_receive {:regression_blocked, %{count: 1},
                      %{stack_id: @stack_id, from: "done", to: "in_progress", reason: :shipped}}
    end

    test "drops done -> planning-era statuses too (in_review, deploying)" do
      s = stack("done", %{"rollup_merge" => %{"sha" => "abc123"}})
      assert ShipState.shipped?(s)

      for to <- ~w(in_review deploying blocked) do
        cs = Stack.changeset(s, %{status: to})
        assert get_field(cs, :status) == "done", "expected #{to} to be dropped"
      end
    end

    test "LOSES: a done stack whose PR was never opened still moves (manual-ship lane)" do
      attach_telemetry(self())
      s = stack("done", %{})
      assert s.status == "done"
      refute ShipState.shipped?(s)

      cs = Stack.changeset(s, %{status: "in_progress"})

      assert cs.valid?
      assert get_change(cs, :status) == "in_progress"
      assert get_field(cs, :status) == "in_progress"
      refute_receive {:regression_blocked, _, _}, 50
    end

    test "LOSES: a done stack whose rollup PR is open but unmerged still moves" do
      s = stack("done", %{"rollup_pr" => %{"number" => 123, "merged_at" => nil}})
      refute ShipState.shipped?(s)

      cs = Stack.changeset(s, %{status: "in_progress"})
      assert get_field(cs, :status) == "in_progress"
    end

    test "LOSES: a shipped done stack still accepts abandoned (the terminal escape)" do
      attach_telemetry(self())
      s = stack("done", @shipped_meta)
      assert ShipState.shipped?(s)

      cs = Stack.changeset(s, %{status: "abandoned"})

      assert cs.valid?
      assert get_field(cs, :status) == "abandoned"
      refute_receive {:regression_blocked, _, _}, 50
    end

    test "LOSES: a shipped done stack re-asserting done is a no-op, not a block" do
      attach_telemetry(self())
      cs = Stack.changeset(stack("done", @shipped_meta), %{status: "done"})

      assert get_field(cs, :status) == "done"
      refute_receive {:regression_blocked, _, _}, 50
    end

    test "LOSES: a shipped done stack can still change non-status fields" do
      cs = Stack.changeset(stack("done", @shipped_meta), %{description: "shipped 2026-08"})

      assert cs.valid?
      assert get_change(cs, :description) == "shipped 2026-08"
    end

    test "LOSES: an in_progress stack still moves to in_review" do
      attach_telemetry(self())
      s = stack("in_progress", @shipped_meta)
      assert s.status == "in_progress"

      cs = Stack.changeset(s, %{status: "in_review"})

      assert get_field(cs, :status) == "in_review"
      refute_receive {:regression_blocked, _, _}, 50
    end
  end

  describe "arm B — a conflict-held blocked stack is sticky" do
    test "drops blocked -> in_review while metadata.conflict lingers" do
      attach_telemetry(self())
      s = stack("blocked", @conflict_meta)
      assert s.status == "blocked"
      assert ShipState.conflict_held?(s)

      cs = Stack.changeset(s, %{status: "in_review"})

      assert cs.valid?
      refute Map.has_key?(cs.changes, :status)
      assert get_field(cs, :status) == "blocked"

      assert_receive {:regression_blocked, %{count: 1},
                      %{
                        stack_id: @stack_id,
                        from: "blocked",
                        to: "in_review",
                        reason: :conflict_held
                      }}
    end

    test "drops blocked -> in_progress even when the changeset re-writes metadata WITH the conflict" do
      s = stack("blocked", @conflict_meta)
      assert ShipState.conflict_held?(s)

      still_conflicted = Map.put(@conflict_meta, "note", "touched")
      cs = Stack.changeset(s, %{status: "in_progress", metadata: still_conflicted})

      assert get_change(cs, :metadata) == still_conflicted
      assert get_field(cs, :status) == "blocked"
    end

    test "EXIT: a changeset clearing metadata.conflict AND moving the status goes through" do
      attach_telemetry(self())
      s = stack("blocked", @conflict_meta)
      assert s.status == "blocked"
      assert ShipState.conflict_held?(s)

      cleared = Map.delete(@conflict_meta, "conflict")
      cs = Stack.changeset(s, %{status: "in_review", metadata: cleared})

      assert cs.valid?
      assert get_change(cs, :status) == "in_review"
      assert get_field(cs, :status) == "in_review"
      refute ShipState.conflict_held?(get_field(cs, :metadata))
      refute_receive {:regression_blocked, _, _}, 50
    end

    test "EXIT: a nil conflict key counts as cleared" do
      s = stack("blocked", @conflict_meta)
      cs = Stack.changeset(s, %{status: "in_review", metadata: %{"conflict" => nil}})

      assert get_field(cs, :status) == "in_review"
    end

    test "LOSES: a blocked stack with NO conflict record still moves" do
      attach_telemetry(self())
      s = stack("blocked", %{"rollup_pr" => %{"number" => 123}})
      assert s.status == "blocked"
      refute ShipState.conflict_held?(s)

      cs = Stack.changeset(s, %{status: "in_review"})

      assert get_field(cs, :status) == "in_review"
      refute_receive {:regression_blocked, _, _}, 50
    end

    test "LOSES: a conflict-held stack can still be abandoned only via the exit, not bare" do
      # Bare abandon on a conflict-held stack is dropped: the conflict is
      # the reason it is blocked, and the changeset must say so to leave.
      s = stack("blocked", @conflict_meta)
      cs = Stack.changeset(s, %{status: "abandoned"})
      assert get_field(cs, :status) == "blocked"

      cs = Stack.changeset(s, %{status: "abandoned", metadata: %{}})
      assert get_field(cs, :status) == "abandoned"
    end
  end

  describe "existing forming arm is unchanged" do
    test "drops in_progress -> forming with the original telemetry shape" do
      attach_telemetry(self())
      cs = Stack.changeset(stack("in_progress", %{}), %{status: "forming"})

      assert get_field(cs, :status) == "in_progress"
      assert_receive {:regression_blocked, %{count: 1}, meta}
      assert meta == %{stack_id: @stack_id, from: "in_progress", to: "forming"}
    end

    test "LOSES: a forming stack still moves to in_progress" do
      cs = Stack.changeset(stack("forming", %{}), %{status: "in_progress"})
      assert get_field(cs, :status) == "in_progress"
    end
  end
end

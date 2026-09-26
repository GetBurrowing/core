defmodule Platform.Orchestration.LeaseManagerProgressOwnershipTest do
  @moduledoc """
  Task 01a0db63 stage 1 — ACCEPTANCE for "record_progress extends
  safety_net_at from any runtime's progress, no owner check".

  Drives `LeaseManager` DIRECTLY. The router's progress arm is the only
  lib caller today, but a refusal asserted only there would be an
  absorber: the store would still extend the net for any other caller.

  The ownership key is the lease's `owner_runtime_id`, the AgentRuntime
  `runtime_id` the stage was dispatched to — the same key and the same
  fail-closed compare `record_ack/3` uses (task 01a0c762).

  Every refusal case pairs with an OWNER progress call in the same test
  that must move the deadline. That is the positive control: a store that
  accepts nothing would satisfy every refusal assertion on its own.

  async: false — the LeaseManager is a global singleton.
  """

  use ExUnit.Case, async: false

  alias Platform.Orchestration.LeaseManager

  @owner_a "runtime-owner-a"
  @stranger_b "runtime-stranger-b"

  setup do
    on_exit(fn ->
      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:orchestration_lease_manager)
      end
    end)

    %{
      task_id: "task-prog-#{System.unique_integer([:positive])}",
      stage_id: "stage-prog-#{System.unique_integer([:positive])}"
    }
  end

  # Dispatched in the past so progress at `now` provably moves
  # `safety_net_at` forward (`now + 90m > dispatched_at + 90m`).
  defp dispatch!(task_id, stage_id, owner, ago_s \\ 60) do
    at = DateTime.add(DateTime.utc_now(), -ago_s, :second)
    :ok = LeaseManager.record_dispatch(task_id, stage_id, "coding", at, owner)
    LeaseManager.get(task_id)
  end

  defp attach_refusal_telemetry! do
    test_pid = self()
    handler_id = "progress-refused-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :orchestration, :progress_refused],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:progress_refused, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "(a) non-owner progress is refused and the row is untouched" do
    test "B is refused with the row whole-map equal; A's progress then moves the net",
         %{task_id: task_id, stage_id: stage_id} do
      attach_refusal_telemetry!()
      before = dispatch!(task_id, stage_id, @owner_a)

      assert before.owner_runtime_id == @owner_a
      assert before.last_progress_at == nil
      assert %DateTime{} = before.safety_net_at

      assert LeaseManager.record_progress(task_id, @stranger_b) ==
               {:error, {:not_owner, @owner_a}}

      # WHOLE-MAP equality: not safety_net_at alone. A refusal that still
      # wrote last_progress_at (or any other key) is the defect by another
      # route.
      assert LeaseManager.get(task_id) == before

      assert_received {:progress_refused, %{count: 1},
                       %{
                         task_id: ^task_id,
                         stage_id: ^stage_id,
                         caller_runtime_id: @stranger_b,
                         owner_runtime_id: @owner_a
                       }}

      refute_received {:progress_refused, _, _}

      # (a') POSITIVE CONTROL in the same test: the owner's progress is
      # accepted and moves the net.
      assert :ok = LeaseManager.record_progress(task_id, @owner_a)
      after_progress = LeaseManager.get(task_id)

      assert DateTime.compare(after_progress.safety_net_at, before.safety_net_at) == :gt
      assert %DateTime{} = after_progress.last_progress_at
      # Progress is not an ack: the no-ack fields are exactly preserved.
      assert after_progress.no_ack_at == before.no_ack_at
      assert after_progress.ack_at == nil
      refute_received {:progress_refused, _, _}
    end
  end

  describe "(b) a nil caller is refused (fail closed)" do
    test "nil is a non-owner and the row is unchanged; the owner still progresses",
         %{task_id: task_id, stage_id: stage_id} do
      before = dispatch!(task_id, stage_id, @owner_a)

      assert LeaseManager.record_progress(task_id, nil) == {:error, {:not_owner, @owner_a}}
      assert LeaseManager.get(task_id) == before

      assert :ok = LeaseManager.record_progress(task_id, @owner_a)
      assert %{last_progress_at: %DateTime{}} = LeaseManager.get(task_id)
    end

    test "a non-binary caller is a non-owner", %{task_id: task_id, stage_id: stage_id} do
      before = dispatch!(task_id, stage_id, @owner_a)

      assert LeaseManager.record_progress(task_id, :owner_a) ==
               {:error, {:not_owner, @owner_a}}

      assert LeaseManager.get(task_id) == before
    end

    test "an ownerless row refuses a nil caller: nil == nil is not a match",
         %{task_id: task_id, stage_id: stage_id} do
      # The only fixture shape in which a `nil == nil` compare could pass.
      # Without it, mutation M3 (owner?/2 accepts nil == nil) survives.
      # `record_dispatch/5` guards `is_binary(owner_runtime_id)`, so the API
      # cannot build this row; it is written straight into the table, as a
      # row from before task 01a0c762 (no owner key at all) would read.
      leased = dispatch!(task_id, stage_id, @owner_a)
      :ets.insert(:orchestration_lease_manager, {task_id, %{leased | owner_runtime_id: nil}})
      before = LeaseManager.get(task_id)
      assert before.owner_runtime_id == nil

      assert LeaseManager.record_progress(task_id, nil) == {:error, {:not_owner, nil}}
      assert LeaseManager.get(task_id) == before
    end
  end

  describe "(c) after a same-stage reassignment the OLD owner is a non-owner" do
    test "A's progress is refused once the stage belongs to B; B's is accepted",
         %{task_id: task_id, stage_id: stage_id} do
      dispatch!(task_id, stage_id, @owner_a)
      assert :ok = LeaseManager.record_progress(task_id, @owner_a)

      reassigned = dispatch!(task_id, stage_id, @stranger_b, 30)
      assert reassigned.owner_runtime_id == @stranger_b

      assert LeaseManager.record_progress(task_id, @owner_a) ==
               {:error, {:not_owner, @stranger_b}}

      assert LeaseManager.get(task_id) == reassigned

      assert :ok = LeaseManager.record_progress(task_id, @stranger_b)
      after_progress = LeaseManager.get(task_id)

      assert %DateTime{} = after_progress.last_progress_at
      assert reassigned.last_progress_at == nil
      assert DateTime.compare(after_progress.safety_net_at, reassigned.safety_net_at) == :gt
    end
  end

  describe "(d) no lease is :not_found for any caller" do
    test "owner-looking, stranger and nil callers all get :not_found, not :not_owner" do
      missing = "task-missing-#{System.unique_integer([:positive])}"

      for caller <- [@owner_a, @stranger_b, nil] do
        assert LeaseManager.record_progress(missing, caller) == {:error, :not_found}
      end

      assert LeaseManager.get(missing) == nil
    end
  end

  test "record_progress/1 no longer exists: an unthreaded caller cannot compile" do
    Code.ensure_loaded!(LeaseManager)
    refute function_exported?(LeaseManager, :record_progress, 1)
    assert function_exported?(LeaseManager, :record_progress, 2)
  end
end

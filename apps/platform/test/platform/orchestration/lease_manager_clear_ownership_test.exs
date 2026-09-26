defmodule Platform.Orchestration.LeaseManagerClearOwnershipTest do
  @moduledoc """
  Task 01a0dd2c stage 1 — ACCEPTANCE for "a non-owner's terminal event
  deletes the owner's lease and silences both alarms".

  Drives `LeaseManager.clear_if_owner/2` DIRECTLY. The router's
  terminal-event arms (stage 2) are the intended callers, but a refusal
  asserted only there would be an absorber: the store would still delete
  the row for any other caller.

  The ownership key is the lease's `owner_runtime_id`, under the same
  fail-closed compare `record_ack/3` (task 01a0c762) and
  `record_progress/2` (task 01a0db63) use.

  Every refusal case pairs with an OWNER clear on the same fixture that
  must delete the row. That is the positive control: a store that
  deletes nothing would satisfy every refusal assertion on its own.

  `clear/1` stays unconditional — it is the router-internal path (human
  gates, phase boundaries, stage transition, `terminate/2`). A test pins
  that so the owner gate cannot leak into it.

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
      task_id: "task-clear-#{System.unique_integer([:positive])}",
      stage_id: "stage-clear-#{System.unique_integer([:positive])}"
    }
  end

  defp dispatch!(task_id, stage_id, owner) do
    at = DateTime.add(DateTime.utc_now(), -60, :second)
    :ok = LeaseManager.record_dispatch(task_id, stage_id, "coding", at, owner)
    LeaseManager.get(task_id)
  end

  # Writes an ownerless row straight into the table. `record_dispatch/5`
  # guards `is_binary(owner_runtime_id)`, so the API cannot build this
  # shape; it is how a row from before task 01a0c762 would read.
  defp make_ownerless!(task_id, leased) do
    :ets.insert(:orchestration_lease_manager, {task_id, %{leased | owner_runtime_id: nil}})
    LeaseManager.get(task_id)
  end

  defp attach_refusal_telemetry! do
    test_pid = self()
    handler_id = "clear-refused-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :orchestration, :clear_refused],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:clear_refused, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "(a) the owner clears" do
    test "the owner's clear deletes the row", %{task_id: task_id, stage_id: stage_id} do
      attach_refusal_telemetry!()
      before = dispatch!(task_id, stage_id, @owner_a)
      assert before.owner_runtime_id == @owner_a

      assert LeaseManager.clear_if_owner(task_id, @owner_a) == :ok
      assert LeaseManager.get(task_id) == nil
      refute_received {:clear_refused, _, _}
    end
  end

  describe "(b) a stranger's clear is refused and the row is untouched" do
    test "B is refused with the row whole-map equal; A then clears",
         %{task_id: task_id, stage_id: stage_id} do
      before = dispatch!(task_id, stage_id, @owner_a)

      assert LeaseManager.clear_if_owner(task_id, @stranger_b) ==
               {:error, {:not_owner, @owner_a}}

      # WHOLE-MAP equality, not "a row exists": a refusal that rewrote
      # any key (safety_net_at, no_ack_at, ack_at) is the defect by
      # another route.
      assert LeaseManager.get(task_id) == before

      # POSITIVE CONTROL on the same fixture.
      assert LeaseManager.clear_if_owner(task_id, @owner_a) == :ok
      assert LeaseManager.get(task_id) == nil
    end

    test "the refusal emits :clear_refused telemetry once, naming both runtimes",
         %{task_id: task_id, stage_id: stage_id} do
      attach_refusal_telemetry!()
      before = dispatch!(task_id, stage_id, @owner_a)

      assert {:error, {:not_owner, @owner_a}} =
               LeaseManager.clear_if_owner(task_id, @stranger_b)

      assert_received {:clear_refused, %{count: 1},
                       %{
                         task_id: ^task_id,
                         stage_id: ^stage_id,
                         caller_runtime_id: @stranger_b,
                         owner_runtime_id: @owner_a
                       }}

      refute_received {:clear_refused, _, _}
      assert LeaseManager.get(task_id) == before

      # POSITIVE CONTROL: the owner's clear deletes and emits nothing.
      assert LeaseManager.clear_if_owner(task_id, @owner_a) == :ok
      assert LeaseManager.get(task_id) == nil
      refute_received {:clear_refused, _, _}
    end
  end

  describe "(c) fail closed on callers with no authenticated runtime" do
    test "a nil caller is refused; the owner then clears",
         %{task_id: task_id, stage_id: stage_id} do
      before = dispatch!(task_id, stage_id, @owner_a)

      assert LeaseManager.clear_if_owner(task_id, nil) == {:error, {:not_owner, @owner_a}}
      assert LeaseManager.get(task_id) == before

      assert LeaseManager.clear_if_owner(task_id, @owner_a) == :ok
      assert LeaseManager.get(task_id) == nil
    end

    test "a non-binary caller is refused; the owner then clears",
         %{task_id: task_id, stage_id: stage_id} do
      before = dispatch!(task_id, stage_id, @owner_a)

      assert LeaseManager.clear_if_owner(task_id, :"runtime-owner-a") ==
               {:error, {:not_owner, @owner_a}}

      assert LeaseManager.get(task_id) == before

      assert LeaseManager.clear_if_owner(task_id, @owner_a) == :ok
      assert LeaseManager.get(task_id) == nil
    end
  end

  describe "(d) an ownerless row is refused for every caller" do
    test "a nil caller does not match a nil owner: nil == nil is not a match",
         %{task_id: task_id, stage_id: stage_id} do
      # The only fixture shape in which a `nil == nil` compare could pass.
      leased = dispatch!(task_id, stage_id, @owner_a)
      before = make_ownerless!(task_id, leased)
      assert before.owner_runtime_id == nil

      assert LeaseManager.clear_if_owner(task_id, nil) == {:error, {:not_owner, nil}}
      assert LeaseManager.get(task_id) == before

      # POSITIVE CONTROL on the same task: restore the owner, the owner clears.
      :ets.insert(:orchestration_lease_manager, {task_id, leased})
      assert LeaseManager.clear_if_owner(task_id, @owner_a) == :ok
      assert LeaseManager.get(task_id) == nil
    end

    test "a binary caller does not match a nil owner",
         %{task_id: task_id, stage_id: stage_id} do
      leased = dispatch!(task_id, stage_id, @owner_a)
      before = make_ownerless!(task_id, leased)

      for caller <- [@owner_a, @stranger_b] do
        assert LeaseManager.clear_if_owner(task_id, caller) == {:error, {:not_owner, nil}}
        assert LeaseManager.get(task_id) == before
      end

      # POSITIVE CONTROL on the same task.
      :ets.insert(:orchestration_lease_manager, {task_id, leased})
      assert LeaseManager.clear_if_owner(task_id, @owner_a) == :ok
      assert LeaseManager.get(task_id) == nil
    end
  end

  describe "(e) no lease is :not_found for any caller" do
    test "owner-looking, stranger and nil callers all get :not_found, not :not_owner" do
      attach_refusal_telemetry!()
      missing = "task-missing-#{System.unique_integer([:positive])}"

      for caller <- [@owner_a, @stranger_b, nil] do
        assert LeaseManager.clear_if_owner(missing, caller) == {:error, :not_found}
      end

      assert LeaseManager.get(missing) == nil
      refute_received {:clear_refused, _, _}
    end
  end

  describe "(f) clear/1 stays the unconditional router-internal path" do
    test "clear/1 deletes a row owned by anyone, with no caller argument",
         %{task_id: task_id, stage_id: stage_id} do
      attach_refusal_telemetry!()
      dispatch!(task_id, stage_id, @owner_a)

      assert LeaseManager.clear(task_id) == :ok
      assert LeaseManager.get(task_id) == nil
      # Idempotent on a missing row.
      assert LeaseManager.clear(task_id) == :ok
      refute_received {:clear_refused, _, _}
    end

    test "clear/1 deletes an ownerless row", %{task_id: task_id, stage_id: stage_id} do
      leased = dispatch!(task_id, stage_id, @owner_a)
      make_ownerless!(task_id, leased)

      assert LeaseManager.clear(task_id) == :ok
      assert LeaseManager.get(task_id) == nil
    end
  end
end

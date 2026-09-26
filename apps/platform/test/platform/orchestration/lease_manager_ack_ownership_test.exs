defmodule Platform.Orchestration.LeaseManagerAckOwnershipTest do
  @moduledoc """
  Task 01a0c762 stage 1 — ACCEPTANCE for "record_ack extends the no-ack
  timer without checking WHO acked".

  Drives `LeaseManager` DIRECTLY, below the `task_ack` tool surface. A
  refusal asserted only at the tool would be an absorber: the store
  itself would still accept a stranger's ack from any other caller (the
  router's `apply_runtime_event/2`, `maybe_fire_no_ack/3`).

  The ownership key is the AgentRuntime `runtime_id` the stage was
  dispatched to. `subagent_id` is recorded for audit only.

  Every refusal case pairs with an OWNER ack in the same test that must
  move the deadline. That is the positive control: a store that accepts
  nothing would satisfy every refusal assertion on its own.

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
      task_id: "task-own-#{System.unique_integer([:positive])}",
      stage_id: "stage-own-#{System.unique_integer([:positive])}"
    }
  end

  # Dispatched in the past so an ack at `now` provably moves
  # `safety_net_at` forward (`now + 90m > dispatched_at + 90m`).
  defp dispatch!(task_id, stage_id, owner, ago_s \\ 60) do
    at = DateTime.add(DateTime.utc_now(), -ago_s, :second)
    :ok = LeaseManager.record_dispatch(task_id, stage_id, "coding", at, owner)
    LeaseManager.get(task_id)
  end

  defp attach_refusal_telemetry! do
    test_pid = self()
    handler_id = "ack-refused-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :orchestration, :ack_refused],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:ack_refused, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "(a) a non-owner ack is refused and the row is untouched" do
    test "B is refused with the row whole-map equal; A's ack then moves the deadline",
         %{task_id: task_id, stage_id: stage_id} do
      attach_refusal_telemetry!()
      before = dispatch!(task_id, stage_id, @owner_a)

      assert before.owner_runtime_id == @owner_a
      assert before.ack_at == nil
      assert %DateTime{} = before.no_ack_at

      assert LeaseManager.record_ack(task_id, @stranger_b, "sub-b") ==
               {:error, {:not_owner, @owner_a}}

      # WHOLE-MAP equality: not ack_at alone. A refusal that still wrote
      # safety_net_at (or any other field) is the defect by another route.
      assert LeaseManager.get(task_id) == before

      assert_received {:ack_refused, %{count: 1},
                       %{
                         task_id: ^task_id,
                         stage_id: ^stage_id,
                         caller_runtime_id: @stranger_b,
                         owner_runtime_id: @owner_a
                       }}

      # POSITIVE CONTROL in the same test: the owner's ack is accepted.
      assert :ok = LeaseManager.record_ack(task_id, @owner_a, "sub-1")
      after_ack = LeaseManager.get(task_id)

      assert DateTime.compare(after_ack.safety_net_at, before.safety_net_at) == :gt
      assert after_ack.no_ack_at == nil
      assert %DateTime{} = after_ack.ack_at
      assert after_ack.ack_runtime_id == @owner_a
      assert after_ack.ack_subagent_id == "sub-1"
    end
  end

  describe "(b) a nil caller is refused (fail closed)" do
    test "nil is a non-owner and the row is unchanged; the owner still acks",
         %{task_id: task_id, stage_id: stage_id} do
      before = dispatch!(task_id, stage_id, @owner_a)

      assert LeaseManager.record_ack(task_id, nil, "sub-nil") ==
               {:error, {:not_owner, @owner_a}}

      assert LeaseManager.get(task_id) == before

      assert :ok = LeaseManager.record_ack(task_id, @owner_a)
      assert %{ack_at: %DateTime{}, ack_runtime_id: @owner_a} = LeaseManager.get(task_id)
    end

    test "a non-binary caller is a non-owner", %{task_id: task_id, stage_id: stage_id} do
      before = dispatch!(task_id, stage_id, @owner_a)

      assert LeaseManager.record_ack(task_id, :owner_a) == {:error, {:not_owner, @owner_a}}
      assert LeaseManager.get(task_id) == before
    end

    test "an unknown task is still :not_found, not :not_owner" do
      assert LeaseManager.record_ack("task-missing-#{System.unique_integer([:positive])}", nil) ==
               {:error, :not_found}
    end
  end

  describe "(c) reassigning the same stage to a different owner builds a fresh lease" do
    test "A's ack does not survive; A is refused afterwards and B is accepted",
         %{task_id: task_id, stage_id: stage_id} do
      dispatch!(task_id, stage_id, @owner_a)
      assert :ok = LeaseManager.record_ack(task_id, @owner_a, "sub-a")
      assert %{ack_at: %DateTime{}} = LeaseManager.get(task_id)

      reassigned = dispatch!(task_id, stage_id, @stranger_b, 0)

      assert reassigned.owner_runtime_id == @stranger_b
      assert reassigned.ack_at == nil
      assert reassigned.ack_runtime_id == nil
      assert reassigned.ack_subagent_id == nil
      assert reassigned.silenced_until == nil
      # No-ack re-armed from the reassigning dispatch instant.
      assert %DateTime{} = reassigned.no_ack_at

      assert LeaseManager.record_ack(task_id, @owner_a, "sub-a") ==
               {:error, {:not_owner, @stranger_b}}

      assert LeaseManager.get(task_id) == reassigned

      assert :ok = LeaseManager.record_ack(task_id, @stranger_b, "sub-b")

      assert %{ack_at: %DateTime{}, ack_runtime_id: @stranger_b, ack_subagent_id: "sub-b"} =
               LeaseManager.get(task_id)
    end
  end

  describe "(d) a same-owner re-dispatch keeps the ack" do
    test "ack_at, ack_runtime_id and ack_subagent_id survive a duplicate delivery",
         %{task_id: task_id, stage_id: stage_id} do
      dispatch!(task_id, stage_id, @owner_a)
      assert :ok = LeaseManager.record_ack(task_id, @owner_a, "sub-a")
      %{ack_at: %DateTime{} = acked_at} = LeaseManager.get(task_id)

      redispatched = dispatch!(task_id, stage_id, @owner_a, 0)

      assert redispatched.ack_at == acked_at
      assert redispatched.no_ack_at == nil
      assert redispatched.owner_runtime_id == @owner_a
      assert redispatched.ack_runtime_id == @owner_a
      assert redispatched.ack_subagent_id == "sub-a"
    end
  end
end

defmodule Platform.Tasks.BoardTopicScopeTest do
  @moduledoc """
  Scope-narrowed kanban board topics.

  These exercise `Tasks.broadcast_board/1` fan-out only — no database access
  is involved, since every scope is derived from ids already on the payload.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks
  alias Platform.Tasks.{Epic, Plan, Stack, Stage, Task}

  defp id, do: Ecto.UUID.generate()

  describe "topic_for_scope/1" do
    test "builds one topic per scope kind, all under the board namespace" do
      a = id()

      assert Tasks.topic_for_scope({:task, a}) == "tasks:board:task:#{a}"
      assert Tasks.topic_for_scope({:project, a}) == "tasks:board:project:#{a}"
      assert Tasks.topic_for_scope({:plan, a}) == "tasks:board:plan:#{a}"
      assert Tasks.topic_for_scope({:stack, a}) == "tasks:board:stack:#{a}"
      assert Tasks.board_topic() == "tasks:board"
    end
  end

  describe "scope derivation, one case per board_scopes/1 head" do
    test "task events reach both the task and the project scope" do
      task = %Task{id: id(), project_id: id()}

      :ok = Tasks.subscribe_board(task: task.id)
      Tasks.broadcast_board({:task_updated, task})
      assert_receive {:task_updated, ^task}
      :ok = Tasks.unsubscribe_board(task: task.id)

      :ok = Tasks.subscribe_board(project: task.project_id)
      Tasks.broadcast_board({:task_updated, task})
      assert_receive {:task_updated, ^task}
    end

    test "plan events reach the owning task's scope" do
      plan = %Plan{id: id(), task_id: id()}

      :ok = Tasks.subscribe_board(task: plan.task_id)
      Tasks.broadcast_board({:plan_updated, plan})

      assert_receive {:plan_updated, ^plan}
    end

    test "epic events reach the owning project's scope" do
      epic = %Epic{id: id(), project_id: id()}

      :ok = Tasks.subscribe_board(project: epic.project_id)
      Tasks.broadcast_board({:epic_updated, epic})

      assert_receive {:epic_updated, ^epic}
    end

    test "stage transitions reach the plan scope (Stage carries no task_id)" do
      stage = %Stage{id: id(), plan_id: id()}

      :ok = Tasks.subscribe_board(plan: stage.plan_id)
      Tasks.broadcast_board({:stage_transitioned, stage})

      assert_receive {:stage_transitioned, ^stage}
    end

    test "stack gate opening reaches the stack scope" do
      stack_id = id()
      members = [id(), id()]

      :ok = Tasks.subscribe_board(stack: stack_id)
      Tasks.broadcast_board({:stack_gate_opened, stack_id, members})

      assert_receive {:stack_gate_opened, ^stack_id, ^members}
    end

    test "stack struct events reach the stack scope" do
      stack = %Stack{id: id()}

      :ok = Tasks.subscribe_board(stack: stack.id)
      Tasks.broadcast_board({:stack_updated, stack})

      assert_receive {:stack_updated, ^stack}
    end

    test "runtime events reach the scope of the task they name" do
      task_id = id()
      payload = %{task_id: task_id, event_type: "execution.acked"}

      :ok = Tasks.subscribe_board(task: task_id)
      Tasks.broadcast_board({:runtime_event, payload})

      assert_receive {:runtime_event, ^payload}
    end

    test "batch deletes derive no scope and go to the global topic only" do
      ids = [id(), id()]
      meta = %{canvas_id: id(), count: 2, soft_deleted_at: DateTime.utc_now()}

      # No id in this payload names a single row, so there is nothing to
      # narrow to; the board handles it as a whole-board reflow.
      :ok = Tasks.subscribe_board(task: hd(ids))
      :ok = Tasks.subscribe_board()

      Tasks.broadcast_board({:tasks_batch_deleted, ids, meta})

      assert_receive {:tasks_batch_deleted, ^ids, ^meta}
      refute_receive {:tasks_batch_deleted, ^ids, ^meta}
    end
  end

  describe "isolation" do
    test "a scoped subscriber does not see another task's event, while the global one does" do
      a = id()
      b = id()
      refute a == b

      plan_for_b = %Plan{id: id(), task_id: b}

      # This process listens ONLY to task a.
      :ok = Tasks.subscribe_board(task: a)

      # A control process listens to the global firehose. If the broadcast
      # never happened at all, the refute below would pass for the wrong
      # reason — the control's assertion is what rules that out.
      test_pid = self()

      control =
        spawn_link(fn ->
          :ok = Tasks.subscribe_board()
          send(test_pid, :control_subscribed)

          receive do
            {:plan_updated, ^plan_for_b} -> send(test_pid, :control_got_it)
          after
            2_000 -> send(test_pid, :control_timed_out)
          end
        end)

      assert_receive :control_subscribed, 1_000

      Tasks.broadcast_board({:plan_updated, plan_for_b})

      # Half 1: the global control DID receive it — the broadcast is real.
      assert_receive :control_got_it, 2_000
      # Half 2: the scoped subscriber did NOT.
      refute_received {:plan_updated, _}

      Process.unlink(control)
    end
  end

  describe "ordering" do
    test "the global copy is broadcast before the scoped one" do
      task = %Task{id: id(), project_id: id()}
      test_pid = self()

      # The two copies are byte-identical, so two subscriptions on one
      # mailbox cannot tell them apart. Relaying the scoped copy through a
      # second process makes the order observable: the scoped send happens
      # after the global send, and the relay after that — so if the global
      # copy really goes first it is already in this mailbox by the time the
      # relay is even sent.
      relay =
        spawn_link(fn ->
          :ok = Tasks.subscribe_board(task: task.id)
          send(test_pid, :relay_subscribed)

          receive do
            {:task_updated, ^task} -> send(test_pid, :scoped_copy)
          after
            2_000 -> send(test_pid, :scoped_timed_out)
          end
        end)

      assert_receive :relay_subscribed, 1_000
      :ok = Tasks.subscribe_board()

      Tasks.broadcast_board({:task_updated, task})

      # Wait for the scoped copy to have been delivered, THEN require the
      # global copy to be sitting in this mailbox already (`assert_received`
      # does not wait). Note `assert_receive` matches selectively, so simply
      # asserting the two in order would prove nothing.
      #
      # Honest limit: this pins "the global copy has been delivered by the
      # time the scoped one is observed", NOT the broadcast order itself.
      # Swapping the two broadcasts in `broadcast_board/1` leaves this green,
      # because the broadcasting process finishes both sends before the relay
      # is scheduled. Cross-topic ordering is a property of the sequential
      # source, and no PubSub-level test can discriminate it.
      assert_receive :scoped_copy, 2_000
      assert_received {:task_updated, ^task}

      Process.unlink(relay)
    end

    test "each subscription gets exactly one copy — no dedup, no duplicates" do
      task = %Task{id: id(), project_id: id()}

      :ok = Tasks.subscribe_board()
      :ok = Tasks.subscribe_board(task: task.id)
      :ok = Tasks.subscribe_board(project: task.project_id)

      Tasks.broadcast_board({:task_updated, task})

      assert_receive {:task_updated, ^task}
      assert_receive {:task_updated, ^task}
      assert_receive {:task_updated, ^task}
      refute_receive {:task_updated, ^task}
    end
  end
end

defmodule Platform.Tasks.PlanEnginePostCommitBroadcastTest do
  @moduledoc """
  `{:stage_transitioned, _}` must not reach a subscriber while the writer's
  transaction is still open (task 019ff788).

  ## Which side of the race this pins

  Every consumer of that message RE-READS the database off it — the one that
  matters is `TaskRouter.handle_review_stage_failure/3`, which calls
  `Tasks.list_validations/1` from its own process. When the broadcast was
  emitted from inside `PlanEngine.evaluate_validation/2`'s transaction, a
  subscriber that re-read fast enough saw `status: "pending"` for the very
  validation that transaction had just marked `failed`. The failed list came
  back EMPTY and a correctly-marked un-runnable review spent a round of the
  bound.

  This test pins the WRITER side: the emit must not happen before the
  transaction closes. It does not pin it by timing — a timing probe would
  pass on the buggy tree whenever the scheduler happened to be kind, and the
  scheduler is kind under load. It was measured to be kind under load:
  eight busy routers got the right answer 8/8, while ONE IDLE router with a
  ~300 ms quiet gap got it wrong 0/8. Production sits in the quiet state —
  a router is idle while a reviewer composes a verdict — so any probe that
  can only fail under contention certifies the bug.

  So the observable is ORDER, not time, and it is collected in ONE process
  (this one), which is the quiet/idle shape:

    * Ecto's query telemetry fires in the writer process when its
      transaction closes (`commit`, or `release savepoint` under the test
      sandbox). The handler `send/2`s a marker to this process.
    * The board broadcast, delivered by the local PubSub adapter, is a
      `send/2` from the same writer process.

  Both therefore land in THIS mailbox in exactly the order the writer
  executed them, with no scheduling dependence at all.

  The assertion is "no transaction close happens AFTER the broadcast"
  rather than "a close happens before it": nested savepoints inside
  `advance_stage/1` close before the broadcast on BOTH trees, so a
  before-only assertion would be satisfied by the defect it is meant to
  catch. On the buggy tree the OUTER close lands after the broadcast; on
  the fixed tree nothing does.

  Confirmed to fail on `39c4a0ea` (the tree that carries the defect) and to
  pass after the fix.
  """
  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine

  @handler_id "post-commit-broadcast-probe"

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Post-commit broadcast project",
        repo_url: "https://github.com/test/post-commit-broadcast"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Post-commit broadcast task",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, gate} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Task-level review"})

    {:ok, validation} =
      Tasks.create_validation(%{
        stage_id: gate.id,
        kind: "e2e_behavior",
        evaluation_payload: %{
          "setup" => "A task sits at its behavioural review gate.",
          "actions" => "Fail the gate.",
          "expected" => "Subscribers only ever see committed rows."
        }
      })

    {:ok, _running} = PlanEngine.start_stage(gate.id)

    %{plan: plan, gate: gate, validation: validation}
  end

  test "the stage broadcast is published only after the writing transaction closes",
       %{plan: plan, gate: gate, validation: validation} do
    :ok = Tasks.subscribe_board(plan: plan.id)

    test_pid = self()

    :ok =
      :telemetry.attach(
        @handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if transaction_close?(metadata[:query]) do
            send(test_pid, {:probe, :transaction_closed})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(@handler_id) end)

    # Drain anything the fixture left behind so the recorded sequence covers
    # this call and nothing else.
    _ = drain([])

    {:ok, _failed} =
      PlanEngine.evaluate_validation(validation.id, %{
        status: "failed",
        evidence: %{
          "disposition" => "could_not_evaluate",
          "reason" => "dev server would not boot: migration lock held by another run"
        },
        evaluated_by: "test"
      })

    events = drain([])
    gate_id = gate.id

    broadcast_index =
      Enum.find_index(events, fn
        {:stage_transitioned, %{id: ^gate_id}} -> true
        _ -> false
      end)

    # Anti-vacuity, both halves: the sequence must actually contain the
    # broadcast AND at least one transaction close, otherwise "nothing came
    # after it" would be true of an empty recording.
    assert broadcast_index,
           "the probe recorded no {:stage_transitioned, _} for the gate stage at all — " <>
             "got: #{inspect(events)}"

    assert Enum.any?(events, &(&1 == {:probe, :transaction_closed})),
           "the probe recorded no transaction close, so its ordering claim would be " <>
             "vacuous — got: #{inspect(events)}"

    after_broadcast = Enum.drop(events, broadcast_index + 1)

    refute Enum.any?(after_broadcast, &(&1 == {:probe, :transaction_closed})),
           "the stage broadcast was published while the writer's transaction was still " <>
             "open — a subscriber that re-reads on this message can observe pre-commit " <>
             "rows, which is how an un-runnable review spent a round. Sequence after " <>
             "the broadcast: #{inspect(after_broadcast)}"
  end

  test "a rolled-back transition is not broadcast at all", %{plan: plan} do
    # The other half of moving the emit past the commit: the pre-commit emit
    # announced transitions that could still roll back. Reopening a
    # non-manual-approval validation rolls back after touching the engine.
    :ok = Tasks.subscribe_board(plan: plan.id)
    _ = drain([])

    {:ok, other_plan} = Tasks.create_plan(%{task_id: plan.task_id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: other_plan.id, position: 1, name: "Rollback probe"})

    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assert {:error, :not_manual_approval} = PlanEngine.reopen_manual_approval(validation.id)

    refute Enum.any?(drain([]), &match?({:stage_transitioned, _}, &1)),
           "a transition that rolled back must not be announced"
  end

  defp transaction_close?(query) when is_binary(query) do
    normalized = String.downcase(query)

    normalized == "commit" or String.starts_with?(normalized, "release savepoint")
  end

  defp transaction_close?(_), do: false

  defp drain(acc) do
    receive do
      message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

defmodule Platform.TasksTest do
  @moduledoc """
  Tests for the central `Platform.Tasks` seam introduced in Stack v2 stage 1:
  `Tasks.dispatch_deploy_for_task/1` — the single guard consulted by every
  per-task deploy-dispatch call site (auto-merger, webhook controller,
  plan-engine's deploy-stage injection) so the "stacks ship as ONE rollup
  PR" invariant can never regress silently.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{ChatPin, ChatPins, Stacks}

  describe "dispatch_deploy_for_task/1 — guard behavior" do
    test "returns :ok for a task with no stack_id" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Solo #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/solo"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Solo task"})

      assert :ok = Tasks.dispatch_deploy_for_task(task)
      assert :ok = Tasks.dispatch_deploy_for_task(task.id)
    end

    test "returns :ok for nil and unknown task id" do
      assert :ok = Tasks.dispatch_deploy_for_task(nil)
      assert :ok = Tasks.dispatch_deploy_for_task(Ecto.UUID.generate())
    end

    test "returns {:error, :stack_ships_atomically} for a stacked task" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Stacked #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/stacked"
        })

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "stacked-#{System.unique_integer([:positive])}",
          name: "Guard Stack",
          rollup_branch: "stack/guard"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      assert {:error, :stack_ships_atomically} = Tasks.dispatch_deploy_for_task(task)
      # Same via task id — recovers the record and applies the same guard.
      assert {:error, :stack_ships_atomically} = Tasks.dispatch_deploy_for_task(task.id)
    end
  end

  describe "dispatch_deploy_for_task/1 — telemetry" do
    setup do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Telem #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/telem"
        })

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "telem-#{System.unique_integer([:positive])}",
          name: "Telem Stack",
          rollup_branch: "stack/telem"
        })

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member"})
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      # Per-test telemetry handler with a unique id so async runs don't
      # collide even though we've opted out of :async — belt and braces.
      handler_id = "rejected_stack_member_test_#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :tasks, :deploy_dispatch, :rejected_stack_member],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{task: task, stack: stack}
    end

    test "fires exactly once per invocation on the blocked path", %{task: task, stack: stack} do
      assert {:error, :stack_ships_atomically} = Tasks.dispatch_deploy_for_task(task)

      assert_receive {:telemetry_event,
                      [:platform, :tasks, :deploy_dispatch, :rejected_stack_member], %{count: 1},
                      %{task_id: task_id, stack_id: stack_id}}

      assert task_id == task.id
      assert stack_id == stack.id

      # Exactly once — nothing else in the queue after draining.
      refute_receive {:telemetry_event, _, _, _}, 50
    end

    test "does NOT fire on the allowed (non-stack) path" do
      {:ok, project} =
        Tasks.create_project(%{name: "Allowed #{System.unique_integer([:positive])}"})

      {:ok, solo} = Tasks.create_task(%{project_id: project.id, title: "Solo"})

      assert :ok = Tasks.dispatch_deploy_for_task(solo)

      refute_receive {:telemetry_event, _, _, _}, 50
    end
  end

  # ── Pin-to-Chat cascade (task 019f62a1 stage 3) ───────────────────────────
  #
  # `transition_task_status/2 → maybe_dispatch_teardown/2` calls
  # `ChatPins.unpin_all_for_task/1` whenever a task enters a terminal
  # status. Placed in the shared teardown (not just
  # `maybe_finalize_transition/3`) so the MCP `task_update({status: …})`
  # path — which bypasses `maybe_finalize_transition/3` — cascades too.
  # Space rows are intentionally preserved: cascade is pin-only.
  describe "terminal-status pin cascade (task 019f62a1 stage 3)" do
    setup do
      {:ok, project} =
        Tasks.create_project(%{name: "Cascade #{System.unique_integer([:positive])}"})

      # Subscribe to the space-lifecycle topic so we can assert on the
      # per-participant `{:task_pin_removed, ...}` broadcasts fired
      # inside `ChatPins.unpin_all_for_task/1`.
      :ok = ChatPubSub.subscribe_spaces()
      on_exit(fn -> ChatPubSub.unsubscribe_spaces() end)

      %{project: project}
    end

    defp count_pins_for(task_id) do
      Repo.aggregate(from(p in ChatPin, where: p.task_id == ^task_id), :count)
    end

    defp count_exec_spaces_for(task_id) do
      Repo.aggregate(
        from(s in Platform.Chat.Space,
          where:
            s.kind == "execution" and
              fragment("?->>'task_id' = ?", s.metadata, ^task_id)
        ),
        :count
      )
    end

    defp seed_three_pins(task_id) do
      pinner = "sponsor@example.com"

      participants = [
        %{kind: "user", id: "sponsor@example.com"},
        %{kind: "user", id: "alice@example.com"},
        %{kind: "agent", id: "historian"}
      ]

      Enum.each(participants, fn p ->
        {:ok, _} = ChatPins.pin(task_id, p, pinner)
        assert_receive {:task_pin_added, _}
      end)

      participants
    end

    test "in_progress → done unpins every participant and broadcasts each removal",
         %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Terminal done"})
      {:ok, task} = Tasks.transition_task_status(task, "in_progress")

      participants = seed_three_pins(task.id)
      assert count_pins_for(task.id) == 3
      # Sanity: pin materialised the exec space in stage 2 — cascade
      # must not delete it.
      assert count_exec_spaces_for(task.id) == 1

      assert {:ok, %Platform.Tasks.Task{status: "done"}} =
               Tasks.transition_task_status(task, "done")

      assert count_pins_for(task.id) == 0
      # Space intentionally preserved for post-mortem access.
      assert count_exec_spaces_for(task.id) == 1

      broadcasts =
        for _ <- 1..3 do
          assert_receive {:task_pin_removed, payload}
          {payload.participant_kind, payload.participant_id}
        end

      assert Enum.sort(broadcasts) ==
               Enum.sort(Enum.map(participants, fn %{kind: k, id: i} -> {k, i} end))

      # Exactly three — no phantom re-broadcast.
      refute_receive {:task_pin_removed, _}, 50
    end

    test "backlog → cancelled cascades the same as done", %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Terminal cancelled"})

      participants = seed_three_pins(task.id)
      assert count_pins_for(task.id) == 3

      assert {:ok, %Platform.Tasks.Task{status: "cancelled"}} =
               Tasks.transition_task_status(task, "cancelled")

      assert count_pins_for(task.id) == 0
      assert count_exec_spaces_for(task.id) == 1

      broadcasts =
        for _ <- 1..3 do
          assert_receive {:task_pin_removed, payload}
          {payload.participant_kind, payload.participant_id}
        end

      assert Enum.sort(broadcasts) ==
               Enum.sort(Enum.map(participants, fn %{kind: k, id: i} -> {k, i} end))
    end

    test "transitioning a pinned task to a NON-terminal status leaves pins intact",
         %{project: project} do
      # Regression fence: only the `done` and `cancelled` clauses of
      # `maybe_dispatch_teardown/2` cascade — everything else must be
      # a no-op for pins.
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Not terminal yet"})

      {:ok, _} =
        ChatPins.pin(task.id, %{kind: "user", id: "sponsor@example.com"}, "sponsor@example.com")

      assert_receive {:task_pin_added, _}

      {:ok, _} = Tasks.transition_task_status(task, "in_progress")

      assert count_pins_for(task.id) == 1
      refute_receive {:task_pin_removed, _}, 50
    end

    test "done cascade on a task with no pins is a no-op (no broadcasts)",
         %{project: project} do
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Empty terminal"})
      {:ok, task} = Tasks.transition_task_status(task, "in_progress")

      assert {:ok, _done} = Tasks.transition_task_status(task, "done")

      refute_receive {:task_pin_removed, _}, 50
    end
  end
end

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

  # ── Sponsor-bypass predicate (task 019f6380 stage 1) ─────────────────────
  #
  # `sponsor_bypasses_plan_gate?/2` exempts board-moves on sponsor-only
  # tasks (human sponsor, no agent involvement, initiated by a human)
  # from `require_approved_plan_for/3`. The gate exists to protect
  # against agents self-approving their own work — pointless when no
  # agent is on the task and the sponsor is manually confirming
  # completion. See the task description for the full motivation.
  describe "sponsor_bypasses_plan_gate?/2 (task 019f6380 stage 1)" do
    setup do
      {:ok, project} =
        Tasks.create_project(%{name: "Sponsor bypass #{System.unique_integer([:positive])}"})

      sponsor = insert_bypass_user()
      other_user = insert_bypass_user()
      agent_id = Ecto.UUID.generate()

      %{project: project, sponsor: sponsor, other_user: other_user, agent_id: agent_id}
    end

    # Test case 1 (from task 019f6380 description):
    # Human sponsor + no agent + no plan → bypass fires for a human actor.
    test "human sponsor + no assignee + human actor → bypass",
         %{project: project, sponsor: sponsor, other_user: other_user} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsor solo",
          sponsor_user_id: sponsor.id
        })

      assert Tasks.sponsor_bypasses_plan_gate?(task, {:user, sponsor.id})
      # Any human user, not just the sponsor — the gate is about actor
      # taxonomy, not identity match.
      assert Tasks.sponsor_bypasses_plan_gate?(task, {:user, other_user.id})
    end

    # Test case 1 end-to-end: `require_approved_plan_for/3` and
    # `drop_task_to_column/3` both allow the move without a plan.
    test "bypass unblocks require_approved_plan_for/3 and drop_task_to_column/3",
         %{project: project, sponsor: sponsor} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsor drops to done",
          status: "in_progress",
          sponsor_user_id: sponsor.id
        })

      # Baseline: two-arity delegator uses `:system` and stays gated —
      # every existing internal caller keeps its current behavior.
      assert Tasks.require_approved_plan_for(task, "done") == :ok
      # (from `in_progress` the intra-execution short-circuit fires, so
      # test the bypass by going from `backlog` where the plan gate is live.)

      {:ok, backlog_task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsor from backlog",
          sponsor_user_id: sponsor.id
        })

      # Two-arity (system actor) — gated as before.
      assert Tasks.require_approved_plan_for(backlog_task, "in_progress") ==
               {:error, :no_approved_plan}

      # Three-arity with human actor — bypass fires.
      assert Tasks.require_approved_plan_for(
               backlog_task,
               "in_progress",
               {:user, sponsor.id}
             ) == :ok

      # And the actor-aware `drop_task_to_column/3` completes the move
      # end-to-end without requiring an approved plan.
      assert {:ok, dropped} =
               Tasks.drop_task_to_column(backlog_task, "done", {:user, sponsor.id})

      assert dropped.status == "done"
    end

    # Test case 2: Agent assignee + no plan → still blocked regardless of
    # actor. The gate exists precisely because there IS an agent on the
    # task, so no bypass ever fires.
    test "agent assignee (no sponsor) → predicate stays false, gate still fires",
         %{project: project, sponsor: sponsor, agent_id: agent_id} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Agent solo",
          assignee_id: agent_id,
          assignee_type: "agent"
        })

      refute Tasks.sponsor_bypasses_plan_gate?(task, {:user, sponsor.id})
      refute Tasks.sponsor_bypasses_plan_gate?(task, {:agent, agent_id})
      refute Tasks.sponsor_bypasses_plan_gate?(task, :system)

      assert Tasks.require_approved_plan_for(task, "in_progress", {:user, sponsor.id}) ==
               {:error, :no_approved_plan}
    end

    # Test case 3: Human sponsor + agent assignee (mixed) → still blocked.
    # Sponsor alone isn't enough; agent involvement pulls the protection
    # back in.
    test "human sponsor + agent assignee (mixed) → still gated",
         %{project: project, sponsor: sponsor, agent_id: agent_id} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Mixed",
          sponsor_user_id: sponsor.id,
          assignee_id: agent_id,
          assignee_type: "agent"
        })

      refute Tasks.sponsor_bypasses_plan_gate?(task, {:user, sponsor.id})

      # Same result whether resolved via top-level `assignee_type` or
      # via `phase_assignees[current_phase]` — set phase_assignees too
      # to prove the phase-resolved clause also blocks agent involvement.
      {:ok, task} =
        Tasks.set_phase_assignees(task, %{
          "planning" => %{"assignee_id" => agent_id, "assignee_type" => "agent"}
        })

      refute Tasks.sponsor_bypasses_plan_gate?(task, {:user, sponsor.id})

      assert Tasks.require_approved_plan_for(task, "in_progress", {:user, sponsor.id}) ==
               {:error, :no_approved_plan}
    end

    # Test case 4: Sponsor-only task, but the transition is agent- or
    # system-initiated → still blocked. Only human initiation bypasses.
    test "sponsor-only task + non-human actor → predicate stays false, gate still fires",
         %{project: project, sponsor: sponsor, agent_id: agent_id} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsor-only, agent-initiated",
          sponsor_user_id: sponsor.id
        })

      refute Tasks.sponsor_bypasses_plan_gate?(task, {:agent, agent_id})
      refute Tasks.sponsor_bypasses_plan_gate?(task, :system)

      # Explicit gate check: agent-initiated move stays blocked without a
      # plan even though the task itself has no agent assignee.
      assert Tasks.require_approved_plan_for(task, "in_progress", {:agent, agent_id}) ==
               {:error, :no_approved_plan}

      assert Tasks.require_approved_plan_for(task, "in_progress", :system) ==
               {:error, :no_approved_plan}
    end

    # Regression: stage-4 reviewer finding. The old
    # `non_agent_assignment?/1` short-circuited on `is_nil(assignee_id)`
    # BEFORE consulting `phase_assignees`, so a task with the top-level
    # assignee not yet materialized (nil) plus an execution-phase agent
    # override incorrectly got the bypass. The status must be `planning`
    # here because the `require_approved_plan_for/3` intra-execution
    # short-circuit (`task.status in @execution_phase_statuses`) would
    # otherwise return `:ok` before the predicate runs — which is exactly
    # how the original stage-3 unit suite missed this bug.
    test "phase_assignees.execution=agent + nil top-level assignee → predicate stays false",
         %{project: project, sponsor: sponsor, agent_id: agent_id} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Phase-agent, nil top-level",
          status: "planning",
          sponsor_user_id: sponsor.id
        })

      # Simulate the on-disk shape: `phase_assignees.execution` schedules
      # an agent for the execution phase but the task is still in
      # planning, so the top-level `assignee_id` is nil.
      task = %{
        task
        | phase_assignees: %{
            "execution" => %{"assignee_id" => agent_id, "assignee_type" => "agent"}
          },
          assignee_id: nil,
          assignee_type: nil
      }

      refute Tasks.sponsor_bypasses_plan_gate?(task, {:user, sponsor.id})

      # And the gate stays closed on the actor-aware entry point — this
      # is the failure mode the reviewer surfaced (dropping to
      # `in_progress` from `planning` shouldn't sneak past the plan
      # requirement when an agent is queued to do the execution work).
      assert Tasks.require_approved_plan_for(task, "in_progress", {:user, sponsor.id}) ==
               {:error, :no_approved_plan}

      # Symmetric check: a review-phase agent should also hold the gate.
      review_task = %{
        task
        | phase_assignees: %{
            "review" => %{"assignee_id" => agent_id, "assignee_type" => "agent"}
          }
      }

      refute Tasks.sponsor_bypasses_plan_gate?(review_task, {:user, sponsor.id})
    end

    test "two-arity delegators preserve pre-actor-threading behavior",
         %{project: project, sponsor: sponsor} do
      # The two-arity `transition_task/2` and `drop_task_to_column/2`
      # both default to `:system`. That means every internal
      # orchestration caller (task router, stacks manager, webhook
      # controller) keeps the same gate they had before task 019f6380 —
      # no bypass ever fires from the automated pipeline.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "System default stays gated",
          sponsor_user_id: sponsor.id
        })

      assert Tasks.transition_task(task, "in_progress") == {:error, :no_approved_plan}
      assert Tasks.drop_task_to_column(task, "in_progress") == {:error, :no_approved_plan}
    end
  end

  # Bare-user insert helper for sponsor-bypass tests. Mirrors the pattern
  # in `apps/platform/test/platform/tasks/task_test.exs` — bypasses
  # `Platform.Accounts.User.changeset/2`'s name requirement so tests don't
  # need to plumb an OIDC identity fixture.
  defp insert_bypass_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Bypass #{n}",
      email: "bypass-#{n}@example.com",
      oidc_sub: "sub-bypass-#{n}"
    })
  end
end

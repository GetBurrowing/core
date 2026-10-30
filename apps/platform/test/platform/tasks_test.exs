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

      # Task 01a18e02 flipped this deliberately: humans are never blocked by
      # the plan gate, so a user actor passes even with an agent assigned.
      # The agent and system actors below still meet the gate.
      assert Tasks.require_approved_plan_for(task, "in_progress", {:user, sponsor.id}) == :ok

      assert Tasks.require_approved_plan_for(task, "in_progress", {:agent, agent_id}) ==
               {:error, :no_approved_plan}

      assert Tasks.require_approved_plan_for(task, "in_progress", :system) ==
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

      # Task 01a18e02 flipped this deliberately: humans are never blocked by
      # the plan gate, so a user actor passes even with an agent assigned.
      # The agent and system actors below still meet the gate.
      assert Tasks.require_approved_plan_for(task, "in_progress", {:user, sponsor.id}) == :ok

      assert Tasks.require_approved_plan_for(task, "in_progress", {:agent, agent_id}) ==
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

      # The predicate itself still says no (above). The gate's outcome for
      # this shape changed with task 01a18e02, deliberately: a user actor is
      # never plan-gated, while an agent queued for execution still is.
      assert Tasks.require_approved_plan_for(task, "in_progress", {:user, sponsor.id}) == :ok

      assert Tasks.require_approved_plan_for(task, "in_progress", {:agent, agent_id}) ==
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

  describe "similar_open_titles/3 — meeting-triage dedup gate" do
    setup do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Dedup #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/dedup"
        })

      {:ok, other_project} =
        Tasks.create_project(%{
          name: "Other #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/other"
        })

      %{project: project, other_project: other_project}
    end

    test "returns exact-match tasks", %{project: project} do
      {:ok, existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      assert [%Platform.Tasks.Task{id: id}] =
               Tasks.similar_open_titles(project.id, "Provision Neven Acme account")

      assert id == existing.id
    end

    test "case-insensitive + whitespace-normalized matching", %{project: project} do
      {:ok, existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      assert [%Platform.Tasks.Task{id: id}] =
               Tasks.similar_open_titles(project.id, "provision  neven  ACME  account")

      assert id == existing.id
    end

    test "matches near-duplicate above default threshold", %{project: project} do
      {:ok, existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      # Small typo variant — Jaro-Winkler ≥ 0.85 territory.
      matches = Tasks.similar_open_titles(project.id, "Provision Nevan Acme acct")

      assert Enum.any?(matches, fn %{id: id} -> id == existing.id end)
    end

    test "rejects unrelated titles below threshold", %{project: project} do
      {:ok, _existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      assert [] = Tasks.similar_open_titles(project.id, "Refactor billing pipeline")
    end

    test "opts[:threshold] overrides the default", %{project: project} do
      {:ok, existing} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      # With a very permissive threshold, even weakly-related titles hit.
      matches =
        Tasks.similar_open_titles(project.id, "Provision Acme whatever", threshold: 0.5)

      assert Enum.any?(matches, fn %{id: id} -> id == existing.id end)

      # Same call with the default threshold returns empty (0.5 → 0.85).
      assert [] = Tasks.similar_open_titles(project.id, "Provision Acme whatever")
    end

    test "wrong project is excluded", %{project: project, other_project: other} do
      {:ok, _existing} =
        Tasks.create_task(%{project_id: other.id, title: "Provision Neven Acme account"})

      assert [] = Tasks.similar_open_titles(project.id, "Provision Neven Acme account")
    end

    test "done + cancelled tasks are excluded", %{project: project} do
      {:ok, done_task} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      # Bypass the transition guard — flip status directly with an
      # Ecto.Changeset.change/2 update so we can test the query filter
      # without wiring an approved plan.
      done_task
      |> Ecto.Changeset.change(status: "done")
      |> Repo.update!()

      {:ok, cancelled_task} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account 2"})

      cancelled_task
      |> Ecto.Changeset.change(status: "cancelled")
      |> Repo.update!()

      assert [] = Tasks.similar_open_titles(project.id, "Provision Neven Acme account")
      assert [] = Tasks.similar_open_titles(project.id, "Provision Neven Acme account 2")
    end

    test "soft-deleted tasks are excluded", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Provision Neven Acme account"})

      task
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      assert [] = Tasks.similar_open_titles(project.id, "Provision Neven Acme account")
    end

    test "candidate titles shorter than 6 chars short-circuit to []", %{project: project} do
      {:ok, _existing} =
        Tasks.create_task(%{project_id: project.id, title: "Fix"})

      assert [] = Tasks.similar_open_titles(project.id, "Fix")
      assert [] = Tasks.similar_open_titles(project.id, "abc")
    end

    test "in_progress + in_review + planning + blocked all count as open", %{project: project} do
      {:ok, planning_task} =
        Tasks.create_task(%{project_id: project.id, title: "Ship Q3 launch plan"})

      planning_task
      |> Ecto.Changeset.change(status: "planning")
      |> Repo.update!()

      {:ok, blocked_task} =
        Tasks.create_task(%{project_id: project.id, title: "Ship Q3 launch plan v2"})

      blocked_task
      |> Ecto.Changeset.change(status: "blocked")
      |> Repo.update!()

      assert [_ | _] = Tasks.similar_open_titles(project.id, "Ship Q3 launch plan")
      assert [_ | _] = Tasks.similar_open_titles(project.id, "Ship Q3 launch plan v2")
    end

    test "non-binary candidate title returns []", %{project: project} do
      assert [] = Tasks.similar_open_titles(project.id, nil)
      assert [] = Tasks.similar_open_titles(project.id, 42)
    end
  end

  describe "promote/1 — meeting-triage `needs_promotion` flip" do
    setup do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Promote #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/promote"
        })

      %{project: project}
    end

    test "clears needs_promotion + broadcasts :task_updated on the kanban topic",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Filed under cap",
          needs_promotion: true
        })

      # Subscribe to the same kanban topic `update_task/2` broadcasts on
      # so we know the badge-removal signal reaches the LV.
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      assert {:ok, updated} = Tasks.promote(task)
      assert updated.needs_promotion == false

      task_id = task.id
      assert_receive {:task_updated, %{id: ^task_id, needs_promotion: false}}, 500
    end

    test "idempotent — promoting a task whose flag is false is a no-op",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Already promoted",
          needs_promotion: false
        })

      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      assert {:ok, returned} = Tasks.promote(task)
      assert returned.id == task.id

      # No broadcast — the idempotent branch skips `update_task/2`.
      refute_receive {:task_updated, _}, 200
    end

    # ── M5b (task 019f6e2c) Stage 2 — atomic backlog → planning transition ──

    test "backlog + needs_promotion: transitions status atomically with a single broadcast",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Backlog triage",
          status: "backlog",
          needs_promotion: true
        })

      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      assert {:ok, updated} = Tasks.promote(task)
      assert updated.needs_promotion == false
      assert updated.status == "planning"

      task_id = task.id

      # Exactly ONE broadcast — the atomic changeset flips both fields
      # in a single `update_task/2` call, so kanban subscribers see one
      # `:task_updated`, not two.
      assert_receive {:task_updated, %{id: ^task_id, status: "planning", needs_promotion: false}},
                     500

      refute_receive {:task_updated, _}, 200
    end

    test "planning + needs_promotion: clears flag but does NOT re-transition status",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Already-planning triage",
          status: "backlog",
          needs_promotion: true
        })

      # Manually flip to planning via a direct changeset to simulate the
      # task landing in planning by some other path (a router transition,
      # manual operator move) while still carrying the meeting flag.
      {:ok, planning_task} =
        task
        |> Ecto.Changeset.change(status: "planning")
        |> Platform.Repo.update()

      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      assert {:ok, updated} = Tasks.promote(planning_task)
      assert updated.needs_promotion == false
      # Status stays put — no downgrade / no re-transition.
      assert updated.status == "planning"

      task_id = task.id

      assert_receive {:task_updated, %{id: ^task_id, status: "planning", needs_promotion: false}},
                     500

      refute_receive {:task_updated, _}, 200
    end

    test "backlog without needs_promotion: no-op, no broadcast, no status change",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Backlog no-flag",
          status: "backlog",
          needs_promotion: false
        })

      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      assert {:ok, returned} = Tasks.promote(task)
      assert returned.status == "backlog"
      assert returned.needs_promotion == false

      refute_receive {:task_updated, _}, 200
    end
  end

  defp plan_review_task(status) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "PlanReview #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/plan-review"
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Reviewed"})

    {:ok, _plan} =
      %Platform.Tasks.Plan{}
      |> Platform.Tasks.Plan.changeset(%{task_id: task.id, version: 1, status: status})
      |> Repo.insert()

    task
  end

  describe "plan_pending_review?/1 — takes a TASK id" do
    # The `task_plan_review` inbox row's `source_id` is the task id, not the
    # plan id (see the `Inbox.emit` in `maybe_emit_plan_review_inbox/1`), so
    # the staleness predicate has to key on the task.
    test "true while a plan sits in pending_review" do
      task = plan_review_task("pending_review")
      assert Tasks.plan_pending_review?(task.id)
    end

    test "false once the plan is approved" do
      task = plan_review_task("approved")
      refute Tasks.plan_pending_review?(task.id)
    end

    # Both negatives matter: an approved-only test leaves the rejection path
    # silently broken.
    test "false once the plan is rejected" do
      task = plan_review_task("rejected")
      refute Tasks.plan_pending_review?(task.id)
    end

    test "false for a missing task and for an unresolvable id" do
      refute Tasks.plan_pending_review?(Ecto.UUID.generate())
      refute Tasks.plan_pending_review?(nil)
      refute Tasks.plan_pending_review?(:not_an_id)
    end
  end

  describe "eager plan-review inbox clear at approve_plan/reject_plan" do
    alias Platform.Inbox

    defp sponsor! do
      n = System.unique_integer([:positive])

      Repo.insert!(%Platform.Accounts.User{
        name: "Sponsor #{n}",
        email: "sponsor-#{n}@example.com",
        oidc_sub: "sponsor-sub-#{n}"
      })
    end

    # A sponsored task plus `plan_count` plans all sitting in `pending_review`,
    # and the sponsor's live `task_plan_review` row keyed on the TASK id.
    defp sponsored_review_task!(sponsor, plan_count \\ 1) do
      {:ok, project} =
        Tasks.create_project(%{
          name: "EagerClear #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/eager-clear"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Sponsored",
          sponsor_user_id: sponsor.id
        })

      plans =
        Enum.map(1..plan_count, fn v ->
          %Platform.Tasks.Plan{}
          |> Platform.Tasks.Plan.changeset(%{
            task_id: task.id,
            version: v,
            status: "pending_review"
          })
          |> Repo.insert!()
        end)

      {:ok, row} =
        Inbox.emit(%{
          user_id: sponsor.id,
          kind: "task_plan_review",
          source_type: "task",
          source_id: task.id,
          title: "Plan ready for review",
          url: "/tasks/#{task.id}"
        })

      {task, plans, row}
    end

    defp live?(row_id), do: is_nil(Repo.get!(Inbox.Item, row_id).dismissed_at)

    test "approval clears the sponsor's plan-review row" do
      sponsor = sponsor!()
      {_task, [plan], row} = sponsored_review_task!(sponsor)

      assert live?(row.id)
      assert {:ok, _} = Tasks.approve_plan(plan, sponsor.id)
      refute live?(row.id)
    end

    # Both verdicts, one assertion each. Wiring approval alone is exactly how
    # this class of gap arises: the rejection path settles the sponsor's
    # action just as completely and would otherwise leave the row live until
    # the next reconcile.
    test "rejection clears the sponsor's plan-review row" do
      sponsor = sponsor!()
      {_task, [plan], row} = sponsored_review_task!(sponsor)

      assert live?(row.id)
      assert {:ok, _} = Tasks.reject_plan(plan, sponsor.id, "not yet")
      refute live?(row.id)
    end

    # The e2e review of this task (case 3, 2026-08-14) found the eager clear
    # sweeping the sponsor's OTHER row into the same write. `dismiss_by_source`
    # keys on (user_id, source_type, source_id) and `task_sponsor_assigned`
    # carries the same triple, so an unfiltered sweep dismissed both with one
    # `dismissed_at` — undoing the "cleared by the human, by hand" decision
    # that `Inbox.row_stale?/1` documents. One assertion per side below: the
    # kind it owns goes, the kind it does not own stays.
    test "settling a plan clears ONLY the plan-review row, not the sponsor row" do
      sponsor = sponsor!()
      {task, [plan], review_row} = sponsored_review_task!(sponsor)

      {:ok, sponsor_row} =
        Inbox.emit(%{
          user_id: sponsor.id,
          kind: "task_sponsor_assigned",
          source_type: "task",
          source_id: task.id,
          title: "You sponsor this task",
          url: "/tasks/#{task.id}"
        })

      assert live?(review_row.id)
      assert live?(sponsor_row.id)

      assert {:ok, _} = Tasks.approve_plan(plan, sponsor.id)

      refute live?(review_row.id)
      # The half that fails an unfiltered sweep. Sponsorship is an ongoing
      # state with no resolution event; settling a plan is not its resolution.
      assert live?(sponsor_row.id)
    end

    # Same, through the rejection path — the eager clear runs on both verdicts,
    # so a kind filter present on one and absent on the other would be invisible
    # to the approval test alone.
    test "rejecting a plan also leaves the sponsor row alone" do
      sponsor = sponsor!()
      {task, [plan], review_row} = sponsored_review_task!(sponsor)

      {:ok, sponsor_row} =
        Inbox.emit(%{
          user_id: sponsor.id,
          kind: "task_sponsor_assigned",
          source_type: "task",
          source_id: task.id,
          title: "You sponsor this task",
          url: "/tasks/#{task.id}"
        })

      assert {:ok, _} = Tasks.reject_plan(plan, sponsor.id, "not yet")

      refute live?(review_row.id)
      assert live?(sponsor_row.id)
    end

    # The guard, from the other side: a task still holding a `pending_review`
    # plan keeps its row, because the sponsor still has something to review.
    test "row SURVIVES approval of one plan while a sibling stays pending_review" do
      sponsor = sponsor!()
      {_task, [plan_v1, _plan_v2], row} = sponsored_review_task!(sponsor, 2)

      assert {:ok, _} = Tasks.approve_plan(plan_v1, sponsor.id)
      assert live?(row.id)
    end

    # The eager clear is an OPTIMISATION BESIDE the reconciler, never the
    # mechanism. Bypass the eager call entirely — settle the plan with a raw
    # `Repo.update` that `Tasks` never sees — and the reconciler still clears
    # the same row. If this test ever fails, correctness has moved into the
    # eager path and every future resolution path must remember to call it.
    test "reconcile_for_user still clears the row when the eager call is bypassed" do
      sponsor = sponsor!()
      {_task, [plan], row} = sponsored_review_task!(sponsor)

      plan
      |> Ecto.Changeset.change(status: "approved")
      |> Repo.update!()

      assert live?(row.id)

      Inbox.reconcile_for_user(sponsor.id)
      refute live?(row.id)
    end

    # And after the eager clear has already run, the reconciler is a silent
    # no-op: nothing left to dismiss, so no second `{:inbox_changed, _}`.
    test "reconcile after an eager clear dismisses nothing and broadcasts nothing" do
      sponsor = sponsor!()
      {_task, [plan], row} = sponsored_review_task!(sponsor)

      assert {:ok, _} = Tasks.approve_plan(plan, sponsor.id)
      refute live?(row.id)

      Phoenix.PubSub.subscribe(Platform.PubSub, "inbox:#{sponsor.id}")

      Inbox.reconcile_for_user(sponsor.id)

      refute live?(row.id)
      refute_receive {:inbox_changed, _}, 200
    end
  end
end

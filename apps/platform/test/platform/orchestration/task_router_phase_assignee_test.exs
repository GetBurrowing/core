defmodule Platform.Orchestration.TaskRouterPhaseAssigneeTest do
  @moduledoc """
  Pins the phase-blind dispatch defect (task 019fb977).

  ## What this file claims

  `TaskRouter` freezes its `assignee` at `start_link/1` (`task_router.ex:136`),
  stores it in `init/1` (`:238`), and reads it at `:1262`
  (`Federation.lookup_assignment`), `:1282` (`dispatch_attention`), `:1295`
  (the execution-space `Assignee:` log line) and `:1702`
  (`maybe_hydrate_from_lease/1`). `grep -rn assignee_for_phase
  apps/platform/lib` returns only `tasks.ex` and `stacks.ex` — `task_router.ex`
  never calls it. So every dispatch after the one the router booted with goes
  to whichever runtime was current when the router started, regardless of
  which phase the task has since moved into.

  PRIOR-ART MARKER. The comment above `Tasks.maybe_apply_phase_assignee/1`
  used to read:

      # When a task crosses a phase boundary, re-derive the top-level
      # `assignee_id` / `assignee_type` from `phase_assignees[new_phase]`. This
      # is what makes the per-phase modal actually take effect: the runtime
      # router and every read path consults `task.assignee_id`, so it has to
      # match the new phase's configured agent.

  That claim is FALSE for the router, and its falseness is why 019f42fd's fix
  looked sufficient: 019f42fd repaired the flat POINTER after a status write
  and never made the CONSUMER phase-aware.

  CORRECTED IN STAGE 5 — do not go looking for that text in `tasks.ex`, it is
  no longer there. It is quoted above as the historical record of what the
  codebase believed, because the belief is the reason the defect survived a
  prior fix. The replacement comment at the same site now says what the
  router actually consults.

  ## Correction to this ticket's own analysis — read before re-litigating

  The originating ticket says step 4 is "a router keyed to the new assignee
  dispatches again", i.e. two agents at once for ONE task. That cannot happen.
  `Platform.Orchestration.Registry` is `keys: :unique`
  (`application.ex:39`) and `TaskRouter.via/1` (`task_router.ex:173`) keys on
  `task_id` alone, so `TaskRouterSupervisor.start_assignment/2` returns
  `{:error, {:already_started, pid}}` for a second router.
  `TaskRouterWatcher.evaluate_task/1` (`task_router_watcher.ex:1054`) only
  starts-if-missing and stops-if-ineligible; it never restarts a router
  because the assignee changed. For one task, a wrong-agent dispatch and a
  right-agent dispatch can therefore only be SEQUENTIAL, separated by a router
  restart (BEAM restart, `boot_reconcile/0`, or a status excursion outside
  `@active_statuses`).

  What this defect actually produces is not "two agents at once" — it is
  "the wrong agent, every phase after planning, silently".

  ## Telling 019fb977 apart from 019fb949 (they cite the SAME evidence)

    * 019fb949 (`HeartbeatScheduler.short_task_id/1` 8-char truncation) — the
      two dispatches carry two DIFFERENT `task_id`s, the rendered
      `git worktree add` lines are byte-identical, and the branch name is
      shorter than 36 characters. That ticket explains the observed
      2026-07-31 symptom (two agents, one worktree, one branch) on its own.
      Its file is `heartbeat_scheduler.ex`; nothing here touches it.
    * 019fb977 (this file) — ONE `task_id`, and
      `TaskRouter.current_status(task_id).assignee.id` disagrees with the
      runtime behind `phase_assignees[current_phase(task)]`.

  ## Expected state of this file at stage 1

  Case 0 is GREEN at origin/main and must stay green — it is the observer
  control, and a red case 0 means the harness is broken rather than the code.
  Cases 1, 2 and 3 are RED at origin/main BY DESIGN; stage 2 turns them green
  by re-resolving the dispatch runtime from the task's current phase. Do not
  weaken, skip or tag them.

  Case 3 is the de-masking case: it forces the flat `assignee_id` pointer
  stale by construction AFTER the phase assignment, so no amount of
  writer-side pointer hygiene (019f42fd's shape, and stage 4's single-write
  fold) can satisfy it. Only a phase-aware CONSUMER can.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeSupervision
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task, as: TaskSchema

  # Fixed OBSERVATION window, not a synchronisation sleep: every assertion in
  # this file is about the SET of dispatches that occur (and their count), so
  # the test has to hold the door open for a bounded interval and then close
  # it. There is no single observable to barrier on — "no second dispatch
  # arrived" is an absence claim, and absence is only ever provable against a
  # window.
  @observe_ms 1_500

  setup do
    # Routers are started from this process but do their own Repo work.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Phase Assignee Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/phase-assignee"
      })

    # TWO fully-linked agent/runtime pairs. A synthetic
    # `%{type: :federated, id: "runtime-..."}` string (the shape
    # `task_router_test.exs:203` uses) cannot exercise agent -> runtime
    # resolution at all, which is the entire mechanism under test.
    {agent_a, runtime_a} = create_linked_agent_runtime("planning")
    {agent_b, runtime_b} = create_linked_agent_runtime("execution")

    approver = create_user()

    %{
      project: project,
      agent_a: agent_a,
      runtime_a: runtime_a,
      agent_b: agent_b,
      runtime_b: runtime_b,
      approver: approver
    }
  end

  # ── Case 0: THE COUNTING CONTROL ──────────────────────────────────────
  #
  # Written first and expected GREEN at origin/main. "Assert exactly one
  # dispatch" is worthless if the observer cannot see two, so this proves the
  # counter reaches 2 and can NAME which runtime each dispatch landed on.
  describe "observer control" do
    test "the harness observes two dispatches on two runtimes and can name each", %{
      project: project,
      agent_a: agent_a,
      runtime_a: runtime_a,
      agent_b: agent_b,
      runtime_b: runtime_b
    } do
      subscribe_to_both(runtime_a, runtime_b)

      task_a = dispatchable_task(project, agent_a, "in_progress")
      task_b = dispatchable_task(project, agent_b, "in_progress")

      start_router!(task_a.id, runtime_a)
      start_router!(task_b.id, runtime_b)

      topics = collect_attention_topics()

      assert length(topics) == 2,
             "observer control failed: expected 2 attention broadcasts, saw #{inspect(topics)}"

      assert Enum.sort(topics) == Enum.sort(["runtime:#{runtime_a}", "runtime:#{runtime_b}"])
    end
  end

  # ── Case 1: ASSIGNED BEFORE THE ROUTER STARTS ─────────────────────────
  describe "phase assignee resolved at dispatch time" do
    test "planning->execution dispatch goes to the EXECUTION phase agent, not the planner", %{
      project: project,
      agent_a: agent_a,
      runtime_a: runtime_a,
      agent_b: agent_b,
      runtime_b: runtime_b,
      approver: approver
    } do
      subscribe_to_both(runtime_a, runtime_b)

      task =
        project
        |> create_task!()
        |> put_task_fields(%{
          status: "planning",
          assignee_id: agent_a.id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => phase_entry(agent_a),
            "execution" => phase_entry(agent_b)
          }
        })

      plan = create_plan_with_stage!(task, "pending_review")

      # Router boots with the PLANNING runtime — legitimately, that is who
      # owns the task right now.
      start_router!(task.id, runtime_a)

      # Approving drives `apply_dispatch_gate/1` -> `planning` -> `in_progress`
      # (`tasks.ex:3494`), so the task crosses into the EXECUTION phase while
      # this router is alive.
      {:ok, _approved} = Tasks.approve_plan(plan, approver.id, [])

      topics = collect_attention_topics()

      # A zero-length list here is a HARNESS failure, not the failure this
      # test claims. Say which one happened.
      refute topics == [],
             "no dispatch observed at all — the harness never saw the router dispatch, " <>
               "which is not the defect this test claims"

      assert topics == ["runtime:#{runtime_b}"],
             "expected exactly one dispatch, on the execution agent's runtime " <>
               "(runtime:#{runtime_b}); saw #{inspect(topics)}"
    end

    # ── Case 2: REASSIGNED WHILE THE ROUTER IS RUNNING ──────────────────
    #
    # NON-OPTIONAL. This is the shape that actually occurred on 2026-07-31.
    # A suite covering only case 1 goes green while the live bug survives,
    # because case 1 can also be satisfied by making the router pick up a
    # correct value once at boot.
    test "reassigning the execution phase on a LIVE router redirects the next dispatch", %{
      project: project,
      agent_a: agent_a,
      runtime_a: runtime_a,
      agent_b: agent_b,
      runtime_b: runtime_b
    } do
      subscribe_to_both(runtime_a, runtime_b)

      task =
        project
        |> create_task!()
        |> put_task_fields(%{
          status: "in_progress",
          assignee_id: agent_a.id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => phase_entry(agent_a),
            "execution" => phase_entry(agent_a)
          }
        })

      _plan = create_plan_with_stage!(task, "approved")

      pid = start_router!(task.id, runtime_a)

      # First dispatch is CORRECT — A owns the execution phase right now.
      first = collect_attention_topics()

      assert first == ["runtime:#{runtime_a}"],
             "setup precondition failed: the first dispatch should land on the " <>
               "originally-assigned runtime; saw #{inspect(first)}"

      # Reassign the execution phase to B on the LIVE router. No stop, no
      # restart, same pid — this is the whole point.
      {:ok, _reassigned} =
        Tasks.set_phase_assignees(task, %{
          "execution" => %{"assignee_id" => agent_b.id, "assignee_type" => "agent"}
        })

      assert [{^pid, _}] = Registry.lookup(Platform.Orchestration.Registry, task.id),
             "the router was torn down and respawned; this test is about a LIVE router"

      send(pid, :dispatch)

      second = collect_attention_topics()

      refute second == [],
             "no dispatch observed after reassignment — harness failure, not the claimed defect"

      assert Enum.uniq(second) == ["runtime:#{runtime_b}"],
             "after reassigning the execution phase to agent B, every dispatch must land on " <>
               "runtime:#{runtime_b}; saw #{inspect(second)}"

      assert TaskRouter.current_status(task.id).assignee.id == runtime_b,
             "the router's own view of its assignee still disagrees with the DB"
    end

    # ── Case 3: THE DE-MASKING CASE ─────────────────────────────────────
    #
    # Exists specifically so stage 4's single-write fold cannot mask stage 2's
    # phase-aware resolver. The flat pointer is forced stale by construction
    # AFTER the phase assignment, reproducing the exact 019f42fd regression
    # shape: `phase_assignees` intact, `current_phase == "execution"`, flat
    # pointer back at the planning agent. No writer-side hygiene can satisfy
    # this; only a phase-aware reader can.
    #
    # MEASURED at the end of stage 4, with the fold landed and
    # `PhaseRuntime.phase_assignee/1` mutated back to the flat pointer
    # (`{task.assignee_id, task.assignee_type}`):
    #
    #   1) test ... dispatch follows phase_assignees even when the flat pointer is stale
    #      with a stale flat pointer, dispatch must still follow
    #      phase_assignees["execution"] to runtime:phase-execution-runtime-867;
    #      saw ["runtime:phase-planning-runtime-739"]
    #
    # Cases 1 and 2 went GREEN under that same mutation — stage 4's fold
    # makes the flat pointer correct at dispatch time, so they no longer
    # distinguish the two mechanisms. This case is the ONLY one in the file
    # that still does. Do not consolidate it into cases 1-2 and do not
    # "simplify" the `Repo.update_all`; that update is the test.
    test "dispatch follows phase_assignees even when the flat pointer is stale", %{
      project: project,
      agent_a: agent_a,
      runtime_a: runtime_a,
      agent_b: agent_b,
      runtime_b: runtime_b
    } do
      subscribe_to_both(runtime_a, runtime_b)

      task =
        project
        |> create_task!()
        |> put_task_fields(%{
          status: "in_progress",
          assignee_id: agent_b.id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => phase_entry(agent_a),
            "execution" => phase_entry(agent_b)
          }
        })

      _plan = create_plan_with_stage!(task, "approved")

      # Force the flat pointer stale WITHOUT touching `phase_assignees`, and
      # without going through any changeset that would re-derive it.
      {1, _} =
        from(t in TaskSchema, where: t.id == ^task.id)
        |> Repo.update_all(set: [assignee_id: agent_a.id, assignee_type: "agent"])

      reloaded = Repo.get!(TaskSchema, task.id)

      assert reloaded.assignee_id == agent_a.id,
             "fixture precondition failed: the flat pointer was not forced stale"

      assert Tasks.current_phase(reloaded) == "execution"

      assert {id_b, "agent"} = Tasks.assignee_for_phase(reloaded, "execution")
      assert id_b == agent_b.id

      start_router!(task.id, runtime_a)

      topics = collect_attention_topics()

      refute topics == [],
             "no dispatch observed at all — harness failure, not the claimed defect"

      assert Enum.uniq(topics) == ["runtime:#{runtime_b}"],
             "with a stale flat pointer, dispatch must still follow " <>
               "phase_assignees[\"execution\"] to runtime:#{runtime_b}; saw #{inspect(topics)}"
    end
  end

  # ── The two refusal behaviours, which are NOT the same behaviour ───────
  #
  # `PhaseRuntime.resolve/1` has five failure atoms and the router splits them
  # in two: `:user_assignee` SUPPRESSES, everything else FAILS OPEN. These two
  # tests are the pair that pins that split. If both suppressed, a resolution
  # hiccup would strand the task with no prompt and no operator signal; if both
  # fell open, a human-owned phase would dispatch to whichever agent the router
  # happened to be holding — the phase-blind bug wearing a different hat.
  describe "unresolvable phase runtimes" do
    test "a USER phase assignee suppresses the dispatch entirely", %{
      project: project,
      agent_a: agent_a,
      runtime_a: runtime_a,
      runtime_b: runtime_b
    } do
      subscribe_to_both(runtime_a, runtime_b)
      attach_suppression_telemetry()

      user = create_user()

      task =
        project
        |> create_task!()
        |> put_task_fields(%{
          status: "in_progress",
          assignee_id: agent_a.id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => phase_entry(agent_a),
            "execution" => %{"assignee_id" => user.id, "assignee_type" => "user"}
          }
        })

      _plan = create_plan_with_stage!(task, "approved")

      start_router!(task.id, runtime_a)

      assert collect_attention_topics() == [],
             "a human-owned phase has no runtime to dispatch to; falling back to the " <>
               "previously-held agent is the original bug wearing a different hat"

      assert_received {:dispatch_suppressed, %{task_id: suppressed_id, reason: reason}}
      assert suppressed_id == task.id
      assert reason == :user_phase_assignee

      # The router must stay healthy — a suppression is not a stall.
      assert TaskRouter.current_status(task.id).status != :stalled
    end

    test "an unresolvable AGENT runtime fails open to the held assignee", %{
      project: project,
      agent_a: agent_a,
      runtime_a: runtime_a,
      runtime_b: runtime_b
    } do
      subscribe_to_both(runtime_a, runtime_b)
      attach_suppression_telemetry()

      # The ONLY fixture in this file that can reach the fail-open arm: a real
      # `Agent` row that was deliberately never linked to a runtime, so
      # `PhaseRuntime.resolve/1` can answer nothing but `:no_runtime`. A
      # mutation deleting the fail-open arm must turn exactly THIS test red
      # while every case above stays green.
      unlinked = create_agent("unlinked")
      assert unlinked.runtime_id == nil

      task =
        project
        |> create_task!()
        |> put_task_fields(%{
          status: "in_progress",
          assignee_id: agent_a.id,
          assignee_type: "agent",
          phase_assignees: %{
            "planning" => phase_entry(agent_a),
            "execution" => phase_entry(unlinked)
          }
        })

      _plan = create_plan_with_stage!(task, "approved")

      start_router!(task.id, runtime_a)

      topics = collect_attention_topics()

      assert topics == ["runtime:#{runtime_a}"],
             "a transient resolution failure must cost one dispatch to the held runtime, " <>
               "not a stalled task; saw #{inspect(topics)}"

      refute_received {:dispatch_suppressed, _meta},
                      "fail-open must not emit a suppression event — that would make " <>
                        ":no_runtime indistinguishable from :user_assignee in telemetry"

      status = TaskRouter.current_status(task.id)

      assert status.assignee.id == runtime_a
      assert status.assignee_source == :frozen_fallback
      assert status.phase == "execution"
    end
  end

  # ── A lease held by the WRONG runtime (stage 3) ────────────────────────
  #
  # Stages 1-2 stop new wrong dispatches. They do nothing for a task where the
  # wrong agent is already mid-flight: `maybe_hydrate_from_lease/1` matched a
  # lease whose `runtime_id == state.assignee.id` and dropped everything else
  # through a bare `_ -> state`. That fall-through is a live `active`/`blocked`
  # `execution_leases` row proving a DIFFERENT runtime holds this task's
  # current stage — and it was discarded without a log line.
  #
  # The three tests below share ONE fixture helper. The only difference between
  # the emitting case and the negative control is the runtime id on the lease
  # row: `drift_fixture(..., runtime_a)` vs `drift_fixture(..., runtime_b)`.
  # That is deliberate. A negative control built from a different fixture — one
  # with no lease, or a lease on a `passed` stage — proves nothing, because it
  # could not reach the emitting code under ANY guard. This one reaches the
  # exact same case clause and is stopped only by the runtime-id comparison.
  describe "foreign lease on the running stage" do
    test "emits one assignee_drift, logs both runtimes, and abandons the lease", %{
      project: project,
      agent_a: agent_a,
      runtime_a: runtime_a,
      agent_b: agent_b,
      runtime_b: runtime_b
    } do
      %{task: task, stage: stage, lease: lease} =
        drift_fixture(project, agent_a, agent_b, runtime_a)

      Tasks.subscribe_board()

      # Router boots as the PHASE-CORRECT runtime (B owns the execution
      # phase) while the live lease is held by A. This is the "wrong agent
      # already mid-flight" state, not a mis-started router.
      start_router!(task.id, runtime_b)

      # Barrier: a pure `GenServer.call` is answered strictly after `init/1`
      # and every message already queued has been handled.
      status = TaskRouter.current_status(task.id)

      drifts = collect_drift_events()

      assert length(drifts) == 1,
             "expected exactly one execution.assignee_drift; saw #{length(drifts)}"

      [%{event_type: "execution.assignee_drift", payload: payload} = event] = drifts

      assert event.task_id == task.id
      assert event.stage_id == stage.id
      assert payload["expected_runtime_id"] == runtime_b
      assert payload["actual_runtime_id"] == runtime_a
      assert payload["phase"] == "execution"
      assert payload["lease_id"] == lease.id

      # The execution space is where a human actually reads. A runtime id
      # pair in a Logger line is not a substitute.
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      drift_logs =
        space.id
        |> ExecutionSpace.list_messages_with_participants()
        |> Enum.filter(&String.contains?(&1.content, "Assignee drift"))

      assert length(drift_logs) == 1

      [log] = drift_logs
      assert String.contains?(log.content, runtime_a)
      assert String.contains?(log.content, runtime_b)
      assert String.contains?(log.content, "execution")

      # RECOVERABILITY, not just visibility: the wrong agent's next ack has no
      # live lease left to extend.
      reloaded = Repo.get!(ExecutionLease, lease.id)
      assert reloaded.status == "abandoned"
      assert DateTime.compare(reloaded.expires_at, DateTime.utc_now()) != :gt

      # PRESERVED: a foreign lease must not hydrate liveness. Crediting this
      # router's assignee with another runtime's heartbeat is precisely the
      # confusion the drift event exists to end.
      assert status.lease_status == nil
      assert status.last_runtime_event_at == nil
    end

    test "a second hydrate emits nothing — the abandon IS the idempotency", %{
      project: project,
      agent_a: agent_a,
      runtime_a: runtime_a,
      agent_b: agent_b,
      runtime_b: runtime_b
    } do
      %{task: task, stage: stage, lease: lease} =
        drift_fixture(project, agent_a, agent_b, runtime_a)

      Tasks.subscribe_board()

      start_router!(task.id, runtime_b)
      _ = TaskRouter.current_status(task.id)

      first = collect_drift_events()
      assert length(first) == 1, "first boot must emit exactly one drift event"

      # The structural argument, asserted rather than described:
      # `abandon_current_lease_for_task/2` sets `status: "abandoned"` and
      # `expires_at: now`, and `current_lease_for_stage/2` filters on
      # `status in ~w(active blocked)` AND `expires_at > now`. So the lookup
      # the second hydrate performs finds NOTHING — there is no seen-set, and
      # there is nothing for a seen-set to remember.
      #
      # MEASURED, stage 5 control M5. Deleting the
      # `abandon_current_lease_for_task/2` call while keeping the emission
      # turns this test red HERE, on the precondition, before the count below
      # is ever reached — so this test's own failure message names the missing
      # abandon rather than a double emission. Relaxing these two lines and
      # re-running showed what the count does: the restarted router re-emits,
      # and `second` arrives holding one full drift payload. The idempotency
      # claim is therefore structural and observable, not incidental — but if
      # you are reading a red run of this test, read line 552 before assuming
      # you have a duplicate-emission bug.
      assert Repo.get!(ExecutionLease, lease.id).status == "abandoned"
      assert RuntimeSupervision.current_lease_for_stage(task.id, stage.id) == nil

      stop_router(task.id)

      # Full restart, the same path a BEAM restart or `boot_reconcile/0`
      # takes — `init/1` runs `maybe_hydrate_from_lease/1` again from scratch.
      start_router!(task.id, runtime_b)
      _ = TaskRouter.current_status(task.id)

      second = collect_drift_events()

      assert second == [],
             "the restarted router re-emitted drift for an already-abandoned lease: " <>
               "#{inspect(Enum.map(second, & &1.payload))}"
    end

    # ── THE NEGATIVE CONTROL ────────────────────────────────────────────
    #
    # Same fixture builder, one argument changed: the lease is held by the
    # runtime the router dispatches to. Every precondition asserted below is
    # the one an unconditional guard would trip over — the lease exists, the
    # stage-scoped lookup finds it, and it is not filtered as historical. If
    # `note_foreign_lease/2` were called for every non-nil lease instead of
    # only for a mismatched one, THIS test would emit a drift event and
    # abandon a perfectly good lease. That is what makes the `refute` here a
    # statement about the guard rather than about the fixture.
    test "a lease held by the CORRECT runtime emits nothing and still hydrates", %{
      project: project,
      agent_a: agent_a,
      runtime_a: _runtime_a,
      agent_b: agent_b,
      runtime_b: runtime_b
    } do
      %{task: task, stage: stage, lease: lease} =
        drift_fixture(project, agent_a, agent_b, runtime_b)

      # Precondition 1: the lease is live and the stage-scoped lookup — the
      # exact call `maybe_hydrate_from_lease/1` makes — returns it.
      found = RuntimeSupervision.current_lease_for_stage(task.id, stage.id)
      assert found != nil, "fixture cannot reach the code under test: no live lease"
      assert found.id == lease.id
      assert found.runtime_id == runtime_b

      # Precondition 2: the stage is `running`, not `passed`, so
      # `lease_targets_passed_stage?/2` does NOT drop this lease before the
      # case clause sees it.
      assert Repo.get!(Stage, stage.id).status == "running"

      Tasks.subscribe_board()

      start_router!(task.id, runtime_b)
      status = TaskRouter.current_status(task.id)

      assert collect_drift_events() == [],
             "drift emitted for a lease held by the router's own runtime"

      # And the pre-existing behaviour is intact: a matching lease still
      # hydrates. A guard that suppressed the emission by suppressing the
      # whole clause would fail here.
      assert status.lease_status == "active"
      assert status.last_runtime_event_at != nil

      assert Repo.get!(ExecutionLease, lease.id).status == "active",
             "the correct runtime's lease was abandoned"
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────

  # A task whose EXECUTION phase resolves to agent/runtime B, with an approved
  # plan, a RUNNING stage, and one live lease on that stage held by
  # `lease_runtime_id`. Pass runtime_a for the drift case and runtime_b for the
  # negative control — one argument is the entire difference.
  defp drift_fixture(project, agent_a, agent_b, lease_runtime_id) do
    task =
      project
      |> create_task!()
      |> put_task_fields(%{
        status: "in_progress",
        assignee_id: agent_b.id,
        assignee_type: "agent",
        phase_assignees: %{
          "planning" => phase_entry(agent_a),
          "execution" => phase_entry(agent_b)
        }
      })

    plan = create_plan_with_stage!(task, "approved")
    stage = running_stage!(plan)

    now = DateTime.utc_now()

    lease =
      %ExecutionLease{}
      |> ExecutionLease.changeset(%{
        task_id: task.id,
        stage_id: stage.id,
        phase: "execution",
        runtime_id: lease_runtime_id,
        status: "active",
        started_at: now,
        expires_at: DateTime.add(now, 3_600, :second)
      })
      |> Repo.insert!()

    %{task: task, stage: stage, lease: lease}
  end

  # Flip the plan's single stage to `running` without going through
  # `Tasks.update_stage/2`, whose broadcast would race the router we have not
  # started yet.
  defp running_stage!(plan) do
    Stage
    |> Repo.get_by!(plan_id: plan.id)
    |> Ecto.Changeset.change(status: "running")
    |> Repo.update!()
  end

  defp collect_drift_events(window_ms \\ @observe_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    drain_drift(deadline, [])
  end

  # Selective receive: everything that is not a drift event stays in the
  # mailbox, so this collector can run alongside the attention collector
  # without either eating the other's messages.
  defp drain_drift(deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:runtime_event, %{event_type: "execution.assignee_drift"} = event} ->
          drain_drift(deadline, [event | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp attach_suppression_telemetry do
    test_pid = self()
    handler_id = "phase-assignee-suppressed-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :orchestration, :dispatch_suppressed],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:dispatch_suppressed, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp subscribe_to_both(runtime_a, runtime_b) do
    PlatformWeb.Endpoint.subscribe("runtime:#{runtime_a}")
    PlatformWeb.Endpoint.subscribe("runtime:#{runtime_b}")
    :ok
  end

  defp collect_attention_topics(window_ms \\ @observe_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    drain_attention(deadline, [])
  end

  defp drain_attention(deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        %Phoenix.Socket.Broadcast{event: "attention", topic: topic} ->
          drain_attention(deadline, [topic | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp create_user do
    Repo.insert!(%User{
      email: "phase_assignee_#{System.unique_integer([:positive])}@example.com",
      name: "Phase Assignee Test User",
      oidc_sub: "oidc-phase-assignee-#{System.unique_integer([:positive])}"
    })
  end

  defp create_agent(label) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "phase-#{label}-agent-#{System.unique_integer([:positive])}",
        name: "Phase #{label} Agent",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  defp create_linked_agent_runtime(label) do
    user = create_user()
    agent = create_agent(label)

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "phase-#{label}-runtime-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end

  defp create_task!(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Phase Assignee Task #{System.unique_integer([:positive])}",
        description: "Pins phase-blind dispatch",
        deploy_target: "production"
      })

    task
  end

  # Fixture construction, deliberately bypassing `Tasks.update_task/2`: the
  # point is to build the exact DB state the incident had, not to exercise the
  # writers that would normalise it on the way in.
  defp put_task_fields(%TaskSchema{} = task, fields) do
    task
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
  end

  defp phase_entry(%Agent{} = agent) do
    %{"assignee_id" => agent.id, "assignee_type" => "agent"}
  end

  defp create_plan_with_stage!(%TaskSchema{} = task, plan_status) do
    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, status: plan_status, version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "coding",
        description: "Write code"
      })

    {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    plan
  end

  # A task the router will dispatch for on boot: active status, agent
  # assignee, approved plan with a stage to be about.
  defp dispatchable_task(project, agent, status) do
    task =
      project
      |> create_task!()
      |> put_task_fields(%{
        status: status,
        assignee_id: agent.id,
        assignee_type: "agent",
        phase_assignees: %{"planning" => phase_entry(agent), "execution" => phase_entry(agent)}
      })

    _plan = create_plan_with_stage!(task, "approved")

    task
  end

  defp start_router!(task_id, runtime_id) do
    {:ok, pid} =
      TaskRouter.start_link(task_id: task_id, assignee: %{type: :federated, id: runtime_id})

    on_exit(fn -> stop_router(task_id) end)

    pid
  end

  defp stop_router(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end

    # LeaseManager is a global singleton — purge this task's row so it does
    # not leak into the next test.
    case :ets.info(:orchestration_lease_manager) do
      :undefined -> :ok
      _ -> LeaseManager.clear(task_id)
    end
  end
end

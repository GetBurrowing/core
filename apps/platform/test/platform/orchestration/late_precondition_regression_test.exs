defmodule Platform.Orchestration.LatePreconditionRegressionTest do
  @moduledoc """
  One durable guard for the late-precondition defect class named in
  `docs/decisions/0047-late-precondition-promotion.md` (task 019fbe9e).

  The class: **a status transition whose only writer sits inside another
  operation's cascade or inside an in-memory PubSub handler, with no path that
  fires when the precondition becomes true LATER.**

  Every fixture in this file is built so the precondition arrives LATE. That
  ordering is the entire point: a fixture that arranges the precondition before
  the edge fires passes against the pre-fix tree and proves nothing.

  ## What this file does and does not contain

  The consolidation stage briefed five cases, one per reported "face". Three of
  the five faces were investigated by earlier stages of the same task and two
  of those turned out not to be defects. A test asserting a fix that was never
  made is either vacuous or asserts the wrong thing, so the cases here track
  the MEASURED state rather than the reported one:

    * Case 1 — gate opens late. Face VERIFIED, fixed by
      `Stacks.sweep_stack_pending_members/0`. Written.
    * Case 2 — dependency clears late. Face VERIFIED, fixed by the same sweep.
      Written, with the two arrivals separated (see below).
    * Case 3 — re-running the sweep is a no-op. Written, with its limitation
      stated at the test.
    * Case 4 — task reaches `in_progress` with every stage `pending`. Face
      VERIFIED, fixed by wiring `ensure_execution_stage_started/2` into the
      `{:task_updated, _}` handler. Written, both disjuncts.
    * Case 5 — settled plan must not trip the safety net. The reported face
      ("a completed plan does not advance the task") was FALSIFIED by stage 4:
      the advance is synchronous inside `PlanCompletion.advance_task/2`, called
      by the only writer of `plan.status = "completed"` before any broadcast,
      so router liveness cannot affect it. What IS real is the suppression
      half, so case 5 asserts the observable an operator complained about —
      no safety-net runtime_event and no blocker post — and names the
      mechanism it actually travels through.

  The per-stage tests from stages 2-5 stay where they are; this file is the
  cross-cutting guard, not a copy of them.
  """

  use Platform.DataCase, async: false

  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stacks
  alias Platform.Tasks.Stacks.CommencementGate
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{name: "Late precondition #{System.unique_integer([:positive])}"})

    %{project: project}
  end

  # ──────────────────────────────────────────────────────────────────────
  # Case 1 — the commencement gate opens LATE
  # ──────────────────────────────────────────────────────────────────────

  describe "case 1: the gate opens after the stack has already commenced" do
    test "a parked member with no unmet dependency promotes on the next sweep", %{
      project: project
    } do
      %{stack: stack, members: [_a, b]} = stack_with_members(project, 2, withhold_last_plan: true)

      # The stack is ALREADY past `forming`. `commence_if_ready/1` and
      # `start_stack/1` both refuse a stack in this state, so the cascade that
      # would have promoted these members has already run and cannot run again.
      commence!(stack)
      park!(b)

      # The gate is closed here: `b`'s plan is not approved yet, so
      # `plans_ready?/1` is false.
      refute CommencementGate.open?(reload(b))
      assert status(b.id) == "stack_pending"

      # The precondition arrives LATE — the last plan is approved long after
      # the stack commenced.
      approve_plan!(b)
      assert CommencementGate.open?(reload(b))

      # The status assertion comes FIRST deliberately. Matching on the sweep's
      # `promoted:` counter first would fail on a MISSING MAP KEY against a
      # tree without the sweep, reporting "no such key" instead of naming the
      # member that never promoted.
      sweep = Stacks.reconcile_stack_lifecycle()

      # Asserted on the re-fetched MEMBER status. NEVER on
      # `CommencementGate.open?/1` — the gate read open throughout the live
      # incident, so a gate assertion cannot distinguish fixed from broken.
      # (The `open?/1` calls above are fixture provenance, not the outcome.)
      assert status(b.id) == "in_progress"
      assert %{promoted: promoted} = sweep
      assert promoted >= 1
    end

    test "ANTI-VACUITY: a member whose in-stack dependency is unmet is left parked", %{
      project: project
    } do
      # The same fixture with the precondition NOT met. Without this, case 1
      # cannot distinguish "the sweep re-derives the precondition" from "the
      # sweep promotes every parked member unconditionally".
      #
      # NOTE, and this is a real limitation of the shipped fix rather than of
      # the test: the precondition varied here is the DEPENDENCY threshold, not
      # the gate. `try_promote/1` consults `unblocked_in_stack?/1` only; it
      # never reads `CommencementGate.open?/1`. So the sweep will promote a
      # dep-free member of an `in_progress` stack whose gate is still closed.
      # Case 1's positive fixture opens the gate because that is the reported
      # face, but the gate is not what the code keys on, and a control that
      # only closed the gate would go GREEN and prove nothing.
      %{stack: stack, members: [a, b]} = stack_with_members(project, 2, depend: true)

      commence!(stack)
      park!(b)
      set!(a, %{status: "in_progress"})

      _ = Stacks.reconcile_stack_lifecycle()
      assert status(b.id) == "stack_pending"
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Case 2 — the dependency clears LATE
  # ──────────────────────────────────────────────────────────────────────

  describe "case 2: an in-stack dependency clears after the stack has commenced" do
    test "the dependent promotes only once BOTH halves of the unblock threshold arrive", %{
      project: project
    } do
      %{stack: stack, members: [dep, dependent]} = stack_with_members(project, 2, depend: true)

      commence!(stack)
      park!(dependent)
      set!(dep, %{status: "in_progress"})

      # Phase 1 — ANTI-VACUITY. Neither half of the threshold has arrived.
      _ = Stacks.reconcile_stack_lifecycle()
      assert status(dependent.id) == "stack_pending"

      # Phase 2 — the rollup-merge STAMP arrives, and only the stamp. The
      # threshold is `member_landed_on_rollup?/1`, a conjunction of the stamp
      # AND a landed status, so a fixture that moves both at once cannot say
      # which arrival is load-bearing. Stage 2's own test flagged that
      # weakness; this separates them.
      set!(dep, %{metadata: %{"merged_into_rollup_at" => landed_stamp()}})

      _ = Stacks.reconcile_stack_lifecycle()

      assert status(dependent.id) == "stack_pending",
             "the stamp alone cleared the threshold — the landed-status conjunct is not load-bearing"

      # Phase 3 — the STATUS arrives, LATE, and by a path that never crosses
      # the nil -> set edge of the stamp inside `update_task/3`. That edge is
      # the only trigger for `sweep_stack_dependents/1`, so nothing cascades
      # here; the promotion can only come from the reconcile sweep.
      set!(dep, %{status: "done"})

      sweep = Stacks.reconcile_stack_lifecycle()
      assert status(dependent.id) == "in_progress"
      assert %{promoted: 1} = sweep
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Case 3 — re-running the sweep
  # ──────────────────────────────────────────────────────────────────────

  describe "case 3: re-running the sweep" do
    test "a second pass changes no status and does not touch updated_at", %{project: project} do
      # LIMITATION, stated so the next reader does not inherit false
      # confidence: this test passes, but it cannot tell you WHICH guard is
      # holding. Idempotency here is over-determined by three independent
      # layers — the sweep's `status == "stack_pending"` query filter,
      # `try_promote/1`'s status-guarded head, and `transition_task/2`'s
      # rejection of the identity transition (`@valid_task_transitions` has no
      # `"in_progress" -> "in_progress"` edge). Stage 2 ran mutation probes
      # against the first two, separately and together, and all three probes
      # stayed green with zero blast radius. So a green here proves the
      # OBSERVABLE is stable; it does not prove any one guard is tested.
      %{stack: stack, members: [_a, b]} = stack_with_members(project, 2)

      commence!(stack)
      park!(b)
      approve_plan!(b)

      first_sweep = Stacks.reconcile_stack_lifecycle()
      first = Repo.get!(Task, b.id)
      assert first.status == "in_progress"
      assert %{promoted: 1} = first_sweep

      assert %{promoted: 0} = Stacks.reconcile_stack_lifecycle()
      second = Repo.get!(Task, b.id)

      assert second.status == "in_progress"
      assert second.updated_at == first.updated_at
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Case 4 — the task reaches `in_progress` with every stage still pending
  # ──────────────────────────────────────────────────────────────────────

  describe "case 4: in_progress arrives after the plan was approved" do
    setup do
      %{assignee: %{type: :federated, id: "runtime-#{System.unique_integer([:positive])}"}}
    end

    test "a plan approved while the task was parked still opens stage 1 on promotion", %{
      project: project,
      assignee: assignee
    } do
      # LATE: the plan-approval edge — the pre-fix tree's ONLY caller of
      # `ensure_execution_stage_started/2` — fires while the task is still
      # `stack_pending`, and that function early-returns unless the task is
      # already `in_progress`. So the edge is spent before the precondition
      # is true.
      {task, [first, second]} =
        routed_task(project, "stack_pending", [{"coding", 1, "pending"}, {"review", 2, "pending"}])

      pid = start_router!(task, assignee)

      assert {:ok, _} = Tasks.transition_task(task, "in_progress")
      :ok = sync_router(task.id)
      _ = pid

      assert stage_status(first.id) == "running"
      assert stage_status(second.id) == "pending", "only the lowest-position pending stage starts"
    end

    test "a bounce with nothing left to start withholds the dispatch", %{
      project: project,
      assignee: assignee
    } do
      # The other disjunct stage 3 shipped. When the bounce leaves a task at
      # `in_progress` with NO running and NO pending stage, the dispatch is
      # withheld by the pre-existing `unresolved_stage_dispatch?/3` rather
      # than prompting an executor into a dead end — the state where a full
      # stage of work lands and `stage_complete` refuses it.
      {task, [_coding, review]} =
        routed_task(project, "in_review", [
          {"coding", 1, "passed"},
          {"Task-level review", 2, "failed"}
        ])

      handler_ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :orchestration, :dispatch_suppressed]
        ])

      on_exit(fn -> :telemetry.detach(handler_ref) end)

      _pid = start_router!(task, assignee)

      Tasks.broadcast_board({:stage_transitioned, Repo.get!(Stage, review.id)})

      # Barrier BEFORE the assertions: the router's own `init/1` dispatch
      # already suppresses for this fixture, so reading state without draining
      # the bounce first reports on the wrong event.
      :ok = sync_router(task.id)

      task_id = task.id
      assert Tasks.get_task_detail(task_id).status == "in_progress"

      assert_receive {[:platform, :orchestration, :dispatch_suppressed], ^handler_ref,
                      %{count: 1}, %{task_id: ^task_id, reason: :unresolved_stage}},
                     1_000
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Case 5 — the safety net must not measure a plan that has settled
  # ──────────────────────────────────────────────────────────────────────

  describe "case 5: the safety-net window elapses on a settled plan" do
    test "a completed plan emits no safety-net event and posts no blocker", %{project: project} do
      %{task: task, plan: plan, assignee: assignee} = safety_net_task(project)

      pid = start_router!(task, assignee)
      assert %{safety_net_at: %DateTime{}} = LeaseManager.get(task.id)

      before_blockers = blocker_count(task.id)

      # Expire the window FIRST, while the lease still exists. Doing it after
      # completion is impossible — completion clears the lease — and doing it
      # after is also the wrong order: the point is that the window was already
      # elapsed and the plan settled anyway.
      expire_safety_net!(task.id)

      # LATE: the lease was armed against a genuinely running stage. Only now
      # does the plan settle.
      {:ok, completed} = PlanEngine.advance(plan.id)
      assert completed.status == "completed"

      send(pid, :check_safety_net)
      :ok = sync_router(task.id)

      refute_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
      assert blocker_count(task.id) == before_blockers

      # MECHANISM, named rather than implied. On a COMPLETED plan the alert is
      # withheld because `complete_plan/2` clears the lease, so the handler
      # takes its nil-lease early return — NOT the settled-plan suppression
      # clause stage 4 added. That clause is what covers the case where the
      # plan settles without completing, and it is pinned by
      # `task_router_safety_net_suppression_test.exs`. Stating this here keeps
      # a reader from concluding this test exercises the suppression.
      assert LeaseManager.get(task.id) == nil
    end

    test "ANTI-VACUITY: the same task with the plan still open DOES fire", %{project: project} do
      %{task: task, assignee: assignee} = safety_net_task(project)

      pid = start_router!(task, assignee)
      before_blockers = blocker_count(task.id)

      # Differs in exactly one thing: the plan is not settled.
      expire_safety_net!(task.id)
      send(pid, :check_safety_net)
      :ok = sync_router(task.id)

      assert_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
      assert blocker_count(task.id) == before_blockers + 1
    end
  end

  # ── fixtures & helpers ────────────────────────────────────────────────

  defp landed_stamp, do: %{"sha" => "0000000", "at" => "2026-01-01T00:00:00Z"}

  defp reload(%Task{id: id}), do: Repo.get!(Task, id)
  defp status(id), do: Repo.get!(Task, id).status
  defp stage_status(id), do: Repo.get!(Stage, id).status

  defp set!(%Task{} = task, attrs) do
    task |> Task.changeset(attrs) |> Repo.update!()
  end

  defp park!(%Task{} = task), do: set!(task, %{status: "stack_pending"})

  # Drive the stack past `forming` directly. `start_stack/1` refuses any stack
  # that is not `forming` and would run the commencement cascade we are
  # deliberately arranging to have already missed.
  defp commence!(stack) do
    stack |> Ecto.Changeset.change(status: "in_progress") |> Repo.update!()
  end

  defp approve_plan!(%Task{id: id}) do
    {:ok, plan} = Tasks.create_plan(%{task_id: id, status: "approved"})
    plan
  end

  # `count` members on one stack. Every member gets an APPROVED plan by
  # default: `transition_task/2` refuses `stack_pending -> in_progress` without
  # one, so a member missing a plan would be held back by the wrong condition
  # and every anti-vacuity control below would be confounded.
  # `withhold_last_plan: true` leaves the last member unplanned so the
  # commencement gate starts closed and the approval can arrive late.
  # `depend: true` chains member N onto member N-1.
  defp stack_with_members(project, count, opts \\ []) do
    slug = "late-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Late precondition stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    members =
      Enum.reduce(1..count, [], fn i, acc ->
        deps =
          case {Keyword.get(opts, :depend, false), acc} do
            {true, [%Task{id: prev} | _]} -> [%{"task_id" => prev, "kind" => "blocks"}]
            _ -> []
          end

        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Member #{i} #{System.unique_integer([:positive])}",
            dependencies: deps
          })

        {:ok, attached} = Stacks.add_task(stack, task)

        unless Keyword.get(opts, :withhold_last_plan, false) and i == count do
          approve_plan!(attached)
        end

        [attached | acc]
      end)
      |> Enum.reverse()

    %{stack: Repo.reload!(stack), members: members}
  end

  defp routed_task(project, task_status, stage_specs) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Routed #{System.unique_integer([:positive])}",
        status: task_status,
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    stages =
      for {name, position, stage_state} <- stage_specs do
        {:ok, stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: position,
            name: name,
            status: stage_state
          })

        stage
      end

    {task, stages}
  end

  defp safety_net_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Safety net #{System.unique_integer([:positive])}",
        status: "in_progress",
        deploy_strategy: %{"type" => "none"}
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    %{
      task: task,
      plan: plan,
      stage: stage,
      assignee: %{type: :federated, id: "runtime-#{System.unique_integer([:positive])}"}
    }
  end

  defp start_router!(task, assignee) do
    Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    :ok = sync_router(task.id)

    # Stop the router before the sandbox owner exits, or its in-flight queries
    # tear down a pooled connection and spray unrelated errors over the run.
    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{router, _}] ->
          try do
            GenServer.stop(router, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      LeaseManager.clear(task.id)
    end)

    pid
  end

  defp expire_safety_net!(task_id) do
    lease = LeaseManager.get(task_id)
    assert lease, "expected an armed lease — the refutation would be vacuous without one"
    assert lease.safety_net_at, "expected an armed safety-net deadline"
    refute lease.safety_net_fired?, "expected the one-shot to be unconsumed"

    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task_id, %{lease | safety_net_at: past}})
    :ok
  end

  defp blocker_count(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      nil ->
        0

      space ->
        space.id
        |> ExecutionSpace.list_messages_with_participants()
        |> Enum.count(&String.contains?(&1.content, "Stage safety-net exceeded"))
    end
  end
end

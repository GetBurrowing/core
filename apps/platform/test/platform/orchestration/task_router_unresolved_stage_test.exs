defmodule Platform.Orchestration.TaskRouterUnresolvedStageTest do
  @moduledoc """
  Covers the unresolved-stage dispatch guard in
  `Platform.Orchestration.TaskRouter` (task 019fa469 stage 4).

  ## The defect

  Dispatches on 2026-07-27 arrived carrying an empty `stage_id` AND a label of
  `Stage 1/7` for tasks demonstrably past stage 1. Two separate fabrications of
  the same missing fact: `do_dispatch/2` computed
  `stage_pos = if stage, do: stage.position, else: 1` — inventing position 1 as
  a DEFAULT — while `dispatch_prompt/4` rendered a stage-scoped payload whose
  `stage_id` assign collapsed to `""`. Stage 2 of this task fixed the render
  half (a stage-less dispatch now resolves to `dispatch.fallback` instead of a
  stage-scoped body wrapped around an empty id). This stage fixes the other two
  halves: the label never says `1`, and the router declines to send at all when
  there is no stage the dispatch could possibly be about.

  ## WHY THE PREDICATE IS NARROWER THAN THE PLAN SPECIFIED — read this first

  The approved plan specified the predicate `phase.requires_stage? and
  is_nil(stage)`. That is too wide, and it collides head-on with a negative
  control a sibling task shipped four hours earlier.

  `task_router_dispatch_suppression_test.exs:109` ("a task whose current plan is
  approved with a PENDING zero-validation stage still dispatches") builds an
  `in_progress` task, an `approved` plan, and a single `pending` stage. That
  fixture has `requires_stage? == true` (status `in_progress` implies a
  stage-scoped phase) and `stage == nil` (nothing is `running`), so the plan's
  literal predicate suppresses it — and that test's own comment says why that is
  the worst possible outcome: *"the agent has never been prompted for stage 1
  and is the only thing that can start it. Suppressing here would park the task
  forever with no operator signal."* The dispatch IS the thing that gets an
  agent to call `stage_start`. Verified empirically, not reasoned about: with
  the literal predicate that test goes red (see the stage evidence).

  So the guard adds a third conjunct — there must also be no PENDING stage:

      phase.requires_stage? and is_nil(stage) and is_nil(first_pending_stage(plan))

  The principle it encodes is *do not send a dispatch whose subject cannot be
  named*. A pending stage is a nameable subject (the agent's job is to start
  it). No stage at all, in a status that claims a stage-scoped phase, means
  every stage-shaped field in the prompt would be invented — which is exactly
  the incident.

  ## What this file does NOT claim

  The incident has two variants and the two halves of this stage cover one each,
  which is worth saying out loud rather than implying the guard covers both:

    * plan EXHAUSTED (every stage settled, plan row still `approved`) or absent
      entirely — the suppression guard fires.
    * next stage still `pending` — the guard deliberately declines, and only the
      label is fixed (`Stage: -/2`, never `Stage: 1/2`). Auto-starting such a
      stage from the dispatch path would be a much larger blast radius and is
      not attempted here.

  So a reader should not read "suppression" as covering every `Stage 1/N` line
  the operator saw; it covers the ones with nothing left to point at.

  ## Anti-vacuity

  A test asserting "no dispatch was sent" passes trivially when nothing would
  have been sent anyway, so a dead guard and a working guard are
  indistinguishable from the suppression assertion alone. Every suppression
  assertion here is therefore PAIRED with the counterfactual: the same fixture
  builder, one field different (the stage is `running` instead of settled),
  asserting the dispatch DOES fire. The pair is what discriminates.

  The label assertions are paired the same way: `refute log =~ "Stage: 1/2"` is
  worthless on its own (an empty log satisfies it), so each is paired with a
  positive `assert log =~ "Stage: -/2"` on the same string.

  ## Boundary with task 019fa2fc

  That task owns the `plan.status == "completed"` predicate and owns
  `task_router_dispatch_suppression_test.exs` outright. This is a DIFFERENT
  predicate in a NEW file; neither its test file nor its predicate is touched.
  The suppression TELEMETRY event is deliberately shared — `reason` distinguishes
  them (`:unresolved_stage` vs `:completed_plan_no_work`), and a second event
  name would have split the dashboards.

  Evidence is the actual `runtime:<id>` broadcast, not a log line
  (`config/test.exs` runs the logger at `level: :warning`, so a `Logger.info`
  assertion is silently vacuous). No `Process.sleep`: the barrier is
  `TaskRouter.current_status/1`, a plain `GenServer.call` that cannot be
  answered until the router's mailbox drains.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks

  @suppressed_event [:platform, :orchestration, :dispatch_suppressed]

  setup do
    # Routers are separate processes that hit the repo.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Unresolved Stage Project",
        repo_url: "https://github.com/test/unresolved-stage"
      })

    %{project: project}
  end

  describe "unresolved-stage suppression" do
    test "suppresses dispatch for an in_progress task whose plan holds no running and no pending stage",
         %{project: project} do
      %{task: task} = fixture = exhausted_plan_task(project, :settled)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      assert_received {:dispatch_suppressed, %{task_id: task_id, reason: reason}}
      assert task_id == task.id
      assert reason == :unresolved_stage

      # The point of the guard: no fabricated stage payload reached the runtime.
      refute_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "COUNTERFACTUAL — the same fixture with the last stage RUNNING dispatches", %{
      project: project
    } do
      # This is the test that makes the one above mean something. Identical
      # builder, identical task status, identical plan status, identical stage
      # rows — the ONLY difference is that stage 2 is `running` rather than
      # `passed`. If the guard were dead code (or if this shape were unreachable
      # for some unrelated reason) this test and the previous one would both
      # pass while asserting nothing.
      %{task: task} = fixture = exhausted_plan_task(project, :running)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "suppresses dispatch for an in_progress task with no plan row at all", %{
      project: project
    } do
      # The other reachable shape, and the one that produced the most absurd
      # label of the lot: `stage_count` is 0 and the old default made the line
      # read `Stage: 1/0`. Nothing to name at all.
      %{task: task} = fixture = planless_in_progress_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      assert_received {:dispatch_suppressed, %{reason: :unresolved_stage}}
      refute_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "COUNTERFACTUAL — the same planless task at `planning` dispatches", %{project: project} do
      # Identical in every respect (no plan, no stage) except `task.status`.
      # This is what proves the guard keys on the phase and not merely on the
      # absence of a plan — and it is the same discrimination the mandated
      # planning negative control makes, stated against the planless fixture so
      # the pair differs in exactly one field.
      %{task: task} = fixture = planning_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      # `assert_receive`, not `assert_received`, and the change is behavioural
      # rather than cosmetic. Task 019fe1b7 stage 2 moved the pre-plan design
      # step onto the lifecycle pipeline, which runs in a SPAWNED process: a
      # planning task with no plan is held for as long as its designer edge
      # takes to answer (`not_applicable` on a fixture with no designer wired),
      # and only then dispatches. The claim under test — that this guard does
      # not suppress a planning dispatch — is unchanged; what is no longer true
      # is that the dispatch lands inside the router's own tick.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 5_000
    end

    test "suppression leaves the router status untouched so the next tick re-derives", %{
      project: project
    } do
      %{task: task} = fixture = exhausted_plan_task(project, :settled)
      %{pid: pid} = start_router!(fixture)

      before = TaskRouter.current_status(task.id)

      # `:dispatch_now`, not `:dispatch`: the debounced form arms a 50ms timer
      # the barrier does not wait for, so how many suppressions had actually
      # occurred by the assertion was a race. Driven directly, this is exactly
      # ONE more suppression than `init/1` produced.
      send(pid, :dispatch_now)
      after_suppression = barrier(task)

      # A suppressed dispatch is not a dispatch: it must not advance the
      # last-dispatch clock, or the stall detector would read the silence as
      # activity.
      assert after_suppression.last_dispatch_at == before.last_dispatch_at

      # The status claim this test used to make (`== before.status`) moved to
      # the escalation test below. Task 01a006e7 stage 2 made a RUN of
      # suppressions raise a `needs_human` blocker, and `init/1` has already
      # contributed one by the time a test can observe anything — so "the
      # status never moves" is no longer true of the second tick, by design.
    end

    # Task 01a006e7 stage 2. The status claim above is about the SUPPRESSION.
    # The ESCALATION is a different event and does move the router: a
    # `needs_human` blocker upserts the task's execution lease to `blocked`,
    # and a blocked lease parks the router at `:waiting_human` — the same
    # thing any other blocker does, and the point of raising one. Pinned here
    # so a future reader does not "restore" the untouched-status claim across
    # the escalation and silently disarm the guard.
    test "the escalation on a later suppression parks the router at :waiting_human", %{
      project: project
    } do
      %{task: task} = fixture = exhausted_plan_task(project, :settled)
      %{pid: pid} = start_router!(fixture)

      send(pid, :dispatch_now)
      barrier(task)
      send(pid, :dispatch_now)
      after_escalation = barrier(task)

      assert after_escalation.status == :waiting_human
    end
  end

  describe "negative controls — the guard must not strangle live work" do
    test "a planning task with no plan and no stage still dispatches", %{project: project} do
      # Mandated negative control (b). `dispatch.planning` resolves with
      # `requires_stage?: false` precisely so this guard cannot reach it: a
      # planning dispatch has no running stage BY DESIGN, and suppressing it
      # would mean no task ever gets a plan again.
      %{task: task} = fixture = planning_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      # `assert_receive`, not `assert_received`, and the change is behavioural
      # rather than cosmetic. Task 019fe1b7 stage 2 moved the pre-plan design
      # step onto the lifecycle pipeline, which runs in a SPAWNED process: a
      # planning task with no plan is held for as long as its designer edge
      # takes to answer (`not_applicable` on a fixture with no designer wired),
      # and only then dispatches. The claim under test — that this guard does
      # not suppress a planning dispatch — is unchanged; what is no longer true
      # is that the dispatch lands inside the router's own tick.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 5_000
    end

    test "an in_progress task whose next stage is PENDING still dispatches", %{project: project} do
      # THE COLLISION the plan's literal predicate would have caused. Same shape
      # as `task_router_dispatch_suppression_test.exs:109`, restated here so the
      # boundary is defended from inside this stage's own file rather than
      # depending on a sibling task's file staying put.
      #
      # `requires_stage?` is true and `stage` is nil, so the plan's two-conjunct
      # predicate matches exactly. The third conjunct is what saves it.
      %{task: task, plan: plan} = fixture = pending_next_stage_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      # Pin the premise, so this test cannot pass because the fixture drifted
      # into some other shape.
      stages = Tasks.get_plan(plan.id).stages
      refute Enum.any?(stages, &(&1.status == "running"))
      assert Enum.any?(stages, &(&1.status == "pending"))

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end
  end

  describe "the Stage label no longer fabricates position 1" do
    test "reports `-` when no stage resolved", %{project: project} do
      # `stage_pos = if stage, do: stage.position, else: 1` rendered this exact
      # fixture as `Stage: 1/2` — the string an operator saw all day on tasks
      # that were nowhere near stage 1.
      %{task: task} = fixture = pending_next_stage_task(project)
      %{pid: pid} = start_router!(fixture)

      send(pid, :dispatch)
      barrier(task)

      log = task_assigned_log!(task)

      assert log =~ "Stage: -/2"
      refute log =~ "Stage: 1/2"
    end

    test "COUNTERFACTUAL — reports the real position when a stage IS running", %{project: project} do
      # Without this, `-` could be hardcoded and the test above would still
      # pass. Stage 2 is `running` here, so the label must read `2/2` — which is
      # also the one value the old fabrication could never produce for a
      # stage-less dispatch.
      %{task: task} = fixture = exhausted_plan_task(project, :running)
      %{pid: pid} = start_router!(fixture)

      send(pid, :dispatch)
      barrier(task)

      log = task_assigned_log!(task)

      assert log =~ "Stage: 2/2"
      refute log =~ "Stage: -/2"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # An `in_progress` task with an `approved` two-stage plan in which BOTH stages
  # are settled: nothing `running`, nothing `pending`, and the plan row was
  # never flipped to `completed` (so 019fa2fc's guard declines and control
  # genuinely reaches this stage's predicate).
  #
  # `mode: :running` is the counterfactual: identical rows except stage 2 is
  # left `running`.
  defp exhausted_plan_task(project, mode) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unresolved stage #{mode}",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, first} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, first} = Tasks.transition_stage(first, "running")
    {:ok, _first} = Tasks.transition_stage(first, "passed")

    {:ok, second} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Ship"})
    {:ok, second} = Tasks.transition_stage(second, "running")

    second =
      case mode do
        :running ->
          second

        :settled ->
          {:ok, settled} = Tasks.transition_stage(second, "passed")
          settled
      end

    %{task: task, plan: plan, stage: second}
  end

  # An `in_progress` task whose stage 1 is done and whose stage 2 is still
  # `pending` — nothing running, but a nameable subject exists. The shape the
  # plan's literal predicate would have strangled.
  defp pending_next_stage_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unresolved stage pending next",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, first} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, first} = Tasks.transition_stage(first, "running")
    {:ok, _first} = Tasks.transition_stage(first, "passed")

    {:ok, second} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Ship"})
    assert second.status == "pending"

    %{task: task, plan: plan, stage: second}
  end

  # An `in_progress` task with no plan row whatsoever.
  defp planless_in_progress_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unresolved stage planless",
        status: "in_progress"
      })

    assert Tasks.current_plan(task.id) == nil

    %{task: task, plan: nil, stage: nil}
  end

  # A fresh task in `planning` with no plan at all.
  defp planning_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unresolved stage planning",
        status: "planning"
      })

    assert Tasks.current_plan(task.id) == nil

    %{task: task, plan: nil, stage: nil}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp start_router!(%{task: task}) do
    runtime_id = "runtime-test-#{System.unique_integer([:positive])}"
    assignee = %{type: :federated, id: runtime_id}
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{p, _}] ->
          try do
            GenServer.stop(p, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    # `init/1` schedules a boot dispatch; drain it so assertions observe the
    # dispatch WE inject rather than boot noise.
    barrier(task)

    %{pid: pid, runtime_id: runtime_id}
  end

  defp watch_dispatches!(runtime_id) do
    handler_id = "unresolved-stage-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @suppressed_event,
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:dispatch_suppressed, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")
    on_exit(fn -> PlatformWeb.Endpoint.unsubscribe("runtime:#{runtime_id}") end)

    :ok
  end

  # The `Task assigned: … | Stage: …` line the router posts to the execution
  # space. Fails loudly when absent rather than returning "" — a nil-tolerant
  # accessor here would make every `refute log =~ …` below vacuous, which is the
  # exact smell stage 3 of this task found at `heartbeat_scheduler_test.exs:918`.
  defp task_assigned_log!(task) do
    space = ExecutionSpace.find_by_task_id(task.id)
    assert space, "expected an execution space for task #{task.id}"

    lines =
      space.id
      |> Chat.list_messages(limit: 100)
      |> Enum.map(& &1.content)
      |> Enum.filter(&String.starts_with?(&1, "Task assigned:"))

    assert lines != [], "expected at least one `Task assigned:` log line in the execution space"

    Enum.join(lines, "\n")
  end

  # A complete mailbox barrier: `current_status/1` is a `GenServer.call`, so it
  # is answered only after every message queued ahead of it is handled.
  # Task 01a00587: `:dispatch` only ARMS a ~50ms `:dispatch_now`, so a bare
  # `current_status/1` call is answered before the reconcile runs and every
  # assertion after it would observe pre-dispatch state (a suppression refute
  # would go vacuously green). `sync_router/2` makes the same call and then
  # waits on `state.dispatch_timer` returning to `nil` — the observable for
  # "no reconcile is still owed" — so the barrier means what it did before.
  defp barrier(task) do
    :ok = sync_router(task.id)
    TaskRouter.current_status(task.id)
  end
end

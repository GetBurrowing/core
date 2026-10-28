defmodule Platform.Orchestration.TaskRouterStagelessDispatchTraceTest do
  @moduledoc """
  Task 01a0a5fa stage 1 — a dispatch that resolves NO stage must leave a
  durable, MCP-readable trace.

  Before this stage the only trace was the `ExecutionSpace.post_engagement/3`
  row written in `do_dispatch_resolved/6`. That row is a chat message in the
  execution space: `runtime_event_list` does not return it, which is why the
  2026-09-15 instance on task 01a09de9 had to be dug out of the gateway journal
  rather than read off the MCP surface.

  ## Anti-vacuity

  A test that asserts only "no execution_lease row was created" or "no timer was
  armed" is VACUOUS here — that is today's behaviour on `main` and it is the
  thing the ticket is questioning, not the thing it is fixing. So every test in
  this file leads with a POSITIVE assertion about the trace: the
  `execution.dispatch_stageless` runtime_event exists, and its payload carries
  the fields a later reader needs. `LeaseManager.get(task.id) == nil` appears
  only as a COMPANION to a positive assertion, never as a whole test — it pins
  that the recording did not accidentally start minting leases.

  NOT tested here, and deliberately so: the "task with no execution space" case.
  `TaskRouter.init/1` calls `ExecutionSpace.find_or_create/1` and only leaves
  `execution_space_id` nil when that call ERRORS, which no fixture can provoke
  under test. The emit is placed outside the `if state.execution_space_id`
  block for that case regardless — that placement is a code-review fact, and
  writing a test whose premise ("this task has no execution space") is false
  would be worse than not writing one.

  The counterfactual is the second describe block: a dispatch that DOES resolve
  a stage must emit no such event. Without it, an implementation that emitted
  the event unconditionally would pass every assertion in the first block.

  ## Stage 2 — the unanswered watchdog

  Stage 2 adds a task-level watchdog over the same no-stage dispatch: when
  nothing comes back inside `@stageless_watchdog_ms`, ONE
  `execution.dispatch_unanswered` event is recorded. The window is overridden
  in tests through `Application.put_env(:platform,
  :task_router_stageless_watchdog_ms, _)` — the Application-env shape the
  file's neighbours already use for `:task_router_dispatch_debounce_ms` and
  `:task_router_awaiting_human_reminder_ms`, rather than a new mechanism.

  Order is load-bearing here. The POSITIVE case (a real timer, a real fire)
  comes first; the suppression cases come after. A suppression test that never
  saw the event fire proves nothing — it would pass identically against an
  implementation that emits the event nowhere at all.

  Harness (barrier, router startup, runtime subscription) mirrors
  `task_router_dispatch_suppression_test.exs`. `sync_router/2` +
  `TaskRouter.current_status/1` is a complete mailbox barrier and is used for
  everything except the one test that must observe a REAL `send_after` timer
  land, which polls (`await_event/2`) rather than sleeping a fixed duration.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Orchestration.RuntimeSupervision
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Stageless Trace Project",
        repo_url: "https://github.com/test/stageless-trace"
      })

    %{project: project}
  end

  describe "a dispatch that resolves no stage records execution.dispatch_stageless" do
    test "the event is persisted for the task, and no lease row is minted alongside it", %{
      project: project
    } do
      %{task: task} = fixture = planning_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      # The boot dispatch alone is not reliable for a `planning` task, so drive
      # one explicitly and drain it. The subscription was taken before boot, so
      # a boot frame counts too — either way at least one frame must be observed
      # before any assertion below means anything.
      send(pid, :dispatch)
      barrier(task)

      # POSITIVE FIRST. The frame really went out...
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"},
                     1_000,
                     "the dispatch must actually have been sent — otherwise every " <>
                       "assertion below is about a dispatch that never happened"

      # ...and it left a row on the runtime_event table, which is what
      # `runtime_event_list` reads.
      events = stageless_events(task.id)

      assert length(events) >= 1,
             "a dispatch resolving no stage must persist an execution.dispatch_stageless event"

      event = hd(events)

      assert event.event_type == "execution.dispatch_stageless"
      assert event.runtime_id == RuntimeSupervision.self_filed_runtime_id()
      assert event.phase == "planning"

      assert event.payload["stage_id"] == nil,
             "the payload must say explicitly that no stage resolved"

      assert event.payload["task_status"] == "planning"
      assert event.payload["dispatch_runtime_id"] == runtime_id
      assert is_boolean(event.payload["delivered_online"])
      assert event.payload["reported_by"] == "task_router"

      assert event.payload["description"] =~ task.id,
             "the description must name the task it is about"

      assert event.payload["description"] =~ "resolved NO stage",
             "the description must say what happened, not just that something happened"

      # COMPANION, never the whole test: recording the send must not have
      # started minting a lease keyed to a stage that does not exist.
      assert LeaseManager.get(task.id) == nil,
             "the stageless event is registered with a nil status precisely so it " <>
               "inserts no execution_lease row"

      assert Repo.aggregate(
               from(l in Platform.Orchestration.ExecutionLease, where: l.task_id == ^task.id),
               :count
             ) == 0
    end
  end

  describe "counterfactual — a dispatch that DOES resolve a stage emits no such event" do
    test "a running-stage dispatch leaves no execution.dispatch_stageless row", %{
      project: project
    } do
      # Without this, an implementation that emitted the event on EVERY dispatch
      # would satisfy every assertion in the block above. The event's meaning is
      # "no stage resolved"; if it fires on stage-bearing dispatches too it
      # carries no information.
      %{task: task} = fixture = running_stage_task(project)
      %{runtime_id: _runtime_id} = start_router!(fixture)

      assert_received %Phoenix.Socket.Broadcast{event: "attention"},
                      "the stage-bearing dispatch must have been sent, or the refute below is vacuous"

      assert stageless_events(task.id) == [],
             "a dispatch that resolved a stage must not be recorded as stageless"
    end
  end

  describe "stage 2 — an unanswered stageless dispatch records execution.dispatch_unanswered" do
    test "the armed timer fires and persists the event, without blocking the task", %{
      project: project
    } do
      # POSITIVE, and deliberately FIRST. This is the only test in the block
      # that exercises the real `Process.send_after/3` arm — the suppression
      # tests below drive the handler directly, and they only mean something
      # because this one shows the timer genuinely lands.
      put_watchdog_ms(25)

      %{task: task} = fixture = planning_task(project)
      %{runtime_id: runtime_id} = start_router!(fixture)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"},
                     1_000,
                     "the dispatch must have been sent, or there is nothing to be unanswered"

      event =
        await_event(task.id, "execution.dispatch_unanswered") ||
          flunk("the watchdog never fired: no execution.dispatch_unanswered event was persisted")

      assert event.payload["stage_id"] == nil
      assert event.payload["task_status"] == "planning"
      assert event.payload["dispatch_runtime_id"] == runtime_id
      assert is_integer(event.payload["elapsed_ms"])
      assert {:ok, _, _} = DateTime.from_iso8601(event.payload["dispatched_at"])
      assert event.payload["reported_by"] == "task_router"
      assert event.payload["description"] =~ task.id

      # COMPANIONS. This is an observability floor: it records, it does not
      # alarm. None of the three below is the whole test.
      assert LeaseManager.get(task.id) == nil,
             "the watchdog must mint no lease for a stage that does not exist"

      status = TaskRouter.current_status(task.id)

      assert status.status != :stalled,
             "recording an unanswered dispatch must not stall the router"

      assert Tasks.get_task_detail(task.id).status == "planning",
             "the task must not be blocked or otherwise moved by the watchdog"

      assert blocker_events(task.id) == [],
             "no needs_human blocker may be filed by an observability floor"

      # Fired exactly once, and `stageless_dispatch_at` is cleared so a second
      # fire is structurally impossible rather than merely guarded.
      assert TaskRouter.current_status(task.id).stageless_dispatch_at == nil
    end

    test "a runtime event arriving inside the window suppresses the watchdog", %{project: project} do
      # The false-alarm regression. A watchdog that fires on an ANSWERED
      # dispatch trains readers to ignore it.
      put_watchdog_ms(60_000)

      %{task: task} = fixture = planning_task(project)
      %{pid: pid, runtime_id: owner} = start_router!(fixture)

      # The boot dispatch is not reliable for a `planning` task (same reason the
      # stage 1 test drives one explicitly), and the debounce means the frame
      # has not gone out by the time the barrier returns — so drive one and wait
      # for the arm rather than reading the token off a dispatch that has not
      # happened yet.
      send(pid, :dispatch)

      token =
        await_token(task, 1) ||
          flunk(
            "ANTI-VACUITY: the watchdog was never armed, so the refute below would be " <>
              "about a timer that never existed"
          )

      # Something came back for this task.
      send(pid, {:runtime_event, %{heartbeat_event(task.id) | runtime_id: owner}})
      barrier(task)

      # Now let the timer land.
      send(pid, {:check_stageless_dispatch, token})
      barrier(task)

      assert unanswered_events(task.id) == [],
             "a dispatch answered inside the window must leave no unanswered trace"
    end

    test "an orphaned timer from an earlier dispatch cannot double-fire", %{project: project} do
      put_watchdog_ms(60_000)

      %{task: task} = fixture = planning_task(project)
      %{pid: pid} = start_router!(fixture)

      send(pid, :dispatch)
      first_token = await_token(task, 1) || flunk("the first stageless dispatch never armed")

      # A second stageless dispatch supersedes the first and bumps the token.
      send(pid, :dispatch)

      second_token =
        await_token(task, first_token + 1) ||
          flunk(
            "ANTI-VACUITY: the second dispatch never re-armed the watchdog (token stuck at " <>
              "#{first_token}), so the orphan case below would not be exercised at all"
          )

      assert second_token == first_token + 1

      # The FIRST dispatch's timer still fires — nothing cancels it. It must be
      # dropped on the token mismatch.
      send(pid, {:check_stageless_dispatch, first_token})
      barrier(task)

      assert unanswered_events(task.id) == [],
             "an orphaned timer from a superseded dispatch must not fire"

      # The live token does fire, exactly once...
      send(pid, {:check_stageless_dispatch, second_token})
      barrier(task)

      assert length(unanswered_events(task.id)) == 1

      # ...and a repeat of the same token cannot fire again.
      send(pid, {:check_stageless_dispatch, second_token})
      barrier(task)

      assert length(unanswered_events(task.id)) == 1,
             "no re-arm, no repeat: one unanswered event per dispatch token"
    end
  end

  describe "task 01a0b5ce — the unanswered description states only what the watchdog measured" do
    # The watchdog's fire-time checks are: token, already-fired,
    # `state.current_stage_id`, `last_runtime_event_at`, and membership of the
    # live task status in the answer-expected set. It reads no plan row. The
    # old description claimed "nothing has come back ... no status change" and
    # "was dispatched at <status>" — none of which those checks measure. These
    # tests pin the rendered text against the case that exposed it: a plan that
    # WAS submitted (so something did come back) while the watchdog fires anyway.

    test "(A) a submitted, unapproved plan: the event fires and the text claims nothing it did not read",
         %{project: project} do
      # Wide enough to build and submit a plan before the timer lands, short
      # enough that `await_event/3` below sees the real `send_after` fire.
      put_watchdog_ms(1_500)

      %{task: task} = fixture = planning_task(project)
      %{pid: pid} = start_router!(fixture)

      # The stage-less dispatch must be RECORDED (watchdog armed) before the
      # plan is submitted. The boot dispatch is still inside its debounce when
      # `start_router!/1` returns, and a submit that lands first moves the
      # router to `:waiting_human` with no stage-less dispatch ever sent — a
      # run measured on test-host at token 0 throughout. So drive one and wait for
      # the arm, as the suppression tests above do.
      send(pid, :dispatch)

      await_token(task, 1) ||
        flunk(
          "ANTI-VACUITY: the watchdog was never armed, so there is no stage-less " <>
            "dispatch for the submitted plan to follow"
        )

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      assert plan.status == "draft"

      for position <- 1..2 do
        {:ok, _stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: position,
            name: "Authored stage #{position}"
          })
      end

      assert {:ok, %{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)

      # The plan work finished BEFORE the watchdog fired — otherwise this is the
      # no-plan case under another name.
      assert unanswered_events(task.id) == [],
             "the watchdog fired before the plan was submitted; the test did not exercise " <>
               "the submitted-plan case"

      event =
        await_event(task.id, "execution.dispatch_unanswered", 250) ||
          flunk(
            "FINDING: with a submitted pending_review plan the watchdog stayed silent — " <>
              "no execution.dispatch_unanswered event was persisted"
          )

      description = event.payload["description"]

      refute description =~ "nothing has come back",
             "clause 'nothing has come back' is false here: a plan with 2 stages was " <>
               "submitted, and the check never reads plans"

      refute description =~ "no status change",
             "clause 'no status change' is unmeasured: the check only tests membership " <>
               "in the answer-expected status set"

      refute description =~ "dispatched at",
             "clause 'dispatched at <status>' is false: the status is re-read when the " <>
               "watchdog fires, not taken from dispatch time"

      assert description =~ "tracks no running stage"
      assert description =~ "is now at planning"
      assert description =~ task.id
    end

    test "(B) no plan: the event fires and names the runtime-event measurement", %{
      project: project
    } do
      put_watchdog_ms(25)

      %{task: task} = fixture = planning_task(project)
      %{runtime_id: _runtime_id} = start_router!(fixture)

      event =
        await_event(task.id, "execution.dispatch_unanswered") ||
          flunk("the watchdog never fired: no execution.dispatch_unanswered event was persisted")

      description = event.payload["description"]

      assert description =~ "no runtime event"
      assert description =~ task.id
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # A task at `planning` with NO plan: no plan means no stage can resolve, which
  # is the production shape (`dispatch.planning`) this stage is about.
  defp planning_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Stageless dispatch trace probe",
        status: "planning"
      })

    assert Tasks.current_phase(task) == "planning"

    %{task: task}
  end

  defp running_stage_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Stage-bearing dispatch probe",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")

    %{task: task, stage: stage}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp stageless_events(task_id) do
    Repo.all(
      from(e in RuntimeEvent,
        where: e.task_id == ^task_id and e.event_type == "execution.dispatch_stageless",
        order_by: [asc: e.inserted_at]
      )
    )
  end

  # Subscribes to the runtime topic BEFORE the router boots, so the dispatch
  # under test is the BOOT dispatch itself. An injected second `:dispatch` is
  # not equivalent: the router debounces / suppresses a repeat whose engagement
  # is unchanged, so the second frame is not reliably sent and an assertion on
  # it is flaky (observed on the test-host rig: green on one run, "no attention
  # broadcast" on the next).
  defp start_router!(%{task: task}) do
    runtime_id = "runtime-stageless-#{System.unique_integer([:positive])}"
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")
    on_exit(fn -> PlatformWeb.Endpoint.unsubscribe("runtime:#{runtime_id}") end)

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

    # `init/1` schedules the boot dispatch; the barrier drains it, so every
    # assertion after this call observes a dispatch that has already completed.
    barrier(task)

    %{pid: pid, runtime_id: runtime_id}
  end

  defp unanswered_events(task_id) do
    Repo.all(
      from(e in RuntimeEvent,
        where: e.task_id == ^task_id and e.event_type == "execution.dispatch_unanswered",
        order_by: [asc: e.inserted_at]
      )
    )
  end

  defp blocker_events(task_id) do
    Repo.all(
      from(e in RuntimeEvent,
        where: e.task_id == ^task_id and e.event_type == "execution.blocked"
      )
    )
  end

  defp put_watchdog_ms(ms) do
    previous = Application.get_env(:platform, :task_router_stageless_watchdog_ms)
    Application.put_env(:platform, :task_router_stageless_watchdog_ms, ms)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :task_router_stageless_watchdog_ms)
        value -> Application.put_env(:platform, :task_router_stageless_watchdog_ms, value)
      end
    end)
  end

  # Polls rather than sleeping a fixed duration: the assertion is "the timer
  # landed", and a fixed sleep either flakes or wastes the difference.
  defp await_event(task_id, event_type, attempts \\ 100) do
    query =
      from(e in RuntimeEvent,
        where: e.task_id == ^task_id and e.event_type == ^event_type,
        order_by: [asc: e.inserted_at]
      )

    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case Repo.all(query) do
        [event | _] ->
          {:halt, event}

        [] ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)
  end

  defp heartbeat_event(task_id) do
    %RuntimeEvent{
      task_id: task_id,
      event_type: "execution.heartbeat",
      occurred_at: DateTime.utc_now(),
      payload: %{},
      lease: nil
    }
  end

  # Polls `current_status/1` until the watchdog has been armed at least
  # `expected` times. The dispatch debounce means the frame has not gone out
  # when the mailbox barrier returns, so a direct read races it.
  defp await_token(task, expected, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case TaskRouter.current_status(task.id) do
        %{stageless_dispatch_token: token} when token >= expected ->
          {:halt, token}

        _ ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)
  end

  defp barrier(task) do
    :ok = sync_router(task.id)
    TaskRouter.current_status(task.id)
  end
end

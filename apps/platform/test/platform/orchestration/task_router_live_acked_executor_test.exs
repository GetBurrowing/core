defmodule Platform.Orchestration.TaskRouterLiveAckedExecutorTest do
  @moduledoc """
  Tasks `01a04135` and `01a00915`: a stage that already has an executor working
  it must not be dispatched again.

  ## Why the assertions are PAIRED

  "No second dispatch arrived" passes for a great many reasons that have
  nothing to do with the guard — a fixture that never dispatched at all, a
  router that failed to boot, a stage the dispatcher declined to resolve, a
  runtime topic nobody was subscribed to. Every refutation below is therefore
  bracketed by a positive assertion on the SAME fixture: the first dispatch is
  observed before the second one is refuted, and the withheld dispatch is shown
  to arrive once the single condition under test is removed.

  ## What must NOT be asserted here

  Not "only one executor ran", and not a count of dispatches over a window.
  The first depends on the RECIPIENT behaving carefully, which is the exact
  thing these tickets say we must stop relying on. The second passes the moment
  timing shifts and then regresses in silence. The load-bearing claim is that
  the dispatch is not SENT — so these tests read the broadcast on the runtime
  topic, which is what actually wakes an agent.

  Shared-mode sandbox throughout: the router is a real GenServer reading the
  Repo from its own process.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  @suppressed_event [:platform, :orchestration, :dispatch_suppressed]

  # 90 minutes is `coding`'s `safety_net_ms` in `LeaseManager.stage_kind_timeouts/0`.
  # Read from the module rather than hardcoded so a retune of that matrix moves
  # these tests with it instead of silently making them assert the old contract.
  defp coding_safety_net_ms do
    LeaseManager.stage_kind_timeouts()
    |> Map.fetch!("coding")
    |> Map.fetch!(:safety_net_ms)
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Live Acked Executor Project #{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Live acked executor #{n}",
        description: "Pin the acked-stage dispatch suppression contract",
        status: "in_progress",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    # "Build the feature" infers `stage_kind: "coding"`, which is what gives the
    # stage a non-nil `safety_net_ms` and therefore a suppression window at all.
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build the feature",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    # A pending non-manual gate keeps `no_unmet_gate_dispatch?/3` from
    # suppressing for an unrelated reason — without it a refutation here could
    # pass on the wrong mechanism entirely.
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-live-ack-#{n}"}

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{assignee.id}")

    handler_id = "live-acked-executor-#{n}"
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

    on_exit(fn ->
      :telemetry.detach(handler_id)
      PlatformWeb.Endpoint.unsubscribe("runtime:#{assignee.id}")
      stop_router(task.id)

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{
      project: project,
      task: task,
      plan: plan,
      stage: stage,
      validation: validation,
      assignee: assignee
    }
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp start_router(task_id, assignee) do
    {:ok, pid} = TaskRouter.start_link(task_id: task_id, assignee: assignee)
    :ok = sync_router(task_id)
    pid
  end

  defp stop_router(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  # ANTI-VACUITY GATE. Every refutation in this file is only meaningful if a
  # dispatch demonstrably reaches this runtime in the first place. This asserts
  # that and hands back the prompt, so a fixture that silently stopped
  # dispatching fails loudly here instead of making the next `refute_receive`
  # pass for free.
  defp assert_dispatched!(context \\ "expected a dispatch on the runtime topic") do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "attention",
                     payload: %{message: %{content: prompt}}
                   },
                   2_000,
                   context

    assert String.length(prompt) > 200,
           "a dispatch prompt this short is not a real stage dispatch — the " <>
             "refutations that follow would be testing nothing"

    prompt
  end

  defp refute_dispatched!(context) do
    refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_500, context
  end

  # The REAL ack path: writes the durable `runtime_events` row, lands on the
  # lease, and broadcasts — the same call an executor makes as its first tool
  # call. Asserting on both stores here means a later refutation cannot pass
  # because the ack quietly failed to record.
  defp ack!(task, stage, assignee) do
    {:ok, _envelope} =
      ToolSurface.execute(
        "task_ack",
        %{
          "task_id" => task.id,
          "stage_id" => stage.id,
          "subagent_id" => "subagent-live-ack-#{System.unique_integer([:positive])}"
        },
        # Task 01a0c762 stage 2: ack as the DISPATCHED runtime. The router's
        # durable-ack readers now count only the lease owner's rows; an empty
        # context wrote `runtime_id: "tool-surface"`, which no owner matches.
        %{runtime_id: assignee.id}
      )

    :ok = sync_router(task.id)

    assert Orchestration.stage_acked?(task.id, stage.id),
           "the ack path must leave a durable per-stage row, or the guard has " <>
             "nothing to read and this test proves nothing"

    assert %DateTime{} = Orchestration.last_stage_ack_at(task.id, stage.id)

    :ok
  end

  # Ages the durable ack so it falls outside the stage kind's safety net. This
  # is the ONLY condition varied between the withheld case and the dispatched
  # case in the paired test — move two and neither probe proves anything.
  defp age_ack!(task_id, stage_id, ms_ago) do
    event =
      Repo.one!(
        from(e in RuntimeEvent,
          where:
            e.task_id == ^task_id and e.event_type == "execution.acked" and
              fragment("?->>'stage_id' = ?", e.payload, ^stage_id),
          order_by: [desc: e.occurred_at, desc: e.id],
          limit: 1
        )
      )

    aged = DateTime.add(DateTime.utc_now(), -ms_ago, :millisecond)

    event
    |> Ecto.Changeset.change(%{occurred_at: aged})
    |> Repo.update!()

    assert DateTime.compare(Orchestration.last_stage_ack_at(task_id, stage_id), aged) == :eq,
           "the lookup must see the aged timestamp, or the second half of the " <>
             "pair is varying nothing"

    :ok
  end

  # ── The pair ───────────────────────────────────────────────────────────────

  describe "a restarted router and a stage with a live acked executor" do
    test "the acked stage is withheld on restart, and dispatches again once the ack ages out",
         %{task: task, stage: stage, assignee: assignee} do
      # 1. First dispatch — the executor is staffed.
      start_router(task.id, assignee)
      assert_dispatched!("the fixture must dispatch once before anything can be withheld")

      ack!(task, stage, assignee)

      # 2. The reported incident: the router stops and a NEW process boots.
      #    `terminate/2` clears the ETS lease on the way out, so the restarted
      #    router has no in-memory deadline — only the durable ack can save it.
      stop_router(task.id)

      assert is_nil(LeaseManager.get(task.id)),
             "terminate/2 is expected to clear the lease; if it stopped doing " <>
               "so this test is no longer exercising the restart shape"

      start_router(task.id, assignee)

      refute_dispatched!(
        "a stage acked minutes ago, inside its safety net, must not be " <>
          "re-dispatched by a restarted router"
      )

      assert_receive {:dispatch_suppressed,
                      %{task_id: suppressed_id, reason: :live_acked_executor}},
                     2_000

      assert suppressed_id == task.id

      # 3. Vary ONE condition: the ack is now older than `coding`'s safety net.
      #    The executor is presumed dead and the stage must be re-dispatched —
      #    this is what makes the guard self-healing rather than a stall.
      stop_router(task.id)
      age_ack!(task.id, stage.id, coding_safety_net_ms() + 60_000)
      start_router(task.id, assignee)

      assert_dispatched!(
        "once the ack falls outside the safety net the stage must be " <>
          "re-dispatched, or this guard strands tasks forever"
      )
    end
  end

  describe "an event-driven redispatch of an acked stage" do
    # The cheaper repro from task 01a04135: a deploy stage whose work is done
    # and which is idle waiting on external CI got re-dispatched three times in
    # four minutes. No restart is involved.
    test "is withheld", %{task: task, stage: stage, assignee: assignee} do
      pid = start_router(task.id, assignee)
      assert_dispatched!("the fixture must dispatch once before anything can be withheld")

      ack!(task, stage, assignee)

      send(pid, :dispatch)
      :ok = sync_router(task.id)

      refute_dispatched!("an acked, live stage must not be re-dispatched by a reconcile either")

      assert_receive {:dispatch_suppressed, %{reason: :live_acked_executor}}, 2_000
    end
  end

  # Each test below removes exactly one conjunct and asserts the dispatch goes
  # out. Together they are what stops the guard degenerating into "never
  # dispatch anything twice", which would pass the tests above just as well.
  describe "each conjunct is load-bearing" do
    test "a stage that was never acked is re-dispatched", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      pid = start_router(task.id, assignee)
      assert_dispatched!()

      refute Orchestration.stage_acked?(task.id, stage.id),
             "this test is about the NEVER-ACKED path; an ack here would " <>
               "make the assertion below test the wrong branch"

      send(pid, :dispatch)
      :ok = sync_router(task.id)

      assert_dispatched!("with no ack there is no executor to protect — the dispatch must go out")
    end

    test "an ack recorded against a DIFFERENT stage does not suppress this one", %{
      task: task,
      plan: plan,
      stage: stage,
      assignee: assignee
    } do
      {:ok, other_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Build something else",
          description: "coding — stage 2",
          status: "pending"
        })

      pid = start_router(task.id, assignee)
      assert_dispatched!()

      # Ack the OTHER stage directly through the durable log. The running stage
      # remains unacked, so the guard must not read one stage's ack as another's.
      {:ok, _event} =
        Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.acked",
          "occurred_at" => DateTime.utc_now(),
          "payload" => %{
            "stage_id" => other_stage.id,
            "subagent_id" => "subagent-other-stage"
          }
        })

      assert Orchestration.stage_acked?(task.id, other_stage.id)
      refute Orchestration.stage_acked?(task.id, stage.id)

      send(pid, :dispatch)
      :ok = sync_router(task.id)

      assert_dispatched!(
        "an ack belonging to a different stage must not withhold this stage's dispatch"
      )
    end

    test "an executor that reported execution.finished after acking no longer protects the stage",
         %{task: task, stage: stage, assignee: assignee} do
      pid = start_router(task.id, assignee)
      assert_dispatched!()

      ack!(task, stage, assignee)

      # The subagent exits. Its ack is still well inside the safety-net window,
      # so ONLY the finished event distinguishes this from the withheld case
      # above — which is what makes this a probe of that conjunct alone.
      {:ok, _event} =
        Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.finished",
          "occurred_at" => DateTime.utc_now(),
          "payload" => %{"stage_id" => stage.id}
        })

      :ok = sync_router(task.id)

      assert DateTime.diff(
               DateTime.utc_now(),
               Orchestration.last_stage_ack_at(task.id, stage.id),
               :millisecond
             ) < coding_safety_net_ms(),
             "the ack must still be INSIDE its window, or this test passes on " <>
               "the age bound rather than on the finished event"

      send(pid, :dispatch)
      :ok = sync_router(task.id)

      assert_dispatched!(
        "an ack whose executor has already exited is a record of the past, " <>
          "not a live claim on the stage"
      )
    end

    # Ticket 01a08e86, instance 1. A review gate that FAILED, opened a
    # remediation stage and was then re-started carries a fresh `started_at`
    # while the prior round's ack is still inside the safety net — and the
    # subagent that wrote that ack returned long ago. Measured on the incident
    # stage (`01a08e59-60bf-7005`, task `01a08e57`): ack 03:15:45.117Z, restart
    # 03:31:11.254Z, and ZERO `execution.finished` rows for the stage or the
    # task, which is why `finished_since?/3` did not already cover it. The
    # fixture below deliberately records NO finished event for the same reason.
    test "a stage restarted after the ack is re-dispatched", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      pid = start_router(task.id, assignee)
      assert_dispatched!()

      ack!(task, stage, assignee)

      # POSITIVE CONTROL ON THIS FIXTURE. Before varying anything, show the
      # guard is actively suppressing here — otherwise the assertion at the
      # bottom passes for any reason at all, including a guard that never ran.
      send(pid, :dispatch)
      :ok = sync_router(task.id)

      refute_dispatched!(
        "with the stage still on its original started_at the ack must suppress, " <>
          "or the restart probe below is varying nothing"
      )

      assert_receive {:dispatch_suppressed, %{reason: :live_acked_executor}}, 2_000

      # THE ONE VARIED CONDITION: the stage restarts. This is the shape
      # `reset_gate_stage/1` + the `"running"` arm of `transition_stage/2`
      # produce — `started_at` NULLed on the way down, re-stamped on the way
      # back up — reproduced directly so the test pins the router's reading of
      # `started_at` and not PlanEngine's route to it.
      restarted_at = DateTime.utc_now()

      stage
      |> Ecto.Changeset.change(%{status: "running", started_at: restarted_at})
      |> Repo.update!()

      assert DateTime.compare(
               restarted_at,
               Orchestration.last_stage_ack_at(task.id, stage.id)
             ) == :gt,
             "the restart must postdate the ack, or this is not the incident shape"

      assert DateTime.diff(
               DateTime.utc_now(),
               Orchestration.last_stage_ack_at(task.id, stage.id),
               :millisecond
             ) < coding_safety_net_ms(),
             "the ack must still be INSIDE its window, or this test passes on " <>
               "the age bound rather than on the restart"

      refute Repo.exists?(
               from(e in RuntimeEvent,
                 where: e.task_id == ^task.id and e.event_type == "execution.finished"
               )
             ),
             "no execution.finished may exist here — the incident had none, and " <>
               "one would let this pass on finished_since?/3 instead"

      send(pid, :dispatch)
      :ok = sync_router(task.id)

      assert_dispatched!(
        "a stage that restarted after the ack has opened a NEW round; the prior " <>
          "round's ack is not a live claim on it and the dispatch must go out"
      )
    end

    test "a stage whose only pending gate is manual_approval has no safety net and is re-dispatched",
         %{task: task, stage: stage, validation: validation, assignee: assignee} do
      # Make `manual_approval` the ONLY pending validation, which is what
      # `current_stage_type/1` keys on to return the "manual_approval" stage
      # kind — the one entry in the matrix with `safety_net_ms: nil`.
      Repo.delete!(validation)

      {:ok, _manual} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      pid = start_router(task.id, assignee)
      assert_dispatched!()

      ack!(task, stage, assignee)

      send(pid, :dispatch)
      :ok = sync_router(task.id)

      assert_dispatched!(
        "a stage kind with no safety net has no deadline that would ever " <>
          "release a withheld dispatch, so it must never be withheld"
      )
    end
  end
end

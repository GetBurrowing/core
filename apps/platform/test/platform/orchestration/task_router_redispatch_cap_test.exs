defmodule Platform.Orchestration.TaskRouterRedispatchCapTest do
  @moduledoc """
  Task `01a16bf5` stage 1: unanswered re-dispatches are capped, backed off,
  and dead-lettered to `blocked`.

  ## The incident

  On 2026-10-23 one execution space took 1,437 `task_assigned` deliveries and
  3,346 `Dispatch withheld` notices at a 2s cadence. An injector sent
  `:dispatch` every ~2s and nothing in the router counted deliveries: once the
  last ack aged past the stage's safety net, every injection went out, and the
  lease re-dispatch path kept the old `ack_at`, so the no-ack alarm could not
  fire either.

  ## The claim this file pins

  Every `task_assigned` delivery passes through `do_dispatch_resolved/6`. With
  `cap` (default 5) deliveries to one runtime for one stage and no sign of life
  from that runtime since, the next dispatch is NOT delivered: the task moves
  to `blocked` with `blocked_cause.kind == "execution.dispatch_dead_lettered"`.
  Between deliveries a backoff of `base_ms * 2^(n - 1)` applies, and a
  throttled dispatch posts nothing and schedules no retry.

  ## What would falsify it

  Test (i) or (ii) observing a 6th broadcast on the runtime topic, or the task
  not blocked after 20 injections. On origin/main both deliver all 21.

  ## Why deliveries are counted on the runtime topic

  The broadcast on `runtime:<id>` is what wakes an agent. The execution-space
  engagement rows are counted too, because they are what the cap reads; the
  two counts must agree or the cap is reading something other than deliveries.

  `async: false` and shared sandbox: the router is a real GenServer reading the
  Repo from its own process. The TaskRouterWatcher is not started in test, so
  a blocked task does not stop the router here; that is why test (i) can go on
  injecting after the block and still observe nothing.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Chat.Message
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  @suppressed_event [:platform, :orchestration, :dispatch_suppressed]
  @dead_letter_kind "execution.dispatch_dead_lettered"
  @cap 5

  defp coding_safety_net_ms do
    LeaseManager.stage_kind_timeouts()
    |> Map.fetch!("coding")
    |> Map.fetch!(:safety_net_ms)
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    prior_cap = Application.get_env(:platform, :redispatch_cap)
    prior_base = Application.get_env(:platform, :redispatch_backoff_base_ms)
    Application.put_env(:platform, :redispatch_cap, @cap)
    Application.put_env(:platform, :redispatch_backoff_base_ms, 0)

    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Redispatch Cap Project #{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Redispatch cap #{n}",
        description: "Pin the unanswered re-dispatch cap",
        status: "in_progress",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    # "Build the feature" infers `stage_kind: "coding"`: a non-nil safety net,
    # so the live-acked guard is in play for the stale-ack and withheld tests.
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build the feature",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    # A pending non-manual gate keeps `no_unmet_gate_dispatch?/3` out of it.
    {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-redispatch-cap-#{n}"}
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{assignee.id}")

    handler_id = "redispatch-cap-#{n}"
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
      restore_env(:redispatch_cap, prior_cap)
      restore_env(:redispatch_backoff_base_ms, prior_base)

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{task: task, plan: plan, stage: stage, assignee: assignee}
  end

  # ── (i) the plain unacked stage ──────────────────────────────────────────

  test "(i) an unacked stage hit 20 times delivers exactly cap, then is dead-lettered to blocked",
       %{task: task, stage: stage, assignee: assignee} do
    pid = start_router(task.id, assignee)
    assert drain_deliveries() == 1, "the boot dispatch must deliver once (anti-vacuity)"

    inject(pid, task.id, 20)

    delivered = 1 + drain_deliveries()

    assert delivered == @cap,
           "expected exactly #{@cap} deliveries to an unanswering runtime, got #{delivered}"

    assert engagement_count(task.id, stage.id) == @cap,
           "the engagement rows the cap reads must agree with the broadcasts"

    assert_dead_lettered!(task.id, stage.id, assignee.id)
    assert_receive {:dispatch_suppressed, %{reason: :redispatch_dead_lettered}}, 2_000
  end

  # ── (ii) the stale-ack shape from prod ───────────────────────────────────

  test "(ii) an ack older than the safety net does not reopen the stream", %{
    task: task,
    stage: stage,
    assignee: assignee
  } do
    pid = start_router(task.id, assignee)
    assert drain_deliveries() == 1

    ack!(task, stage, assignee)
    age_ack!(task, stage, assignee, coding_safety_net_ms() + 60_000)

    # Positive control: the aged ack no longer withholds, so a dispatch goes out.
    inject(pid, task.id, 1)
    assert drain_deliveries() == 1, "an ack past its safety net must not withhold"

    inject(pid, task.id, 20)

    delivered = 2 + drain_deliveries()

    assert delivered == @cap,
           "the stale-ack shape must be capped like the never-acked one; got #{delivered}"

    assert_dead_lettered!(task.id, stage.id, assignee.id)
  end

  # ── (iii) a sign of life resets the streak ───────────────────────────────

  # An ack here would engage the live-acked guard and withhold every later
  # dispatch, so "not blocked" would pass on THAT guard. A heartbeat from the
  # same runtime is a sign of life the live-acked guard does not read, so the
  # deliveries after it are still observable.
  test "(iii) a runtime event between deliveries resets the streak; the task is not blocked", %{
    task: task,
    stage: stage,
    assignee: assignee
  } do
    pid = start_router(task.id, assignee)
    assert drain_deliveries() == 1

    inject(pid, task.id, @cap - 2)
    assert drain_deliveries() == @cap - 2

    assert %{count: count} =
             Orchestration.unanswered_dispatch_streak(task.id, stage.id, assignee.id)

    assert count == @cap - 1

    {:ok, _event} =
      Orchestration.record_runtime_event(%{
        "task_id" => task.id,
        "phase" => "execution",
        "runtime_id" => assignee.id,
        "event_type" => "execution.heartbeat",
        "occurred_at" => DateTime.utc_now(),
        "payload" => %{"stage_id" => stage.id}
      })

    assert %{count: 0} = Orchestration.unanswered_dispatch_streak(task.id, stage.id, assignee.id)

    inject(pid, task.id, @cap - 1)

    assert drain_deliveries() == @cap - 1,
           "after a sign of life the runtime gets a fresh streak"

    total = engagement_count(task.id, stage.id)
    assert total == 2 * @cap - 2, "more than cap deliveries in total, without a block"

    refute Tasks.get_task_record(task.id).status == "blocked"
  end

  # ── (iv) the backoff ─────────────────────────────────────────────────────

  test "(iv) with base 1_000, injections every 50ms for 1.5s deliver exactly 2, and nothing retries",
       %{task: task, stage: stage, assignee: assignee} do
    Application.put_env(:platform, :redispatch_backoff_base_ms, 1_000)

    pid = start_router(task.id, assignee)
    assert drain_deliveries() == 1
    started = System.monotonic_time(:millisecond)

    inject_until(pid, task.id, started + 1_500, 50)

    assert drain_deliveries() == 1,
           "the second delivery waits 1s; the third would wait 2s more"

    assert engagement_count(task.id, stage.id) == 2

    assert_receive {:dispatch_suppressed, %{reason: :redispatch_backoff}}, 1_000

    # NO RETRY TIMER: the injector has gone quiet. The third window (2s after
    # the second delivery) passes with nothing sent.
    refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_500

    refute Tasks.get_task_record(task.id).status == "blocked"
  end

  # ── (v) the withheld notice dedupe ───────────────────────────────────────

  test "(v) 20 injections inside the live-acked window post ONE Dispatch withheld row", %{
    task: task,
    stage: stage,
    assignee: assignee
  } do
    pid = start_router(task.id, assignee)
    assert drain_deliveries() == 1

    ack!(task, stage, assignee)

    inject(pid, task.id, 20)

    assert drain_deliveries() == 0, "a live acked stage must stay withheld"
    assert withheld_count(task.id) == 1

    # Telemetry stays per call.
    suppressed =
      Enum.count(flush_suppressed(), &(&1.reason == :live_acked_executor))

    assert suppressed >= 20
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp restore_env(key, nil), do: Application.delete_env(:platform, key)
  defp restore_env(key, value), do: Application.put_env(:platform, key, value)

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

  # One injection = one `:dispatch` followed by the barrier, so the debounce
  # cannot coalesce two injections into one decision.
  defp inject(pid, task_id, times) do
    Enum.each(1..times//1, fn _ ->
      send(pid, :dispatch)
      :ok = sync_router(task_id)
    end)
  end

  defp inject_until(pid, task_id, deadline, every_ms) do
    if System.monotonic_time(:millisecond) < deadline do
      send(pid, :dispatch)
      :ok = sync_router(task_id)
      Process.sleep(every_ms)
      inject_until(pid, task_id, deadline, every_ms)
    else
      :ok
    end
  end

  # Counts and consumes every `task_assigned` broadcast already in the mailbox.
  defp drain_deliveries(acc \\ 0) do
    receive do
      %Phoenix.Socket.Broadcast{
        event: "attention",
        payload: %{signal: %{reason: "task_assigned"}}
      } ->
        drain_deliveries(acc + 1)
    after
      200 -> acc
    end
  end

  defp flush_suppressed(acc \\ []) do
    receive do
      {:dispatch_suppressed, metadata} -> flush_suppressed([metadata | acc])
    after
      0 -> acc
    end
  end

  defp engagement_count(task_id, stage_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    Repo.aggregate(
      from(m in Message,
        where: m.space_id == ^space.id and is_nil(m.deleted_at),
        where: fragment("?->>'reason' = 'task_assigned'", m.metadata),
        where: fragment("?->>'stage_id' = ?", m.metadata, ^stage_id)
      ),
      :count
    )
  end

  defp withheld_count(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    Repo.aggregate(
      from(m in Message,
        where: m.space_id == ^space.id and is_nil(m.deleted_at),
        where: ilike(m.content, "Dispatch withheld:%")
      ),
      :count
    )
  end

  defp assert_dead_lettered!(task_id, stage_id, runtime_id) do
    task = Tasks.get_task_record(task_id)

    assert task.status == "blocked"

    assert %{"kind" => @dead_letter_kind, "stage_id" => ^stage_id, "runtime_id" => ^runtime_id} =
             task.metadata["blocked_cause"]

    assert task.metadata["blocked_reason"] =~ "#{@cap} unanswered deliveries"
    assert task.metadata["blocked_reason"] =~ runtime_id

    space = ExecutionSpace.find_by_task_id(task_id)

    blockers =
      Repo.all(
        from(m in Message,
          where: m.space_id == ^space.id and is_nil(m.deleted_at),
          where: fragment("?->>'reason' = ?", m.metadata, ^@dead_letter_kind)
        )
      )

    assert [blocker] = blockers, "exactly one dead-letter blocker post, however many injections"
    assert blocker.content =~ "Blocker reported:"
    assert blocker.metadata["needs_human"] == true
  end

  defp ack!(task, stage, assignee) do
    {:ok, _envelope} =
      ToolSurface.execute(
        "task_ack",
        %{
          "task_id" => task.id,
          "stage_id" => stage.id,
          "subagent_id" => "subagent-redispatch-cap-#{System.unique_integer([:positive])}"
        },
        %{runtime_id: Platform.RuntimeProfileFixtures.ensure_task_runtime!(assignee.id)}
      )

    :ok = sync_router(task.id)

    assert %DateTime{} = Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id)
    :ok
  end

  # Ages the ack AND the stage start (so the stage did not "restart after" it):
  # the prod shape, an executor that acked long ago and is gone.
  defp age_ack!(task, stage, assignee, ms_ago) do
    aged = DateTime.add(DateTime.utc_now(), -ms_ago, :millisecond)

    stage
    |> Ecto.Changeset.change(%{started_at: DateTime.add(aged, -60, :second)})
    |> Repo.update!()

    Repo.one!(
      from(e in RuntimeEvent,
        where:
          e.task_id == ^task.id and e.event_type == "execution.acked" and
            e.runtime_id == ^assignee.id and
            fragment("?->>'stage_id' = ?", e.payload, ^stage.id),
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: 1
      )
    )
    |> Ecto.Changeset.change(%{occurred_at: aged})
    |> Repo.update!()

    assert DateTime.compare(Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id), aged) ==
             :eq

    :ok
  end
end

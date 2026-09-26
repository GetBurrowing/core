defmodule Platform.Federation.StagelessDispatchMcpSurfaceTest do
  @moduledoc """
  Task 01a0a5fa stage 3 — acceptance item 2, in executable form: the trace of a
  dispatch that resolved NO stage must be readable FROM THE MCP SURFACE, not
  only from the database.

  ## Why this file is not a duplicate of the stage 1/2 test

  `task_router_stageless_dispatch_trace_test.exs` asserts the row exists by
  querying `runtime_events` with Ecto. That test would have passed against a
  `runtime_event_list` that filtered the row away — and a filtered read path is
  precisely how the 2026-09-15 instance on task 01a09de9 ended up being dug out
  of the gateway journal instead of read off MCP. So the assertion here goes
  through `ToolSurface.execute("runtime_event_list", ...)`: the same call an
  agent makes, returning the same serialized shape.

  MEASURED BEFORE WRITING, and recorded here because it bounds the claim:
  `execute("runtime_event_list", ...)` delegates to
  `Diagnostics.list_runtime_events/2`, which is `where(task_id == ^task_id)`
  plus an optional `event_type` filter, an order and a limit. There is no join
  to `execution_leases` and no `lease_id` predicate, so the read path never
  filtered lease-less events. The gap stage 1 closed was that the ROW DID NOT
  EXIST, not that it was hidden. This file pins the composition — row written,
  row returned — which is the thing acceptance item 2 actually asks for and
  which neither half proves alone.

  ## Anti-vacuity

  The suppression cases (`suppress_live_acked_executor/3`,
  `suppress_unchanged_boot_engagement/2`) assert that NO
  `execution.dispatch_stageless` row comes back. On its own that assertion
  passes against an implementation that emits the event nowhere at all, which
  is why the positive case lives in this same file and runs first — and why
  each suppression test additionally requires the
  `[:platform, :orchestration, :dispatch_suppressed]` telemetry with its own
  reason, so a test whose fixture failed to reach the suppression path flunks
  instead of passing on an absence it never caused.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  @suppressed_event [:platform, :orchestration, :dispatch_suppressed]

  # An agent-less context authorizes as root (`authorize_review_access/2`
  # returns :ok when `load_agent/1` finds nobody). The tenant-denial behaviour
  # of this tool is owned by `tool_surface_call_ledger_test.exs`; repeating it
  # here would test the authorizer instead of the read path.
  @ctx %{}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Stageless MCP Surface Project",
        repo_url: "https://github.com/test/stageless-mcp-surface"
      })

    %{project: project}
  end

  describe "the stageless trace is readable through runtime_event_list" do
    test "a no-stage dispatch's execution.dispatch_stageless row comes back over MCP", %{
      project: project
    } do
      %{task: task} = fixture = planning_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      send(pid, :dispatch)
      barrier(task)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"},
                     1_000,
                     "the dispatch must actually have been sent — otherwise every assertion " <>
                       "below is about a dispatch that never happened"

      assert {:ok, result} =
               ToolSurface.execute("runtime_event_list", %{"task_id" => task.id}, @ctx)

      assert result.task_id == task.id

      stageless =
        Enum.filter(result.events, &(&1.event_type == "execution.dispatch_stageless"))

      assert length(stageless) >= 1,
             "the stageless dispatch trace must be returned by the MCP read path, not only " <>
               "written to the table — that is acceptance item 2 of task 01a0a5fa"

      event = hd(stageless)

      # The serialized shape an agent actually reads, not the Ecto struct.
      assert event.payload["stage_id"] == nil
      assert event.payload["task_status"] == "planning"
      assert event.payload["dispatch_runtime_id"] == runtime_id
      assert is_boolean(event.payload["delivered_online"])
      assert event.payload["description"] =~ task.id
      assert event.phase == "planning"
      assert event.occurred_at

      # The row has no lease, and that is the whole reason a lease-joined read
      # path would have hidden it. COMPANION to the positive above, never the
      # whole test.
      assert event.lease_id == nil
      assert LeaseManager.get(task.id) == nil

      assert Repo.aggregate(
               from(l in Platform.Orchestration.ExecutionLease, where: l.task_id == ^task.id),
               :count
             ) == 0
    end

    test "the event_type filter resolves it by name", %{project: project} do
      # An agent diagnosing a silent task filters rather than paging: if the
      # open-vocabulary filter did not match this type, the row would be
      # reachable only by reading every event, which is not how the tool is
      # documented to be used.
      %{task: task} = fixture = planning_task(project)
      %{pid: pid} = start_router!(fixture)

      send(pid, :dispatch)
      barrier(task)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      assert {:ok, result} =
               ToolSurface.execute(
                 "runtime_event_list",
                 %{"task_id" => task.id, "event_type" => "execution.dispatch_stageless"},
                 @ctx
               )

      assert result.count >= 1
      assert Enum.all?(result.events, &(&1.event_type == "execution.dispatch_stageless"))
    end
  end

  describe "suppressed dispatches send no frame and so leave no stageless row" do
    test "suppress_live_acked_executor records nothing", %{project: project} do
      %{task: task, stage: stage} = fixture = running_stage_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      # The stage was acked moments ago by an executor still inside its safety
      # net, so the router withholds the frame.
      insert_ack(task.id, stage.id, runtime_id)

      watch_suppressions!(runtime_id)

      # The BOOT dispatch already sent a frame for this stage-bearing task and
      # it is sitting in the mailbox. Drain it, so the refutation below is about
      # the dispatch driven after the ack and not about that earlier, legitimate
      # one. Positive control: there must BE one to drain.
      assert flush_attention!() >= 1,
             "the boot dispatch never sent a frame, so this fixture is not the one described"

      send(pid, :dispatch)
      barrier(task)

      # ANTI-VACUITY: prove the suppression path was actually taken. Without
      # this, a fixture that simply failed to dispatch would satisfy the
      # assertion below identically.
      assert_received {:dispatch_suppressed, %{reason: :live_acked_executor}},
                      "the live-acked suppression never fired, so the assertion below would be " <>
                        "about a dispatch that was never suppressed"

      refute_received %Phoenix.Socket.Broadcast{event: "attention"}

      assert mcp_stageless_events(task.id) == [],
             "no frame was sent, so nothing may be recorded as a stageless dispatch"
    end

    test "suppress_unchanged_boot_engagement records nothing", %{project: project} do
      %{task: task} = fixture = planning_task(project)

      # First boot: a real dispatch, which writes the engagement row whose
      # content the guard compares against. This one DOES leave a stageless
      # row — that is the positive control, and it is what makes the refutation
      # after the second boot meaningful.
      %{pid: pid, runtime_id: runtime_id, space_id: space_id} = start_router!(fixture)
      send(pid, :dispatch)
      barrier(task)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      first_round = mcp_stageless_events(task.id)

      assert length(first_round) >= 1,
             "the first boot must have recorded a stageless dispatch, or the second boot's " <>
               "refutation is about an event that never fires anywhere"

      stop_router!(task)

      # The guard requires `delivered_online == true`; nothing is subscribed to
      # a runtime presence in test, so the recorded metadata says false. Stub
      # the lookup with the REAL engagement content (byte-equality against the
      # re-rendered prompt is the guard's actual condition and is not faked)
      # and only the presence flag overridden.
      stub_engagement_lookup!(space_id, runtime_id)

      before = length(first_round)

      # Attach BEFORE the router boots: `init/1` sends `:dispatch_boot` itself,
      # and the boot dispatch is the only one this guard can fire on.
      watch_suppressions!(runtime_id)
      _ = start_router!(fixture, runtime_id: runtime_id)

      assert_receive {:dispatch_suppressed, %{reason: :unchanged_boot_engagement}},
                     2_000,
                     "the boot-engagement suppression never fired — most likely the re-rendered " <>
                       "planning prompt is not byte-identical to the stored engagement, which " <>
                       "would make this fixture, not the code, the thing under test"

      assert length(mcp_stageless_events(task.id)) == before,
             "a withheld boot dispatch must add no stageless row: no frame was sent"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp planning_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Stageless MCP surface probe",
        status: "planning"
      })

    %{task: task}
  end

  defp running_stage_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Live-acked stage probe",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")

    %{task: task, stage: stage}
  end

  # Task 01a0c762 stage 2: the ack is written in the DISPATCHED runtime's
  # name. The router's live-acked guard now counts only the lease owner's
  # rows, so a fixed `"runtime-acked-executor"` would suppress nothing.
  defp insert_ack(task_id, stage_id, runtime_id) do
    Repo.insert!(%RuntimeEvent{
      task_id: task_id,
      event_type: "execution.acked",
      runtime_id: runtime_id,
      phase: "execution",
      occurred_at: DateTime.utc_now(),
      # NOT NULL on `runtime_events`; the production writer derives it, and a
      # fixture that omits it fails on the constraint rather than the case.
      idempotency_key: "ack-#{stage_id}-#{System.unique_integer([:positive])}",
      payload: %{"stage_id" => stage_id, "subagent_id" => "sub-live"}
    })
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Reads the trace the way an AGENT does. Every assertion about presence or
  # absence in this file goes through here, so a read-path regression reddens
  # the suppression tests too rather than only the positive one.
  defp mcp_stageless_events(task_id) do
    {:ok, result} = ToolSurface.execute("runtime_event_list", %{"task_id" => task_id}, @ctx)
    Enum.filter(result.events, &(&1.event_type == "execution.dispatch_stageless"))
  end

  defp start_router!(%{task: task}, opts \\ []) do
    runtime_id =
      Keyword.get_lazy(opts, :runtime_id, fn ->
        "runtime-mcp-stageless-#{System.unique_integer([:positive])}"
      end)

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")
    on_exit(fn -> PlatformWeb.Endpoint.unsubscribe("runtime:#{runtime_id}") end)

    assignee = %{type: :federated, id: runtime_id}
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    on_exit(fn -> stop_router!(task) end)

    status = barrier(task)

    %{pid: pid, runtime_id: runtime_id, space_id: status.execution_space_id}
  end

  defp stop_router!(task) do
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
  end

  # The indirection `TaskRouter.engagement_lookup/0` reads exists so a test can
  # substitute the lookup; here the substitution keeps the real CONTENT (the
  # byte-equality the guard turns on) and only forces the presence flag, which
  # no test-env runtime can make true.
  defp stub_engagement_lookup!(space_id, runtime_id) do
    engagement = Platform.Orchestration.ExecutionSpace.latest_engagement(space_id)

    assert %{content: content} = engagement,
           "the first boot wrote no engagement row, so the guard has nothing to compare"

    {:ok, _} = Agent.start_link(fn -> nil end, name: __MODULE__.EngagementStub)

    Application.put_env(
      :platform,
      :execution_space_engagement_lookup,
      __MODULE__.StubLookup
    )

    Agent.update(__MODULE__.EngagementStub, fn _ ->
      %{
        content: content,
        metadata: %{
          "dispatch_runtime_id" => runtime_id,
          "delivered_online" => true,
          "kind" => "engagement",
          "source" => "task_router"
        }
      }
    end)

    on_exit(fn ->
      Application.delete_env(:platform, :execution_space_engagement_lookup)
    end)
  end

  defmodule StubLookup do
    @moduledoc false
    def latest_engagement(_space_id) do
      Agent.get(Platform.Federation.StagelessDispatchMcpSurfaceTest.EngagementStub, & &1)
    end
  end

  # Returns how many it drained, so a caller can assert the frames it is
  # discarding actually existed.
  defp flush_attention!(count \\ 0) do
    receive do
      %Phoenix.Socket.Broadcast{event: "attention"} -> flush_attention!(count + 1)
    after
      0 -> count
    end
  end

  defp watch_suppressions!(runtime_id) do
    handler_id = "stageless-mcp-suppression-#{System.unique_integer([:positive])}"
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

    _ = runtime_id
    :ok
  end

  defp barrier(task) do
    :ok = sync_router(task.id)
    TaskRouter.current_status(task.id)
  end
end

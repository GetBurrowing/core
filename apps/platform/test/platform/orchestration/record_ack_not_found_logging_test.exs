defmodule Platform.Orchestration.RecordAckNotFoundLoggingTest do
  @moduledoc """
  Task 01a007bf stage 4 — `LeaseManager.record_ack/1` returning
  `{:error, :not_found}` used to vanish into `_ =` at both call sites. Every
  occurrence of the acked-stage no-ack bug emitted one and nobody saw it.

  Both sites now log at `Logger.warning`, with DELIBERATELY DIFFERENT text:

    * `tool_surface.ex` `emit_task_ack/4` runs BEFORE the durable
      `execution.acked` row is written, so `:not_found` there is the expected
      dispatch race — "no ETS lease armed yet (expected during the dispatch
      race)".
    * `task_router.ex` `apply_runtime_event/2` runs on the broadcast of an
      ack that already persisted, so `:not_found` there means the lease was
      erased under an acked stage — "ETS lease row missing for an acked
      stage". That is the actionable one.

  Both the positive and the NEGATIVE are asserted: the happy path must emit
  neither string.

  async: false — the LeaseManager is a global singleton.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.{LeaseManager, TaskRouter}
  alias Platform.Tasks

  @tool_surface_marker "no ETS lease armed yet (expected during the dispatch race)"
  @router_marker "ETS lease row missing for an acked stage"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{name: "record_ack logging #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "record_ack :not_found logging",
        description: "Stage 4",
        status: "in_progress",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build the feature",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-ack-log-#{System.unique_integer([:positive])}"}

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
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

    %{task: task, stage: stage, assignee: assignee}
  end

  defp boot_router!(task, assignee) do
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    :ok = sync_router(task.id)
    pid
  end

  defp ack!(task, stage) do
    {:ok, _} =
      ToolSurface.execute(
        "task_ack",
        %{
          "task_id" => task.id,
          "stage_id" => stage.id,
          "subagent_id" => "subagent-#{System.unique_integer([:positive])}"
        },
        %{}
      )

    :ok = sync_router(task.id)
    :ok
  end

  describe "the :not_found return is visible in the log" do
    test "an ack with NO armed lease logs the expected-race warning at the tool_surface site",
         %{task: task, stage: stage, assignee: assignee} do
      _pid = boot_router!(task, assignee)
      :ok = LeaseManager.clear(task.id)
      refute LeaseManager.get(task.id), "precondition: no lease row may be armed"

      log = capture_log(fn -> :ok = ack!(task, stage) end)

      assert log =~ @tool_surface_marker,
             "the tool_surface site must name the dispatch race: #{log}"

      assert log =~ stage.id, "the warning must carry the stage_id: #{log}"
      assert log =~ task.id, "the warning must carry the task_id: #{log}"
    end

    test "the router site's warning is worded as the actionable one, not the expected race",
         %{task: task, stage: stage, assignee: assignee} do
      _pid = boot_router!(task, assignee)
      :ok = LeaseManager.clear(task.id)

      log = capture_log(fn -> :ok = ack!(task, stage) end)

      assert log =~ @router_marker,
             "the router site must say the lease was erased under an acked stage: #{log}"

      assert log =~ "[TaskRouter]"
      assert log =~ stage.id

      # The whole point of the stage: an operator grepping the log can tell
      # the two meanings apart.
      refute @router_marker == @tool_surface_marker
    end
  end

  describe "the happy path stays silent" do
    test "an ack against an armed lease logs NEITHER warning", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      _pid = boot_router!(task, assignee)

      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          DateTime.add(DateTime.utc_now(), -30, :second)
        )

      assert LeaseManager.get(task.id), "precondition: a lease row must be armed"

      log = capture_log(fn -> :ok = ack!(task, stage) end)

      refute log =~ @tool_surface_marker,
             "the tool_surface site must stay silent when the lease exists: #{log}"

      refute log =~ @router_marker,
             "the router site must stay silent when the lease exists: #{log}"

      assert %{ack_at: %DateTime{}} = LeaseManager.get(task.id),
             "the happy path must still record the ack"
    end
  end
end

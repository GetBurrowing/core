defmodule Platform.Federation.ToolSurfaceTaskAckTest do
  @moduledoc """
  Coverage for the `task_ack` MCP tool (task 019f640d stage 5).

  Executes the tool through `Platform.Federation.ToolSurface.execute/3`
  — i.e. as an MCP client would — and asserts on:

    * the return envelope (`ack_at`, `next_safety_net_at`, `event_id`),
    * the persisted `execution.acked` runtime_event row,
    * the LeaseManager row extension (safety-net advances past the
      original dispatch deadline),
    * stage_id resolution from `current_running_stage` when the caller
      omits the arg,
    * error envelopes for unknown task_id and no-running-stage,
    * bundle exposure via `list_tools(["task"])`.

  async: false — the LeaseManager is a global singleton owned by
  Platform.Application; parallel tests would trample each other's
  lease rows.
  """

  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.{LeaseManager, RuntimeEvent}
  alias Platform.Repo
  alias Platform.Tasks

  import Ecto.Query

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Task-ack test project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/task-ack"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Task-ack test task",
        description: "Exercises task_ack",
        deploy_target: "production"
      })

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "coding",
        description: "Write code"
      })

    {:ok, stage} = Tasks.transition_stage(stage, "running")

    on_exit(fn ->
      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{project: project, task: task, plan: plan, stage: stage}
  end

  describe "tool discovery" do
    test "task_ack appears in list_tools([\"task\"]) with the 6-component rubric" do
      tools = ToolSurface.list_tools(["task"])
      task_ack = Enum.find(tools, &(&1.name == "task_ack"))

      assert task_ack, "task_ack must be registered in the task bundle"
      assert task_ack.bundle == "task"

      for key <- [:name, :description, :parameters, :returns, :limitations, :when_to_use] do
        assert Map.has_key?(task_ack, key), "task_ack missing #{key}"
      end

      assert task_ack.parameters.task_id.required == true
      assert task_ack.parameters.stage_id.required == false
    end
  end

  describe "execute/3 happy path" do
    test "returns {:ok, envelope} and persists execution.acked event", %{task: task, stage: stage} do
      dispatched_at = DateTime.utc_now() |> DateTime.add(-30, :second)
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at)

      {:ok, result} =
        ToolSurface.execute(
          "task_ack",
          %{"task_id" => task.id, "stage_id" => stage.id},
          %{runtime_id: "runtime-test-#{System.unique_integer([:positive])}"}
        )

      assert result.task_id == task.id
      assert result.stage_id == stage.id
      assert %DateTime{} = result.acked_at
      assert is_binary(result.event_id)
      assert %DateTime{} = result.next_safety_net_at

      # The persisted event carries the right event_type + payload shape
      event = Repo.get!(RuntimeEvent, result.event_id)
      assert event.event_type == "execution.acked"
      assert event.task_id == task.id
      assert event.payload["stage_id"] == stage.id
    end

    test "extends the LeaseManager safety-net past the initial dispatch deadline",
         %{task: task, stage: stage} do
      # Dispatch 60 seconds ago; safety-net was originally dispatched_at + 90m.
      dispatched_at = DateTime.utc_now() |> DateTime.add(-60, :second)
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at)

      pre_ack_lease = LeaseManager.get(task.id)
      assert pre_ack_lease.ack_at == nil
      original_safety_net_at = pre_ack_lease.safety_net_at

      {:ok, _} =
        ToolSurface.execute(
          "task_ack",
          %{"task_id" => task.id, "stage_id" => stage.id},
          %{}
        )

      post_ack_lease = LeaseManager.get(task.id)
      assert %DateTime{} = post_ack_lease.ack_at
      assert post_ack_lease.no_ack_at == nil
      assert post_ack_lease.no_ack_fired? == false

      # record_ack resets safety_net_at from `now` (which is later than
      # `dispatched_at`) so the extended deadline must be strictly later.
      assert DateTime.compare(post_ack_lease.safety_net_at, original_safety_net_at) == :gt
    end
  end

  describe "execute/3 stage_id resolution" do
    test "resolves stage_id from current_running_stage when arg is omitted",
         %{task: task, stage: stage} do
      {:ok, result} =
        ToolSurface.execute(
          "task_ack",
          %{"task_id" => task.id},
          %{}
        )

      assert result.stage_id == stage.id
    end

    test "returns :no_running_stage when the plan has no running stage", %{project: project} do
      # Fresh task with a plan but a pending (not running) stage.
      {:ok, task2} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Task with only pending stages"
        })

      {:ok, plan2} =
        Tasks.create_plan(%{task_id: task2.id, status: "approved", version: 1})

      {:ok, _pending_stage} =
        Tasks.create_stage(%{
          plan_id: plan2.id,
          position: 1,
          name: "not_running",
          description: "still pending"
        })

      {:error, err} =
        ToolSurface.execute(
          "task_ack",
          %{"task_id" => task2.id},
          %{}
        )

      assert err.error =~ "no running stage"
      assert err.recoverable == true
      assert err.suggestion =~ "stage_id"
    end
  end

  describe "execute/3 error envelopes" do
    test "returns :not_found on unknown task_id" do
      {:error, err} =
        ToolSurface.execute(
          "task_ack",
          %{"task_id" => Ecto.UUID.generate()},
          %{}
        )

      assert err.error =~ "Task not found"
      assert err.recoverable == false
      assert err.suggestion =~ "task_list"
    end

    test "returns error when task_id is missing entirely" do
      {:error, err} = ToolSurface.execute("task_ack", %{}, %{})

      assert err.error =~ "task_id is required"
      assert err.recoverable == true
    end
  end

  describe "belt-and-braces LeaseManager write" do
    test "records ack even when no dispatch was recorded first (soft failure)",
         %{task: task, stage: stage} do
      # Deliberately DO NOT call record_dispatch — simulates the boot race
      # where a runtime spawns and ack-calls before the router has armed
      # its timers. The tool must still succeed and emit the event.
      :ok = LeaseManager.clear(task.id)
      assert LeaseManager.get(task.id) == nil

      {:ok, result} =
        ToolSurface.execute(
          "task_ack",
          %{"task_id" => task.id, "stage_id" => stage.id},
          %{runtime_id: "runtime-boot-race-#{System.unique_integer([:positive])}"}
        )

      # No lease was armed, so next_safety_net_at is nil — the runtime
      # can still push validation_pass to prove liveness later.
      assert result.next_safety_net_at == nil

      # The runtime_event still landed.
      event_count =
        RuntimeEvent
        |> where([e], e.task_id == ^task.id and e.event_type == "execution.acked")
        |> Repo.aggregate(:count, :id)

      assert event_count >= 1
    end
  end
end

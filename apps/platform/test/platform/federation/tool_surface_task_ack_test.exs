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

  alias Platform.Federation.ToolArguments
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

      # task 019f6c73: subagent_id closes the "acked but never spawned" defect.
      assert Map.has_key?(task_ack.parameters, :subagent_id),
             "task_ack must expose subagent_id in its parameters schema"

      assert task_ack.parameters.subagent_id.required == true
      assert task_ack.parameters.subagent_id.type == "string"

      assert task_ack.description =~ "spawn the subagent FIRST",
             "task_ack description must instruct spawn-first ordering"
    end
  end

  describe "execute/3 happy path" do
    test "returns {:ok, envelope} and persists execution.acked event", %{task: task, stage: stage} do
      dispatched_at = DateTime.utc_now() |> DateTime.add(-30, :second)
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at)

      {:ok, result} =
        ToolSurface.execute(
          "task_ack",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "subagent_id" => "higgins.moon"
          },
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
      assert event.payload["subagent_id"] == "higgins.moon"
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
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "subagent_id" => "higgins.moon"
          },
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
          %{"task_id" => task.id, "subagent_id" => "higgins.moon"},
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
          %{"task_id" => task2.id, "subagent_id" => "higgins.moon"},
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
          %{"task_id" => Ecto.UUID.generate(), "subagent_id" => "higgins.moon"},
          %{}
        )

      assert err.error =~ "Task not found"
      assert err.recoverable == false
      assert err.suggestion =~ "task_list"
    end

    # Migrated to dispatch/3 in 019fa609 stage 4. task_ack's own task_id check
    # is gone; note that subagent_id must be supplied here or the gate refuses
    # on THAT parameter first (declaration order is alphabetical), which would
    # make the assertion pass for the wrong reason.
    test "returns error when task_id is missing entirely" do
      {:error, err} =
        ToolArguments.dispatch("task_ack", %{"subagent_id" => "higgins.moon"}, %{})

      assert err.error =~ "task_id is required"
      assert err.code == :missing_task_id
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
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "subagent_id" => "higgins.moon"
          },
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

  describe "subagent_id validation (task 019f6c73)" do
    # Each rejection case must:
    #   1. return {:error, %{recoverable: true, suggestion: <hints spawn/subagent>}}
    #   2. NOT emit any execution.acked runtime_event (validation runs before
    #      record_runtime_event/1)

    setup %{task: task, stage: stage} do
      dispatched_at = DateTime.utc_now() |> DateTime.add(-30, :second)
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at)
      :ok
    end

    for {label, args} <- [
          {"missing subagent_id key", %{}},
          {"empty subagent_id string", %{"subagent_id" => ""}},
          {"whitespace-only subagent_id", %{"subagent_id" => "   \t  "}},
          {"oversized subagent_id (>128 bytes)", %{"subagent_id" => String.duplicate("x", 129)}}
        ] do
      test "rejects #{label} without writing a runtime_event", %{task: task, stage: stage} do
        base = %{"task_id" => task.id, "stage_id" => stage.id}
        args = Map.merge(base, unquote(Macro.escape(args)))

        {:error, err} = ToolSurface.execute("task_ack", args, %{})

        assert err.recoverable == true
        assert is_binary(err.error)
        assert is_binary(err.suggestion)

        # Suggestion mentions either the spawn action or the field itself so the
        # operator has a concrete recovery path.
        assert err.suggestion =~ ~r/spawn|subagent_id/i

        # No execution.acked row landed — validation short-circuits BEFORE
        # record_runtime_event/1 runs.
        event_count =
          RuntimeEvent
          |> where(
            [e],
            e.task_id == ^task.id and e.event_type == "execution.acked"
          )
          |> Repo.aggregate(:count, :id)

        assert event_count == 0,
               "no execution.acked event should have been persisted for #{unquote(label)}"
      end
    end
  end

  describe "subagent_id success path (task 019f6c73)" do
    # Schema doesn't police format — only presence + non-empty + ≤128 bytes.
    # Both actor classes (openclaw runtime slug, Claude Code Task-tool agentId)
    # must fit through the same gate.

    setup %{task: task, stage: stage} do
      dispatched_at = DateTime.utc_now() |> DateTime.add(-30, :second)
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at)
      :ok
    end

    test "accepts openclaw runtime slug shape (higgins.moon)",
         %{task: task, stage: stage} do
      {:ok, result} =
        ToolSurface.execute(
          "task_ack",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "subagent_id" => "higgins.moon"
          },
          %{}
        )

      event = Repo.get!(RuntimeEvent, result.event_id)
      assert event.payload["subagent_id"] == "higgins.moon"
    end

    test "accepts Claude Code Task-tool agentId shape (hex)",
         %{task: task, stage: stage} do
      {:ok, result} =
        ToolSurface.execute(
          "task_ack",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "subagent_id" => "afd767f1e0cc81633"
          },
          %{}
        )

      event = Repo.get!(RuntimeEvent, result.event_id)
      assert event.payload["subagent_id"] == "afd767f1e0cc81633"
    end

    test "accepts a 128-byte subagent_id at the boundary",
         %{task: task, stage: stage} do
      # Exactly 128 bytes — inclusive upper bound.
      id_at_limit = String.duplicate("a", 128)

      {:ok, result} =
        ToolSurface.execute(
          "task_ack",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "subagent_id" => id_at_limit
          },
          %{}
        )

      event = Repo.get!(RuntimeEvent, result.event_id)
      assert event.payload["subagent_id"] == id_at_limit
    end
  end
end

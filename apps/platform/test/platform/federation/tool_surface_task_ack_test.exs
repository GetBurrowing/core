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
    * the non-owner refusal (task 01a0c762): a runtime other than the one
      the lease was dispatched to gets a recoverable envelope and no
      `execution.acked` row,
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

  # Task 01a0c762: the lease accepts an ack only from the runtime it was
  # dispatched to, so the lease-asserting cases dispatch to and ack as
  # this one runtime.
  @owner "runtime-task-ack-owner"

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

      # task 019f6c73 / 01a0ac55: task_ack requires a subagent_id; does not verify it.
      assert Map.has_key?(task_ack.parameters, :subagent_id),
             "task_ack must expose subagent_id in its parameters schema"

      assert task_ack.parameters.subagent_id.required == true
      assert task_ack.parameters.subagent_id.type == "string"

      assert task_ack.description =~ "spawn the subagent FIRST",
             "task_ack description must instruct spawn-first ordering"
    end

    # 01a0c762 stage 3: the ownership grain is a fact about the tool.
    test "task_ack description states the runtime ownership grain" do
      task_ack = ToolSurface.list_tools(["task"]) |> Enum.find(&(&1.name == "task_ack"))

      assert task_ack.description =~ ~r/runtime the stage was dispatched to/,
             "task_ack must state that the ack must come from the dispatched runtime"

      assert task_ack.description =~ ~r/AUTHENTICATED caller/,
             "task_ack must state that the caller is authenticated, not an argument"

      assert task_ack.description =~
               ~r/`subagent_id` is recorded for audit only and is not verified/,
             "task_ack must state that subagent_id is audit-only"
    end

    # 01a0a633 stage 3: the supplied-stage_id contract is a fact about the
    # tool, not an implementation detail. Asserted here so the prose cannot
    # silently drift back to describing only the derived path.
    test "task_ack description states the supplied-stage_id contract" do
      task_ack = ToolSurface.list_tools(["task"]) |> Enum.find(&(&1.name == "task_ack"))
      blob = task_ack.description <> " " <> task_ack.limitations

      assert blob =~ ~r/belongs? to this `task_id`/i,
             "task_ack must state that a supplied stage_id must belong to the acked task"

      assert blob =~ ~r/exists?/i,
             "task_ack must state that a supplied stage_id must exist"

      assert blob =~ ~r/running/i,
             "task_ack must state that a supplied stage_id must be running"

      assert task_ack.parameters.stage_id.description =~ ~r/belong to this `task_id`/i and
               task_ack.parameters.stage_id.description =~ ~r/running/i,
             "the stage_id parameter description must carry the same contract"
    end

    test "alarm_silence description states the same supplied-stage_id contract" do
      silence =
        ToolSurface.list_tools(["task"]) |> Enum.find(&(&1.name == "alarm_silence"))

      assert silence, "alarm_silence must be registered"
      blob = silence.description <> " " <> silence.limitations

      assert blob =~ ~r/belongs? to this `task_id`/i or blob =~ ~r/belongs to another task/i,
             "alarm_silence must state the belongs-to-this-task requirement"

      assert blob =~ ~r/running/i,
             "alarm_silence must state the running requirement"
    end
  end

  describe "execute/3 happy path" do
    test "returns {:ok, envelope} and persists execution.acked event", %{task: task, stage: stage} do
      dispatched_at = DateTime.utc_now() |> DateTime.add(-30, :second)
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at, @owner)

      {:ok, result} =
        ToolSurface.execute(
          "task_ack",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "subagent_id" => "higgins.moon"
          },
          %{runtime_id: @owner}
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
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at, @owner)

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
          %{runtime_id: @owner}
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
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at, @owner)
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
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at, @owner)
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
          %{runtime_id: @owner}
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
          %{runtime_id: @owner}
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
          %{runtime_id: @owner}
        )

      event = Repo.get!(RuntimeEvent, result.event_id)
      assert event.payload["subagent_id"] == id_at_limit
    end
  end

  # ── non-owner refusal at the tool surface (task 01a0c762 stage 3) ──
  #
  # A tool-contract test, NOT the ticket's acceptance: the acceptance is the
  # direct LeaseManager test in `lease_manager_ack_ownership_test.exs`, which
  # a tool-level refusal would otherwise absorb. What this pins is the
  # tool's half: the envelope, and that a refused ack writes NO durable
  # `execution.acked` row for any Postgres reader to consume.
  describe "execute/3 non-owner refusal (task 01a0c762)" do
    setup %{task: task, stage: stage} do
      dispatched_at = DateTime.utc_now() |> DateTime.add(-60, :second)
      :ok = LeaseManager.record_dispatch(task.id, stage.id, "coding", dispatched_at, @owner)
      :ok
    end

    defp acked_rows(task_id, stage_id) do
      RuntimeEvent
      |> where(
        [e],
        e.task_id == ^task_id and e.event_type == "execution.acked" and
          fragment("?->>'stage_id' = ?", e.payload, ^stage_id)
      )
      |> Repo.all()
    end

    defp ack_as(task_id, stage_id, context) do
      ToolSurface.execute(
        "task_ack",
        %{"task_id" => task_id, "stage_id" => stage_id, "subagent_id" => "sub-probe"},
        context
      )
    end

    test "a non-owner ack returns the recoverable envelope and writes no execution.acked row",
         %{task: task, stage: stage} do
      before = LeaseManager.get(task.id)

      {:error, err} = ack_as(task.id, stage.id, %{runtime_id: "runtime-intruder"})

      assert err.recoverable == true
      assert err.error =~ "task_id=#{task.id}"
      assert err.error =~ "stage_id=#{stage.id}"
      assert err.error =~ "dispatched to runtime #{@owner}"
      assert err.error =~ "not runtime-intruder"
      assert err.suggestion =~ ~r/runtime that received the dispatch/
      assert err.suggestion =~ ~r/phase assignee/

      assert acked_rows(task.id, stage.id) == []
      assert LeaseManager.get(task.id) == before
    end

    test "a caller with no authenticated runtime is refused, never treated as tool-surface",
         %{task: task, stage: stage} do
      before = LeaseManager.get(task.id)

      {:error, err} = ack_as(task.id, stage.id, %{})

      assert err.recoverable == true
      assert err.error =~ "dispatched to runtime #{@owner}"
      assert acked_rows(task.id, stage.id) == []
      assert LeaseManager.get(task.id) == before
    end

    # Positive control for the two refusals above: the same fixture, acked by
    # the owner, DOES write the row and move the deadline. A tool that refused
    # everything would pass the refusal tests and fail this one.
    test "the owner's ack returns {:ok, _}, writes the row and moves next_safety_net_at",
         %{task: task, stage: stage} do
      before = LeaseManager.get(task.id)

      {:ok, result} = ack_as(task.id, stage.id, %{runtime_id: @owner})

      assert %DateTime{} = result.next_safety_net_at
      assert DateTime.compare(result.next_safety_net_at, before.safety_net_at) == :gt

      assert [row] = acked_rows(task.id, stage.id)
      assert row.id == result.event_id
      assert row.runtime_id == @owner
      assert row.payload["runtime_id"] == @owner
      assert row.payload["subagent_id"] == "sub-probe"

      lease = LeaseManager.get(task.id)
      assert lease.ack_runtime_id == @owner
      assert lease.ack_subagent_id == "sub-probe"
    end
  end

  # ── supplied stage_id is checked, not trusted (task 01a0a633 stage 1) ──
  #
  # Every test here was RED before the guard landed: the old supplied-id
  # clause returned {:ok, stage_id} for any non-empty binary, so all three
  # acks SUCCEEDED and armed the suppression. A test asserting that a
  # running stage of the right task still acks would be vacuous — it
  # passes on both sides of the change — so that case is covered by the
  # existing happy-path describe block and is not restated here.
  describe "execute/3 supplied stage_id guard" do
    defp ack_with_stage(task_id, stage_id) do
      ToolSurface.execute(
        "task_ack",
        %{"task_id" => task_id, "stage_id" => stage_id, "subagent_id" => "higgins.moon"},
        %{}
      )
    end

    # A refusal must leave the suppression UNARMED. This is the half that
    # actually matters: an envelope the caller ignores is cosmetic, a
    # written execution.acked row parks the stage for the safety-net window.
    #
    # A direct row query, not a reader: the row from ANY runtime is what must
    # be absent, and the unscoped `last_stage_ack_at/2` that used to sit here
    # was deleted (task 01a0db63-c4f3).
    defp refute_suppression_armed(task_id, stage_id) do
      refute Repo.exists?(
               from(e in RuntimeEvent,
                 where:
                   e.task_id == ^task_id and e.event_type == "execution.acked" and
                     fragment("?->>'stage_id' = ?", e.payload, ^stage_id)
               )
             )
    end

    test "refuses a stage of the SAME task that is not running", %{
      task: task,
      plan: plan,
      stage: stage
    } do
      {:ok, _} = Tasks.transition_stage(stage, "passed")

      {:ok, other} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "review",
          description: "Review it"
        })

      {:ok, _} = Tasks.transition_stage(other, "running")

      {:error, err} = ack_with_stage(task.id, stage.id)

      assert err.error =~ "is passed, not running"
      assert err.error =~ stage.id
      assert err.recoverable == true
      assert err.suggestion =~ "omit stage_id"

      refute_suppression_armed(task.id, stage.id)
    end

    test "refuses a RUNNING stage belonging to a DIFFERENT task", %{
      project: project,
      task: task
    } do
      {:ok, other_task} =
        Tasks.create_task(%{project_id: project.id, title: "Sibling task"})

      {:ok, other_plan} =
        Tasks.create_plan(%{task_id: other_task.id, status: "approved", version: 1})

      {:ok, other_stage} =
        Tasks.create_stage(%{
          plan_id: other_plan.id,
          position: 1,
          name: "coding",
          description: "Sibling work"
        })

      {:ok, other_stage} = Tasks.transition_stage(other_stage, "running")

      {:error, err} = ack_with_stage(task.id, other_stage.id)

      assert err.error =~ "belongs to task_id=#{other_task.id}"
      assert err.error =~ "not task_id=#{task.id}"
      assert err.recoverable == true

      refute_suppression_armed(task.id, other_stage.id)

      # And the sibling's own key is untouched — the event is written under
      # the CALLER's task_id, so this is the bound on the vector, not a
      # cross-task defence.
      refute_suppression_armed(other_task.id, other_stage.id)
    end

    test "refuses a well-formed UUID that names no stage", %{task: task} do
      ghost = Ecto.UUID.generate()

      {:error, err} = ack_with_stage(task.id, ghost)

      assert err.error =~ "does not exist"
      assert err.error =~ ghost
      assert err.recoverable == true

      refute_suppression_armed(task.id, ghost)
    end

    test "refuses a stage_id that is not a UUID at all", %{task: task} do
      {:error, err} = ack_with_stage(task.id, "not-a-uuid")

      assert err.error =~ "does not exist"
      refute_suppression_armed(task.id, "not-a-uuid")
    end
  end
end

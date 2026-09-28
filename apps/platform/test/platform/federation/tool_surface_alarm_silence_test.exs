defmodule Platform.Federation.ToolSurfaceAlarmSilenceTest do
  @moduledoc """
  Coverage for the `alarm_silence` MCP tool (task 019f6791-c01b stage 3).

  Exercises the tool through `Platform.Federation.ToolSurface.execute/3`
  and asserts on:

    * the return envelope (`task_id`, `stage_id`, `silenced_until`, `reason`),
    * the LeaseManager row (`silenced_until` populated),
    * the persisted `execution.alarm_silenced` runtime_event row + payload,
    * a `[:platform, :orchestration, :alarm_silence]` telemetry event fired,
    * bundle exposure via `list_tools([\"task\"])`,
    * error envelopes for missing/invalid task_id, until_seconds outside
      60..86_400, short reason, no active lease, no running stage.

  async: false — LeaseManager is a global singleton; parallel tests would
  trample each other's lease rows.
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
        name: "Alarm-silence test project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/alarm-silence"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Alarm-silence test task",
        description: "Exercises alarm_silence",
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
    test "alarm_silence appears in list_tools([\"task\"]) with the 6-component rubric" do
      tools = ToolSurface.list_tools(["task"])
      alarm_silence = Enum.find(tools, &(&1.name == "alarm_silence"))

      assert alarm_silence, "alarm_silence must be registered in the task bundle"
      assert alarm_silence.bundle == "task"

      for key <- [:name, :description, :parameters, :returns, :limitations, :when_to_use] do
        assert Map.has_key?(alarm_silence, key), "alarm_silence missing #{key}"
      end

      assert alarm_silence.parameters.task_id.required == true
      assert alarm_silence.parameters.stage_id.required == false
      assert alarm_silence.parameters.until_seconds.required == true
      assert alarm_silence.parameters.reason.required == true
    end
  end

  describe "execute/3 happy path" do
    test "silences the lease, persists runtime_event, emits telemetry", %{
      task: task,
      stage: stage
    } do
      dispatched_at = DateTime.utc_now() |> DateTime.add(-30, :second)

      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          dispatched_at,
          "runtime-alarm-silence-owner"
        )

      test_pid = self()
      handler_id = "alarm-silence-happy-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :orchestration, :alarm_silence],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_fired, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      before = DateTime.utc_now()

      {:ok, result} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "until_seconds" => 1800,
            "reason" => "task_ack absent from stale MCP catalog; subagent live"
          },
          %{runtime_id: "runtime-test-#{System.unique_integer([:positive])}"}
        )

      after_ = DateTime.utc_now()

      # Envelope shape
      assert result.task_id == task.id
      assert result.stage_id == stage.id
      assert %DateTime{} = result.silenced_until
      assert result.reason == "task_ack absent from stale MCP catalog; subagent live"

      # silenced_until ≈ now + 1800s (within a small tolerance)
      assert DateTime.diff(result.silenced_until, before, :second) >= 1799
      assert DateTime.diff(result.silenced_until, after_, :second) <= 1801

      # LeaseManager row reflects the silence
      lease = LeaseManager.get(task.id)
      assert %DateTime{} = lease.silenced_until
      assert DateTime.compare(lease.silenced_until, result.silenced_until) == :eq
      # Silence is orthogonal to ack — no_ack_fired? stays false
      assert lease.no_ack_fired? == false

      # runtime_event persisted with correct payload
      events =
        RuntimeEvent
        |> where(
          [e],
          e.task_id == ^task.id and e.event_type == "execution.alarm_silenced"
        )
        |> Repo.all()

      assert length(events) == 1
      [event] = events
      assert event.payload["stage_id"] == stage.id
      assert event.payload["reason"] == "task_ack absent from stale MCP catalog; subagent live"

      assert event.payload["silenced_until"] ==
               DateTime.to_iso8601(result.silenced_until)

      # Telemetry fired with the expected metadata
      assert_receive {:telemetry_fired, [:platform, :orchestration, :alarm_silence], %{count: 1},
                      meta},
                     500

      assert meta.task_id == task.id
      assert meta.stage_id == stage.id
      assert meta.reason == "task_ack absent from stale MCP catalog; subagent live"
      # silenced_until is ISO-8601 in the telemetry metadata (see
      # tool_surface.ex — the audit bridge's ensure_json_safe/1 chokes
      # on raw %DateTime{} structs, so the emitter serialises to string).
      assert is_binary(meta.silenced_until)
      assert meta.silenced_until == DateTime.to_iso8601(result.silenced_until)
    end

    test "resolves stage_id from current_running_stage when arg is omitted",
         %{task: task, stage: stage} do
      dispatched_at = DateTime.utc_now() |> DateTime.add(-5, :second)

      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          dispatched_at,
          "runtime-alarm-silence-owner"
        )

      {:ok, result} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => task.id,
            "until_seconds" => 600,
            "reason" => "stage_id resolution via current_running_stage"
          },
          %{}
        )

      assert result.stage_id == stage.id
    end
  end

  describe "execute/3 error envelopes" do
    test "missing task_id" do
      {:error, err} =
        ToolSurface.execute(
          "alarm_silence",
          %{"until_seconds" => 600, "reason" => "no task id supplied"},
          %{}
        )

      assert err.error =~ "task_id is required"
      assert err.recoverable == true
    end

    test "unknown task_id" do
      {:error, err} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => Ecto.UUID.generate(),
            "until_seconds" => 600,
            "reason" => "unknown task id"
          },
          %{}
        )

      assert err.error =~ "Task not found"
      assert err.recoverable == false
    end

    test "until_seconds below the 60s floor", %{task: task, stage: stage} do
      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          DateTime.utc_now(),
          "runtime-alarm-silence-owner"
        )

      {:error, err} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "until_seconds" => 30,
            "reason" => "below the minute floor"
          },
          %{}
        )

      assert err.error =~ "60..86_400"
      assert err.recoverable == true
    end

    test "until_seconds above the 24h cap", %{task: task, stage: stage} do
      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          DateTime.utc_now(),
          "runtime-alarm-silence-owner"
        )

      {:error, err} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "until_seconds" => 86_401,
            "reason" => "above the day cap"
          },
          %{}
        )

      assert err.error =~ "60..86_400"
      assert err.recoverable == true
    end

    test "reason shorter than 8 characters", %{task: task, stage: stage} do
      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          DateTime.utc_now(),
          "runtime-alarm-silence-owner"
        )

      {:error, err} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "until_seconds" => 600,
            "reason" => "short"
          },
          %{}
        )

      assert err.error =~ "at least 8"
      assert err.recoverable == true
    end

    test "no active lease returns recoverable :not_found envelope",
         %{task: task, stage: stage} do
      # Deliberately do NOT record_dispatch — simulates the boot race
      # where the caller runs before the router has armed liveness.
      :ok = LeaseManager.clear(task.id)
      assert LeaseManager.get(task.id) == nil

      {:error, err} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "until_seconds" => 600,
            "reason" => "no active lease yet"
          },
          %{}
        )

      assert err.error =~ "No active lease"
      assert err.recoverable == true
      assert err.suggestion =~ "retry"
    end

    test "no running stage when stage_id omitted", %{project: project} do
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
          "alarm_silence",
          %{
            "task_id" => task2.id,
            "until_seconds" => 600,
            "reason" => "cannot resolve stage_id"
          },
          %{}
        )

      assert err.error =~ "no running stage"
      assert err.recoverable == true
      assert err.suggestion =~ "stage_id"
    end

    # 019f9b61 stage 1: the real planning case — the task has NO plan row.
    test "no running stage when the task has no plan at all (planning)", %{project: project} do
      {:ok, planning_task} =
        Tasks.create_task(%{project_id: project.id, title: "Task still in planning"})

      assert Tasks.current_plan(planning_task.id) == nil

      {:error, err} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => planning_task.id,
            "until_seconds" => 600,
            "reason" => "planning has no stage"
          },
          %{}
        )

      assert err.error =~ "no running stage"
      assert err.recoverable == true
    end

    # Positive control: a RUNNING stage under a pending_review plan still
    # refuses — the approved-only `current_plan/1` filter drives the refusal.
    test "no running stage when the only running stage belongs to a pending_review plan",
         %{project: project} do
      {:ok, review_task} =
        Tasks.create_task(%{project_id: project.id, title: "Task with unapproved plan"})

      {:ok, review_plan} =
        Tasks.create_plan(%{task_id: review_task.id, status: "pending_review", version: 1})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: review_plan.id,
          position: 1,
          name: "coding",
          description: "running under an unapproved plan"
        })

      {:ok, stage} = Tasks.transition_stage(stage, "running")
      assert stage.status == "running"

      {:error, err} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => review_task.id,
            "until_seconds" => 600,
            "reason" => "unapproved plan has no stage"
          },
          %{}
        )

      assert err.error =~ "no running stage"
      assert err.recoverable == true
    end
  end

  # Task 01a0a633 stage 2 — the supplied-stage_id guard added to
  # `resolve_ack_stage_id/2` in stage 1 fans out to alarm_silence, which
  # calls the same resolver. Before the `else` clause carried the new
  # atom/tuple errors, each of these raised `WithClauseError` out of the
  # tool boundary instead of returning a refusal envelope. A raise is
  # indistinguishable from a broken tool; these pin the crash-to-envelope
  # transition. Silencing an alarm on a stage you do not own, or one that
  # is not running, suppresses the wrong lease exactly as a misdirected
  # ack does, so the refusal is desired here, not incidental.
  describe "execute/3 supplied stage_id refusals" do
    test "a non-running stage of the SAME task is refused, not silenced", %{
      task: task,
      plan: plan,
      stage: stage
    } do
      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          DateTime.utc_now(),
          "runtime-alarm-silence-owner"
        )

      {:ok, done_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "already_finished",
          description: "completed stage of the same task"
        })

      {:ok, done_stage} = Tasks.transition_stage(done_stage, "running")
      {:ok, done_stage} = Tasks.transition_stage(done_stage, "passed")

      assert {:error, err} =
               ToolSurface.execute(
                 "alarm_silence",
                 %{
                   "task_id" => task.id,
                   "stage_id" => done_stage.id,
                   "until_seconds" => 600,
                   "reason" => "misdirected silence probe"
                 },
                 %{}
               )

      assert is_map(err)
      assert err.recoverable == true
      assert err.error =~ done_stage.id
      assert err.error =~ "not running"

      refute_silenced(task.id)
      refute_alarm_event(done_stage.id)
    end

    test "a RUNNING stage of a DIFFERENT task is refused", %{
      project: project,
      task: task,
      stage: stage
    } do
      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          DateTime.utc_now(),
          "runtime-alarm-silence-owner"
        )

      {:ok, other_task} =
        Tasks.create_task(%{project_id: project.id, title: "Sibling task"})

      {:ok, other_plan} =
        Tasks.create_plan(%{task_id: other_task.id, status: "approved", version: 1})

      {:ok, other_stage} =
        Tasks.create_stage(%{
          plan_id: other_plan.id,
          position: 1,
          name: "sibling_running",
          description: "running stage owned by another task"
        })

      {:ok, other_stage} = Tasks.transition_stage(other_stage, "running")

      assert {:error, err} =
               ToolSurface.execute(
                 "alarm_silence",
                 %{
                   "task_id" => task.id,
                   "stage_id" => other_stage.id,
                   "until_seconds" => 600,
                   "reason" => "cross-task silence probe"
                 },
                 %{}
               )

      assert is_map(err)
      assert err.recoverable == true
      assert err.error =~ other_stage.id
      assert err.error =~ other_task.id

      refute_silenced(task.id)
      refute_alarm_event(other_stage.id)
    end

    test "a syntactically valid but non-existent stage_id is refused", %{
      task: task,
      stage: stage
    } do
      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          DateTime.utc_now(),
          "runtime-alarm-silence-owner"
        )

      ghost_id = Ecto.UUID.generate()

      assert {:error, err} =
               ToolSurface.execute(
                 "alarm_silence",
                 %{
                   "task_id" => task.id,
                   "stage_id" => ghost_id,
                   "until_seconds" => 600,
                   "reason" => "ghost stage silence probe"
                 },
                 %{}
               )

      assert is_map(err)
      assert err.recoverable == true
      assert err.error =~ ghost_id
      assert err.error =~ "does not exist"

      refute_silenced(task.id)
      refute_alarm_event(ghost_id)
    end

    # The running stage of THIS task still silences — without this control,
    # "refuse everything" would pass the three cases above and break the
    # tool the stage exists to keep working.
    test "the task's own running stage still silences (regression control)", %{
      task: task,
      stage: stage
    } do
      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          DateTime.utc_now(),
          "runtime-alarm-silence-owner"
        )

      assert {:ok, result} =
               ToolSurface.execute(
                 "alarm_silence",
                 %{
                   "task_id" => task.id,
                   "stage_id" => stage.id,
                   "until_seconds" => 600,
                   "reason" => "legitimate silence control"
                 },
                 %{}
               )

      assert result.stage_id == stage.id
      assert %DateTime{} = LeaseManager.get(task.id).silenced_until
    end
  end

  # No lease was silenced by the refused call.
  defp refute_silenced(task_id) do
    case LeaseManager.get(task_id) do
      nil -> :ok
      lease -> assert lease.silenced_until == nil
    end
  end

  # No execution.alarm_silenced runtime_event names the refused stage.
  defp refute_alarm_event(stage_id) do
    rows =
      Repo.all(
        from(e in RuntimeEvent,
          where: e.event_type == "execution.alarm_silenced"
        )
      )

    refute Enum.any?(rows, &(get_in(&1.payload, ["stage_id"]) == stage_id))
  end

  describe "audit bridging" do
    test "successful silence records a platform.orchestration.alarm_silence audit row",
         %{task: task, stage: stage} do
      # Attach the TelemetryHandler explicitly — in some test envs the
      # Application-boot attach hasn't run and the audit bridge would be
      # inert. Restored on exit, because it is VM-global (task 019f9d80).
      Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)

      :ok =
        LeaseManager.record_dispatch(
          task.id,
          stage.id,
          "coding",
          DateTime.utc_now(),
          "runtime-alarm-silence-owner"
        )

      {:ok, _result} =
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "until_seconds" => 600,
            "reason" => "audit bridging verification"
          },
          %{runtime_id: "runtime-audit-#{System.unique_integer([:positive])}"}
        )

      events = Platform.Audit.list(event_type: "platform.orchestration.alarm_silence")

      assert Enum.any?(events, fn e ->
               e.resource_type == "task" and e.resource_id == task.id and
                 e.action == "silence" and e.actor_type == "system"
             end),
             "expected an audit row for the alarm_silence event; got #{inspect(events)}"
    end
  end
end

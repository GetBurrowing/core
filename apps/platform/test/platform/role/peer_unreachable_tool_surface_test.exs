defmodule Platform.Role.PeerUnreachableToolSurfaceTest do
  @moduledoc """
  A web node (`Platform.Role`, task 01a155a6) sends `task_ack` and
  `alarm_silence` lease writes to its cluster peer. When that peer cannot be
  reached, the tools must say so — not report "no active lease", which is a
  claim about the lease the web node never got to check.

  The peer is a node name that does not exist, so the GenServer call exits
  the same way an unreachable real peer does.

  NOT async: it sets the node role and app env, and the LeaseManager is a
  global singleton.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Federation.ToolSurface
  alias Platform.Tasks

  @peer :platform@peer_unreachable_test_nohost

  setup do
    keys = [:role, :cluster_peer]
    previous = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    {:ok, project} =
      Tasks.create_project(%{name: "peer unreachable #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "peer unreachable",
        description: "web role",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build",
        description: "coding",
        status: "running",
        started_at: DateTime.utc_now()
      })

    Application.put_env(:platform, :role, :web)
    Application.put_env(:platform, :cluster_peer, @peer)

    %{task: task, stage: stage}
  end

  test "alarm_silence names the unreachable peer, not a missing lease", %{
    task: task,
    stage: stage
  } do
    {result, _log} =
      with_log(fn ->
        ToolSurface.execute(
          "alarm_silence",
          %{
            "task_id" => task.id,
            "stage_id" => stage.id,
            "until_seconds" => 600,
            "reason" => "executor is working this stage"
          },
          %{}
        )
      end)

    assert {:error, %{error: error, recoverable: true}} = result
    assert error =~ "could not reach its cluster peer"
    refute error =~ "No active lease"
  end

  test "task_ack still writes the durable ack row and logs the unreachable peer", %{
    task: task,
    stage: stage
  } do
    runtime_id = Platform.RuntimeProfileFixtures.ensure_task_runtime!("rt-peer-unreachable")

    {result, log} =
      with_log(fn ->
        ToolSurface.execute(
          "task_ack",
          %{"task_id" => task.id, "stage_id" => stage.id, "subagent_id" => "sub-1"},
          %{runtime_id: runtime_id}
        )
      end)

    assert {:ok, %{task_id: task_id, event_id: event_id}} = result
    assert task_id == task.id
    assert is_binary(event_id)
    assert log =~ "returned :peer_unreachable"
    refute log =~ "returned :not_found"
  end
end

defmodule Platform.Execution.RunServerTest do
  @moduledoc """
  Tests for Platform.Execution.RunServer:
    - Context session open on start
    - Status transitions
    - Ack tracking
    - Stale trigger on SLA miss
    - Dead trigger after stale
    - Context eviction on terminal state
  """
  use ExUnit.Case, async: false

  alias Platform.Context
  alias Platform.Execution.{ContextSession, Run, RunServer, RunSupervisor}

  # Start a run with very short SLA timers for stale tests
  defp start_run(task_id, opts \\ []) do
    run_id = "run-#{System.unique_integer([:positive, :monotonic])}"
    run = Run.new(run_id, task_id, opts)

    {:ok, _pid} = RunSupervisor.start_run(run, opts)
    run
  end

  defp unique_task, do: "task-#{System.unique_integer([:positive, :monotonic])}"

  # ---------------------------------------------------------------------------
  # Basic lifecycle
  # ---------------------------------------------------------------------------

  describe "start and context session" do
    test "opens a context session when started" do
      task_id = unique_task()
      run = start_run(task_id)

      # Session should exist in cache
      scope_key = Run.context_scope_key(run)
      assert {:ok, _session} = Context.get_session(%{task_id: task_id, run_id: run.id})

      # Snapshot should work
      assert {:ok, snapshot} = RunServer.get_snapshot(run.id)
      assert snapshot.version == 0
      assert snapshot.items == []

      _ = scope_key
    end

    test "get_run returns the run struct" do
      run = start_run(unique_task())
      assert {:ok, %Run{id: id}} = RunServer.get_run(run.id)
      assert id == run.id
    end
  end

  # ---------------------------------------------------------------------------
  # Status transitions
  # ---------------------------------------------------------------------------

  describe "transition/2" do
    test "created -> starting -> running -> completed" do
      run = start_run(unique_task())

      assert {:ok, %Run{status: :starting}} = RunServer.transition(run.id, :starting)
      assert {:ok, %Run{status: :running}} = RunServer.transition(run.id, :running)
      assert {:ok, %Run{status: :completed}} = RunServer.transition(run.id, :completed)
    end

    test "created -> cancelled is valid" do
      run = start_run(unique_task())
      assert {:ok, %Run{status: :cancelled}} = RunServer.transition(run.id, :cancelled)
    end

    test "invalid transition returns error" do
      run = start_run(unique_task())

      assert {:error, {:invalid_transition, :created, :completed}} =
               RunServer.transition(run.id, :completed)
    end

    test "context session evicted on terminal transition" do
      run = start_run(unique_task())
      RunServer.transition(run.id, :starting)
      RunServer.transition(run.id, :running)
      RunServer.transition(run.id, :completed)

      # After eviction, the run-scoped session should be gone
      # (wait a moment for the synchronous eviction)
      assert {:error, :not_found} =
               Context.get_session(%{task_id: run.task_id, run_id: run.id})
    end
  end

  # ---------------------------------------------------------------------------
  # Push and snapshot
  # ---------------------------------------------------------------------------

  describe "push_context/3 and get_snapshot/1" do
    test "pushed items appear in snapshot" do
      run = start_run(unique_task())

      {:ok, version} = RunServer.push_context(run.id, %{"env" => "production", "model" => "gpt"})

      assert version == 1

      {:ok, snapshot} = RunServer.get_snapshot(run.id)
      assert snapshot.version == 1
      keys = Enum.map(snapshot.items, & &1.key)
      assert "env" in keys
      assert "model" in keys
    end

    test "successive pushes accumulate items" do
      run = start_run(unique_task())

      RunServer.push_context(run.id, %{"a" => 1})
      RunServer.push_context(run.id, %{"b" => 2})

      {:ok, snapshot} = RunServer.get_snapshot(run.id)
      keys = Enum.map(snapshot.items, & &1.key)
      assert "a" in keys
      assert "b" in keys
    end
  end

  # ---------------------------------------------------------------------------
  # Acknowledgement
  # ---------------------------------------------------------------------------

  describe "ack_context/2" do
    test "recording ack updates run struct" do
      run = start_run(unique_task())
      RunServer.push_context(run.id, %{"x" => 1})

      {:ok, %Run{ctx_acked_version: acked}} = RunServer.ack_context(run.id, 1)
      assert acked == 1
    end

    test "ack with version >= required marks context current" do
      run = start_run(unique_task())
      RunServer.push_context(run.id, %{"k" => "v"})

      {:ok, updated} = RunServer.ack_context(run.id, 1)
      assert updated.ctx_status == :current
    end
  end

  # ---------------------------------------------------------------------------
  # Stale and dead transitions via SLA timers
  # ---------------------------------------------------------------------------

  describe "stale trigger" do
    @tag :slow
    test "marks run stale when ack SLA is missed" do
      task_id = unique_task()
      run = start_run(task_id, stale_timeout_ms: 50, dead_timeout_ms: 5_000)

      # Push a delta (triggers required_version bump + stale timer)
      RunServer.push_context(run.id, %{"trigger" => "stale"})

      # Wait slightly longer than the stale timeout
      Process.sleep(150)

      {:ok, current_run} = RunServer.get_run(run.id)
      assert current_run.ctx_status == :stale
    end

    @tag :slow
    test "ack before timeout keeps context current" do
      task_id = unique_task()
      run = start_run(task_id, stale_timeout_ms: 200, dead_timeout_ms: 5_000)

      RunServer.push_context(run.id, %{"trigger" => "ack_test"})
      # Ack immediately
      RunServer.ack_context(run.id, 1)

      # Wait longer than stale_timeout
      Process.sleep(300)

      {:ok, current_run} = RunServer.get_run(run.id)
      assert current_run.ctx_status == :current
    end
  end

  describe "dead trigger" do
    @tag :slow
    test "marks run dead after stale + dead timeout" do
      task_id = unique_task()
      run = start_run(task_id, stale_timeout_ms: 30, dead_timeout_ms: 60)

      RunServer.push_context(run.id, %{"trigger" => "dead"})

      # Wait for stale (30ms) + dead (60ms) + buffer
      Process.sleep(200)

      {:ok, current_run} = RunServer.get_run(run.id)
      assert current_run.ctx_status == :dead
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub status events
  # ---------------------------------------------------------------------------

  describe "ctx status PubSub events" do
    @tag :slow
    test "broadcasts run_ctx_status_changed on stale" do
      task_id = unique_task()
      Phoenix.PubSub.subscribe(Platform.PubSub, "execution:runs:#{task_id}")

      run = start_run(task_id, stale_timeout_ms: 40, dead_timeout_ms: 5_000)
      RunServer.push_context(run.id, %{"k" => "v"})

      assert_receive {:run_ctx_status_changed, run_id, :stale}, 300
      assert run_id == run.id
    end
  end
end

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

  import ExUnit.CaptureLog

  alias Platform.Context
  alias Platform.Execution.{ContextSession, Run, RunServer, RunSupervisor}

  defmodule StubRunner do
    @moduledoc false
    # Records every spawn_run/2 call to the pid passed as `:test_pid` and
    # never starts a process: exits are delivered by the test itself as
    # `{:runner_exited, run_id, %{exit_code: _, exit_state: _}}`.
    @behaviour Platform.Execution.Runner

    @impl true
    def spawn_run(run, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:spawn_run, run.id, run.status})
      {:ok, %{stub: true}}
    end

    @impl true
    def request_stop(_run, _opts), do: :ok

    @impl true
    def force_stop(_run, _opts), do: :ok

    @impl true
    def describe_run(_run, _opts), do: {:ok, %{}}

    @impl true
    def push_context(_run, _context, _opts), do: :ok
  end

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
    test "marks run pending before ack SLA and stale after it is missed" do
      task_id = unique_task()
      run = start_run(task_id, stale_timeout_ms: 50, dead_timeout_ms: 5_000)

      # Push a delta (triggers required_version bump + stale timer)
      RunServer.push_context(run.id, %{"trigger" => "stale"})

      Process.sleep(10)

      {:ok, pending_run} = RunServer.get_run(run.id)
      assert pending_run.ctx_status == :pending

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
    test "broadcasts ctx status changes for pending, current, and stale" do
      task_id = unique_task()
      Phoenix.PubSub.subscribe(Platform.PubSub, "execution:runs:#{task_id}")

      run = start_run(task_id, stale_timeout_ms: 40, dead_timeout_ms: 5_000)
      RunServer.push_context(run.id, %{"k" => "v"})

      assert_receive {:run_ctx_status_changed, run_id, :pending}, 300
      assert run_id == run.id

      RunServer.ack_context(run.id, 1)
      assert_receive {:run_ctx_status_changed, ^run_id, :current}, 300

      RunServer.push_context(run.id, %{"k2" => "v2"})
      assert_receive {:run_ctx_status_changed, ^run_id, :pending}, 300
      assert_receive {:run_ctx_status_changed, ^run_id, :stale}, 300
    end
  end

  # ---------------------------------------------------------------------------
  # Provider spawn and runner exits go through the state machine
  # ---------------------------------------------------------------------------

  defp spawn_stub(run_id) do
    RunServer.spawn_provider(run_id, StubRunner, test_pid: self())
  end

  # `send/2` then a `GenServer.call/2` from the same process: the call is
  # queued behind the exit message, so the reply reflects the handled exit.
  defp deliver_exit(run_id, exit_code, exit_state) do
    [{pid, _}] = Registry.lookup(Platform.Execution.Registry, {:run_server, run_id})
    send(pid, {:runner_exited, run_id, %{exit_code: exit_code, exit_state: exit_state}})
    {:ok, run} = RunServer.get_run(run_id)
    run
  end

  defp to_running(run_id) do
    {:ok, _} = RunServer.transition(run_id, :starting)
    {:ok, %Run{status: :running}} = RunServer.transition(run_id, :running)
  end

  describe "spawn_provider/3" do
    test "a :created run spawns and moves to :starting" do
      run = start_run(unique_task())
      run_id = run.id

      assert {:ok, %Run{status: :starting, runner_ref: %{stub: true}}} = spawn_stub(run_id)
      assert_received {:spawn_run, ^run_id, :created}
    end

    test "a :running run spawns and stays :running (no demotion)" do
      run = start_run(unique_task())
      run_id = run.id
      to_running(run_id)

      assert {:ok, %Run{status: :running, runner_ref: %{stub: true}}} = spawn_stub(run_id)
      assert_received {:spawn_run, ^run_id, :running}
      assert {:ok, %Run{status: :running}} = RunServer.get_run(run_id)
    end

    test "a terminal run is refused and the provider is never spawned" do
      run = start_run(unique_task())
      run_id = run.id
      {:ok, %Run{status: :cancelled}} = RunServer.transition(run_id, :cancelled)

      assert {:error, {:invalid_transition, :cancelled, :starting}} = spawn_stub(run_id)
      refute_received {:spawn_run, ^run_id, _}
      assert {:ok, %Run{status: :cancelled, runner_ref: runner_ref}} = RunServer.get_run(run_id)
      assert runner_ref == run.runner_ref
    end
  end

  describe "runner exits" do
    test ":running + :completed exit records :completed" do
      run = start_run(unique_task())
      to_running(run.id)

      exited = deliver_exit(run.id, 0, :completed)

      assert exited.status == :completed
      assert exited.exit_code == 0
      assert %DateTime{} = exited.finished_at
    end

    test ":starting + :completed exit records :failed, logs an error and emits telemetry" do
      run = start_run(unique_task())
      run_id = run.id
      {:ok, %Run{status: :starting}} = RunServer.transition(run_id, :starting)

      test_pid = self()
      handler_id = "run-server-invalid-exit-#{run_id}"

      :telemetry.attach(
        handler_id,
        [:platform, :execution, :run, :invalid_exit_transition],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {exited, log} = with_log(fn -> deliver_exit(run_id, 0, :completed) end)

      assert exited.status == :failed
      assert exited.exit_code == 0
      assert %DateTime{} = exited.finished_at

      assert log =~ run_id
      assert log =~ "invalid runner-exit transition starting → completed"

      assert_received {:telemetry, [:platform, :execution, :run, :invalid_exit_transition],
                       %{count: 1}, %{run_id: ^run_id, from: :starting, to: :completed}}
    end

    test ":cancelled + :killed exit keeps :cancelled and the first finished_at" do
      run = start_run(unique_task())
      to_running(run.id)

      {:ok, %Run{status: :cancelled, finished_at: finished_at}} =
        RunServer.transition(run.id, :cancelled)

      exited = deliver_exit(run.id, 137, :killed)

      assert exited.status == :cancelled
      assert exited.finished_at == finished_at
      assert exited.exit_code == 137
    end
  end
end

defmodule Platform.Execution.RunServerTest do
  use ExUnit.Case, async: true

  alias Platform.Execution
  alias Platform.Execution.{ContextSession, Run, RunServer}

  defmodule FakeRunner do
    @behaviour Platform.Execution.Runner

    alias Platform.Execution.{ContextSession, Run}

    @impl true
    def spawn_run(%Run{} = run, opts) do
      notify(run, {:spawn_run, run.id, opts})
      {:ok, %{provider: :fake, run_id: run.id}}
    end

    @impl true
    def request_stop(%Run{} = run, opts) do
      notify(run, {:request_stop, run.id, opts})
      :ok
    end

    @impl true
    def force_stop(%Run{} = run, opts) do
      notify(run, {:force_stop, run.id, opts})
      :ok
    end

    @impl true
    def describe_run(%Run{} = run, opts) do
      notify(run, {:describe_run, run.id, opts})
      {:ok, %{provider: :fake, run_id: run.id}}
    end

    @impl true
    def push_context(%Run{} = run, %ContextSession{} = session, opts) do
      notify(run, {:push_context, run.id, session.required_version, opts})
      :ok
    end

    defp notify(%Run{} = run, message) do
      if pid = run.metadata[:test_pid] do
        send(pid, message)
      end

      :ok
    end
  end

  describe "public API" do
    test "spawn_run/3 boots a provider-backed run server and describe_run/1 returns its state" do
      run_id = unique_run_id()

      assert {:ok, pid} =
               Execution.spawn_run(
                 %{id: run_id, metadata: %{test_pid: self()}, kill_grace_ms: 25},
                 FakeRunner
               )

      on_exit(fn ->
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal)
        end
      end)

      assert_receive {:spawn_run, ^run_id, opts}
      assert Keyword.get(opts, :spawn?) == true
      assert Execution.get_run_server(run_id) == pid
      assert {:ok, run} = Execution.describe_run(run_id)
      assert run.id == run_id
      assert run.state == :starting
      assert run.runner_ref == %{provider: :fake, run_id: run_id}
    end
  end

  describe "Run.classify/2" do
    test "classifies stale and dead runs deterministically" do
      now = DateTime.utc_now()

      {:ok, stale_progress} =
        Run.new(%{
          id: unique_run_id(),
          state: :running,
          last_heartbeat_at: now,
          last_progress_at: DateTime.add(now, -2, :second),
          progress_timeout_ms: 500,
          heartbeat_timeout_ms: 5_000,
          context_ack_timeout_ms: 5_000
        })

      {:ok, dead_heartbeat} =
        Run.new(%{
          id: unique_run_id(),
          state: :running,
          last_heartbeat_at: DateTime.add(now, -2, :second),
          last_progress_at: now,
          heartbeat_timeout_ms: 500,
          progress_timeout_ms: 5_000,
          context_ack_timeout_ms: 5_000
        })

      {:ok, stale_context_ack} =
        Run.new(%{
          id: unique_run_id(),
          state: :running,
          last_heartbeat_at: now,
          last_progress_at: now,
          required_context_version: 2,
          acknowledged_context_version: 1,
          context_requested_at: DateTime.add(now, -2, :second),
          heartbeat_timeout_ms: 5_000,
          progress_timeout_ms: 5_000,
          context_ack_timeout_ms: 500
        })

      assert Run.classify(stale_progress, now) == :stale
      assert Run.classify(dead_heartbeat, now) == :dead
      assert Run.classify(stale_context_ack, now) == :stale
    end
  end

  describe "RunServer liveness transitions" do
    test "marks a run stale on progress timeout and resumes it on checkpoint" do
      now = DateTime.utc_now()

      pid =
        start_run_server!(%{
          state: :running,
          last_heartbeat_at: now,
          last_progress_at: DateTime.add(now, -1, :second),
          heartbeat_timeout_ms: 1_000,
          progress_timeout_ms: 50,
          context_ack_timeout_ms: 1_000,
          liveness_interval_ms: 10
        })

      assert_eventually(fn -> RunServer.status(pid).state == :stale end)

      assert {:ok, run} = RunServer.checkpoint(pid, "working")
      assert run.state == :running
      assert run.phase == "working"
    end

    test "marks a run stale when context ack is missing and clears it on ack" do
      now = DateTime.utc_now()

      pid =
        start_run_server!(
          last_heartbeat_at: now,
          last_progress_at: now,
          context_ack_timeout_ms: 50
        )

      run_id = RunServer.status(pid).id

      assert {:ok, pushed_run} =
               RunServer.push_context(pid, %{
                 run_id: run_id,
                 required_version: 1,
                 issued_at: now,
                 snapshot: %{instructions: ["ship it"]}
               })

      assert pushed_run.required_context_version == 1
      assert pushed_run.context_requested_at
      assert_receive {:push_context, ^run_id, 1, []}

      assert_eventually(fn -> RunServer.status(pid).state == :stale end)

      assert {:ok, run} = RunServer.ack_context_version(pid, 1)
      assert run.state == :running
      assert run.acknowledged_context_version == 1
      assert run.context_requested_at == nil
    end

    test "marks a run dead when heartbeats stop arriving" do
      now = DateTime.utc_now()

      pid =
        start_run_server!(%{
          state: :running,
          last_heartbeat_at: DateTime.add(now, -1, :second),
          last_progress_at: now,
          heartbeat_timeout_ms: 50,
          progress_timeout_ms: 1_000,
          context_ack_timeout_ms: 1_000,
          liveness_interval_ms: 10
        })

      assert_eventually(fn -> RunServer.status(pid).state == :dead end)
    end
  end

  describe "RunServer stop escalation" do
    test "requests a graceful stop, escalates to force stop, then marks the run dead if no exit arrives" do
      now = DateTime.utc_now()

      pid =
        start_run_server!(%{
          state: :running,
          last_heartbeat_at: now,
          last_progress_at: now,
          heartbeat_timeout_ms: 1_000,
          progress_timeout_ms: 1_000,
          context_ack_timeout_ms: 1_000,
          kill_grace_ms: 20,
          liveness_interval_ms: 10,
          kill_confirm_timeout_ms: 20
        })

      run_id = RunServer.status(pid).id

      assert {:ok, run} = RunServer.request_stop(pid, :cancelled)
      assert run.state == :stopping
      assert run.stop_reason == "cancelled"
      assert_receive {:request_stop, ^run_id, [reason: :cancelled]}

      assert_receive {:force_stop, ^run_id, [reason: "cancelled"]}, 200
      assert_eventually(fn -> RunServer.status(pid).state == :kill_requested end)
      assert_eventually(fn -> RunServer.status(pid).state == :dead end)
    end
  end

  defp start_run_server!(attrs) do
    run_id = unique_run_id()

    run =
      %{
        id: run_id,
        state: :running,
        heartbeat_timeout_ms: 1_000,
        progress_timeout_ms: 1_000,
        context_ack_timeout_ms: 1_000,
        kill_grace_ms: 25,
        metadata: %{test_pid: self()}
      }
      |> Map.merge(Enum.into(attrs, %{}))

    opts = [
      run: run,
      runner: FakeRunner,
      liveness_interval_ms: Map.get(run, :liveness_interval_ms, 10),
      kill_confirm_timeout_ms: Map.get(run, :kill_confirm_timeout_ms, 25)
    ]

    start_supervised!({RunServer, opts})
  end

  defp unique_run_id do
    "run-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp assert_eventually(fun, timeout \\ 300) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    if fun.() do
      assert true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
      else
        flunk("condition was not met before timeout")
      end
    end
  end
end

defmodule Platform.Orchestration.SandboxGuardTest do
  @moduledoc """
  Unit tests for the sandbox-ownership primitive.

  Every test here drives the unowned-connection path **deliberately** — by
  constructing a process with no sandbox ownership, or a second independently
  owned connection — rather than hoping to catch it by scheduling luck. A
  guard whose test can only observe "nothing bad happened" passes vacuously
  when the trigger never arrives, which is the exact failure mode the
  primitive exists to end.
  """

  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Orchestration.SandboxGuard
  alias Platform.Repo
  alias Platform.Tasks.Project

  # `Platform.DataCase` gives every `async: false` module a SHARED sandbox
  # connection, and shared mode makes each process WITHOUT explicit ownership
  # fall back to the test's connection. Under it, an unowned process — the
  # exact thing these tests must construct — cannot exist, and every
  # assertion here would go green for the wrong reason. So this module runs
  # in `:manual` mode instead, with its own explicit checkout.
  #
  # Two consequences worth knowing before editing this file:
  #
  #   * Switching the mode CHECKS THE SHARED CONNECTION BACK IN, rolling back
  #     anything written on it. That is why the switch happens here in
  #     `setup`, ahead of every fixture, and never inline in a test body.
  #   * It stays `async: false` deliberately. Manual mode is what async
  #     modules get, but marking this one `async: true` would add another
  #     concurrent `DataCase` competing for the singleton `Sandbox.allow/3`
  #     bindings — a small push on the very race this task exists to remove.
  #     Sequential + manual gets the isolation without the contribution.
  setup do
    Sandbox.mode(Repo, :manual)
    :ok = Sandbox.checkout(Repo)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    handler_id = "sandbox-guard-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        SandboxGuard.dropped_event(),
        &__MODULE__.forward_event/4,
        %{pid: self()}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  @doc false
  def forward_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:sandbox_guard_dropped, event, measurements, metadata})
  end

  # ── guarded/3 ──────────────────────────────────────────────────────────

  describe "guarded/3" do
    test "returns the function's value and emits nothing when it succeeds" do
      assert SandboxGuard.guarded(fn -> :computed end, :fallback) == :computed
      refute_receive {:sandbox_guard_dropped, _, _, _}, 50
    end

    test "degrades to the fallback and reports :ownership_error from an unowned process" do
      result =
        in_unowned_process(fn ->
          SandboxGuard.guarded(fn -> Repo.exists?(Project) end, :dropped)
        end)

      assert result == :dropped

      assert_receive {:sandbox_guard_dropped,
                      [:platform, :orchestration, :sandbox_guard, :dropped], %{count: 1},
                      metadata}

      assert metadata.reason == :ownership_error
      assert metadata.exit_reason == nil

      # Attribution comes from the closure itself (`Function.info(fun,
      # :module)`), so a call site cannot forget to pass it and mis-report.
      assert metadata.caller == __MODULE__
    end

    test "degrades to the fallback and reports :owner_exited on the exit shape" do
      # The "owner exited" failure arrives as an EXIT carrying a
      # DBConnection.ConnectionError, which `rescue` cannot see. Driving the
      # exit directly makes the clause deterministic; the stopped-owner test
      # below covers the same clause reached through a real teardown.
      teardown = %DBConnection.ConnectionError{message: "owner #PID<0.999.0> exited"}

      assert SandboxGuard.guarded(fn -> exit(teardown) end, :dropped) == :dropped

      assert_receive {:sandbox_guard_dropped, _event, %{count: 1}, metadata}
      assert metadata.reason == :owner_exited
      assert %DBConnection.ConnectionError{} = metadata.exit_reason
      assert metadata.caller == __MODULE__
    end

    test "degrades when the connection's owner has been stopped out from under it" do
      # Real teardown, no synthetic exit: a worker allowed onto a second
      # owner's connection, then that owner checked in before the query runs.
      # Which of the two clauses catches it is a DBConnection implementation
      # detail; that it degrades and reports is the contract.
      owner = start_owner_worker!()
      worker = start_worker!()
      :ok = Sandbox.allow(Repo, owner, worker)

      # Synchronous — the manager has released the connection and every
      # allowance derived from it by the time this returns. No sleep, no race.
      :ok = run_in(owner, fn -> Sandbox.checkin(Repo) end)

      result =
        run_in(worker, fn ->
          SandboxGuard.guarded(fn -> Repo.exists?(Project) end, :dropped)
        end)

      assert result == :dropped

      assert_receive {:sandbox_guard_dropped, _event, %{count: 1}, metadata}
      assert metadata.reason in [:ownership_error, :owner_exited]
    end

    test "does NOT swallow non-sandbox exceptions" do
      # A blanket `try` would turn every bug inside a guarded block into a
      # silent fallback. Only the two sandbox shapes are caught.
      assert_raise ArgumentError, "not a sandbox problem", fn ->
        SandboxGuard.guarded(fn -> raise ArgumentError, "not a sandbox problem" end, :dropped)
      end

      refute_receive {:sandbox_guard_dropped, _, _, _}, 50
    end

    test "honours an explicit :caller override" do
      assert SandboxGuard.guarded(fn -> exit(:noproc) end, :dropped, caller: SomeOtherModule) ==
               :dropped

      assert_receive {:sandbox_guard_dropped, _event, _measurements, %{caller: SomeOtherModule}}
    end
  end

  # ── connection_owned?/0 ────────────────────────────────────────────────

  describe "connection_owned?/0" do
    test "is true in the owning test process" do
      assert SandboxGuard.connection_owned?() == true
      refute_receive {:sandbox_guard_dropped, _, _, _}, 50
    end

    test "is false in a process with no sandbox ownership" do
      assert in_unowned_process(fn -> SandboxGuard.connection_owned?() end) == false

      assert_receive {:sandbox_guard_dropped, _event, %{count: 1}, metadata}
      assert metadata.reason == :ownership_error
      assert metadata.caller == SandboxGuard
    end
  end

  # ── sandbox_pool?/0 ────────────────────────────────────────────────────

  describe "sandbox_pool?/0" do
    test "is true under MIX_ENV=test" do
      assert SandboxGuard.sandbox_pool?() == true
      assert Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox
    end
  end

  # ── row_visible?/2 ─────────────────────────────────────────────────────

  describe "row_visible?/2" do
    test "is true for a row written on this connection" do
      project = insert_project!()

      assert SandboxGuard.row_visible?(Project, project.id) == true
    end

    test "is false for a row written on a second, independently owned connection" do
      # This is the whole mechanism in one assertion: each sandboxed
      # connection runs inside its own uncommitted transaction, so a row
      # written by another owner is invisible here. A handler that cannot see
      # the row a broadcast is about is being driven by somebody else's
      # connection.
      mine = insert_project!()
      theirs_id = insert_project_on_second_connection!()

      assert SandboxGuard.row_visible?(Project, mine.id) == true
      assert SandboxGuard.row_visible?(Project, theirs_id) == false
    end

    test "is false for an unknown id" do
      assert SandboxGuard.row_visible?(Project, Platform.Types.UUIDv7.generate()) == false
    end

    test "is false for a nil id without touching the Repo" do
      assert SandboxGuard.row_visible?(Project, nil) == false
      refute_receive {:sandbox_guard_dropped, _, _, _}, 50
    end

    test "degrades to false from an unowned process" do
      project = insert_project!()

      assert in_unowned_process(fn -> SandboxGuard.row_visible?(Project, project.id) end) == false

      assert_receive {:sandbox_guard_dropped, _event, %{count: 1}, metadata}
      assert metadata.reason == :ownership_error
      assert metadata.caller == SandboxGuard
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  # Run `fun` in a bare process that owns no sandbox connection. Under the
  # module-level manual mode (see `setup`) this is simply a spawned process:
  # no ownership, no shared fallback, so any Repo call inside raises
  # `DBConnection.OwnershipError` for real rather than by simulation.
  defp in_unowned_process(fun), do: probe(fun)

  # Runs `fun` in a fresh unlinked process and returns its value. A crash is
  # reported as a failure naming the exception, so a guard that stops
  # rescuing fails LOUDLY here rather than returning a wrong value.
  defp probe(fun) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:probe_result, self(), fun.()}) end)

    receive do
      {:probe_result, ^pid, value} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

        value

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("probe process crashed instead of degrading: #{inspect(reason, limit: 5)}")
    after
      2_000 -> flunk("probe process never reported a result")
    end
  end

  # A plain `spawn`, deliberately: `Task`/`Agent` set `$callers`, and the
  # sandbox resolves ownership through that chain — which is why
  # `Sandbox.start_owner!/2` answers `{:already, :owner}` when called from a
  # test that already holds a connection. A bare spawned process has no
  # `$callers`, so it can take out a genuinely independent second connection.
  defp start_worker! do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:worker_ready, self()})
        worker_loop()
      end)

    assert_receive {:worker_ready, ^pid}, 1_000
    pid
  end

  # A worker that owns its own sandbox connection — a second, independent
  # uncommitted transaction alongside the test's.
  defp start_owner_worker! do
    worker = start_worker!()
    :ok = run_in(worker, fn -> Sandbox.checkout(Repo) end)
    worker
  end

  defp worker_loop do
    receive do
      {:run, from, fun} ->
        send(from, {:ran, self(), fun.()})
        worker_loop()

      :stop ->
        :ok
    end
  end

  defp run_in(worker, fun) do
    send(worker, {:run, self(), fun})

    receive do
      {:ran, ^worker, value} -> value
    after
      2_000 -> flunk("worker process never reported a result")
    end
  end

  defp insert_project! do
    Repo.insert!(
      Project.changeset(%Project{}, %{
        name: "SandboxGuard Project #{System.unique_integer([:positive])}",
        org_id: org_id!()
      })
    )
  end

  # Writes a project on a SECOND sandbox connection with its own owner, and
  # returns its id. Uses `Repo.insert!` directly rather than a context
  # function on purpose: context writes broadcast on `tasks:board`, and a
  # broadcast from here would perturb exactly the global state this task is
  # about.
  defp insert_project_on_second_connection! do
    worker = start_owner_worker!()

    on_exit(fn -> send(worker, :stop) end)

    project = run_in(worker, fn -> insert_project!() end)
    project.id
  end

  defp org_id! do
    case Repo.one(from(o in Platform.Tenancy.Org, limit: 1, select: o.id)) do
      nil -> flunk("no org row in the test database — cannot build a Project fixture")
      id -> id
    end
  end
end

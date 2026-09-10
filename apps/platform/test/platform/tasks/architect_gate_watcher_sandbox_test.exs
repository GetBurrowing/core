defmodule Platform.Tasks.ArchitectGateWatcherSandboxTest do
  @moduledoc """
  Ticket 01a06638 — the async watcher must be able to reach the `Repo`.

  ## What is actually being pinned

  `Platform.Tasks.ArchitectGateLifecycleStep.start/2` hands an open gate to a
  watcher running in ANOTHER process, and that watcher reads the gate row on
  every tick. The property under test is that the watcher can perform that
  read at all — i.e. that `Ecto.Adapters.SQL.Sandbox` can resolve an owner for
  a process the test never started.

  It can only do that through `$callers`, which `Task.Supervisor.start_child/2`
  propagates and a bare `spawn/1` does not. That is the whole defect: the
  watcher used to be a bare spawn, so under an `async: true` case its first
  `Repo` call raised `DBConnection.OwnershipError`.

  ## Why the failure was invisible rather than red

  `settled_outcome/1` wraps its read in `rescue` and returns
  `{:failed, :watch_read_raised}`. So the broken watcher did not crash and did
  not time out — **it settled the step with a verdict it had never read**, and
  the caller could not tell that from a real failure. Asserting the settlement
  VALUE, not merely that some settlement arrived, is what separates the two.

  ## Why `async: true` is load-bearing

  This module MUST stay `async: true`. Shared mode makes the sandbox owner
  global, which is exactly the condition under which a bare `spawn/1` finds a
  connection anyway — so an `async: false` version of this test passes against
  the unfixed code and pins nothing. If a future change flips this to
  `async: false`, the test stops discriminating.
  """
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ArchitectGateLifecycleStep
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Task, as: TaskSchema

  setup do
    # Tiny backstop so the watcher re-reads promptly. This is the module's own
    # documented injection point, not a widened timeout: it makes the test
    # FASTER, and the assertions below fail rather than pass if the read never
    # happens.
    before = Application.fetch_env(:platform, :architecture_gate_poll_ms)
    Application.put_env(:platform, :architecture_gate_poll_ms, 10)

    on_exit(fn ->
      case before do
        :error -> Application.delete_env(:platform, :architecture_gate_poll_ms)
        {:ok, v} -> Application.put_env(:platform, :architecture_gate_poll_ms, v)
      end
    end)

    {:ok, project} = Tasks.create_project(%{name: "Gate Watcher Sandbox #{unique()}"})

    task =
      Repo.insert!(%TaskSchema{
        project_id: project.id,
        title: "Watcher subject",
        status: "planning"
      })

    plan = Repo.insert!(%Plan{task_id: task.id, version: 1, status: "pending_review"})
    {:ok, opened} = Tasks.open_architecture_gate(plan)

    %{task: task, plan: opened}
  end

  defp unique, do: System.unique_integer([:positive])

  test "the gate watcher reads the real verdict from its own process", ctx do
    # The gate is OPEN, so `start/2` cannot answer inline and must hand off to
    # the watcher. Asserting `{:running, ref}` is the positive control: without
    # it, everything below is satisfied by a step that answered synchronously
    # and never exercised another process at all.
    assert {:running, ref} =
             ArchitectGateLifecycleStep.start(%{}, %{
               task: ctx.task,
               reply_to: self(),
               step_timeout_ms: 5_000
             })

    # Resolve the gate from the TEST process, which owns the connection. The
    # watcher can only observe this by querying from its own process.
    {:ok, _resolved} =
      Tasks.record_architecture_verdict(ctx.plan, %{"state" => "passed"}, source: "mcp")

    assert_receive {:lifecycle_step_settled, ^ref, outcome}, 5_000

    # THE discriminating assertion. A watcher that cannot reach the Repo also
    # settles — with `{:failed, :watch_read_raised}` out of `settled_outcome/1`'s
    # rescue. Only a watcher that actually performed the read can report the
    # verdict that was written.
    assert outcome == {:completed, :pass}
  end
end

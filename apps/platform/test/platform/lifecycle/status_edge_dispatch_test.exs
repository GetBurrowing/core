defmodule Platform.Lifecycle.StatusEdgeDispatchTest do
  @moduledoc """
  The task-status half of the lifecycle frame, exercised THROUGH
  `Platform.Tasks.transition_task/2` rather than by calling the executor
  directly.

  ## Which entry point, and the premise that died proving it

  This file was first written against `transition_task_status/2`, because
  the plan and the stage-1 inventory both named it as the choke point's
  caller. Every pipeline resolved correctly and NOTHING RAN:
  `transition_task_status/2` calls no finalizer at all. The real callers are
  `transition_task/3` and the plan-approval finalizer, and
  `transition_task_status/2` — which the MCP `task_update` status path uses
  DIRECTLY — is a fifth bypassing writer. Recorded in
  `Platform.Lifecycle.EdgeInventory`.

  The negative half of that finding is asserted below, so it cannot rot back
  into the docs unnoticed.

  ## Why this file exists at all

  Every pre-existing executor test injects `steps:`. **A test that supplies
  its own configuration cannot test the shipped configuration** — that is
  the exact defect that let a mutation probe survive on the previous stack
  member: with `steps:` always injected, no shipped caller ever exercised
  the project-resolution branch, every production pipeline was a hardcoded
  one-element list, a gate was always at index 0, and the
  declared-not-positional `can_divert` guarantee protected a configuration
  nothing could produce.

  So: NOTHING here passes `steps:`. The pipelines below live on the project
  row and are resolved by the executor exactly as they are in production.
  """

  # `async: false` for the same reason as `executor_test.exs`: these cases
  # point the VM-global `:lifecycle_step_registry` at a per-case registry,
  # because the fire point inside `Platform.Tasks` has nowhere to thread a
  # server argument — that is the whole point of going through it.
  use Platform.DataCase, async: false

  alias Platform.Lifecycle.EdgeInventory
  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Lifecycle.TestSteps
  alias Platform.Tasks

  @edge "backlog->planning"

  setup do
    registry_name = :"status_edge_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = StepRegistry.start_link(name: registry_name)

    for name <- ~w(s_notify_a s_notify_b s_gate s_after) do
      :ok =
        StepRegistry.register(
          %{name: name, mfa: {TestSteps.Sync, :start, 1}, kind: :deterministic},
          registry_name
        )
    end

    before = Application.fetch_env(:platform, :lifecycle_step_registry)
    Application.put_env(:platform, :lifecycle_step_registry, registry_name)

    on_exit(fn ->
      case before do
        :error -> Application.delete_env(:platform, :lifecycle_step_registry)
        {:ok, value} -> Application.put_env(:platform, :lifecycle_step_registry, value)
      end
    end)

    %{registry: registry_name}
  end

  defp sync(name, opts) do
    %{
      "step" => name,
      "await" => Keyword.get(opts, :await, true),
      "can_divert" => Keyword.get(opts, :can_divert, false)
    }
  end

  defp fixture(pipeline) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Status Edge Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/status-edge",
        tech_stack: %{"language" => "elixir"},
        deploy_config: %{"target" => "production"},
        config: %{"lifecycle_pipeline" => pipeline}
      })

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Status Edge Task"})

    %{project: project, task: task}
  end

  describe "a status transition fires the edge's SHIPPED-RESOLVED pipeline" do
    test "no :steps injected — the project's own configuration runs, in order" do
      %{task: task} =
        fixture(%{
          @edge => [
            sync("s_notify_a", await: false),
            sync("s_notify_b", await: false),
            sync("s_after", await: false)
          ]
        })

      assert {:ok, %{status: "planning"}} = Tasks.transition_task(task, "planning")

      # Explicit list, not set membership: order IS the semantics.
      assert TestSteps.Sync.ran() == ["s_notify_a", "s_notify_b", "s_after"]

      assert Enum.map(Runs.for_edge(task.id, @edge), &{&1.position, &1.step_name, &1.status}) ==
               [
                 {0, "s_notify_a", "completed"},
                 {1, "s_notify_b", "completed"},
                 {2, "s_after", "completed"}
               ]
    end

    test "divert authority comes from the DECLARATION at position 2, not from position 0" do
      # THE DISCRIMINATING FIXTURE. A positional rule ("index 0 may divert")
      # and the declared rule disagree here and only here: the gate is
      # third. Under a positional rule s_gate could not halt anything and
      # s_after would run.
      Process.put({:lifecycle_test_step, :sync_outcome, "s_gate"}, {:diverted, :back_to_backlog})

      %{task: task} =
        fixture(%{
          @edge => [
            sync("s_notify_a", await: false),
            sync("s_notify_b", await: false),
            sync("s_gate", can_divert: true),
            sync("s_after", await: false)
          ]
        })

      assert {:ok, _} = Tasks.transition_task(task, "planning")

      # POSITIVE CONTROL for the "did not run" claim below: the two steps
      # before the gate must actually have run. An executor that ran
      # nothing at all would satisfy every negative assertion here.
      assert TestSteps.Sync.ran() == ["s_notify_a", "s_notify_b", "s_gate"]

      assert Enum.map(Runs.for_edge(task.id, @edge), &{&1.step_name, &1.status}) == [
               {"s_notify_a", "completed"},
               {"s_notify_b", "completed"},
               {"s_gate", "diverted"}
             ]
    end

    test "CONTROL: the same pipeline with can_divert false does NOT halt" do
      # Same step returning the same `{:diverted, _}`, same position. The
      # ONLY difference is the declaration. If the executor read authority
      # from position, this control and the test above would behave
      # identically and neither would discriminate.
      Process.put({:lifecycle_test_step, :sync_outcome, "s_gate"}, {:diverted, :back_to_backlog})

      %{task: task} =
        fixture(%{
          @edge => [
            sync("s_notify_a", await: false),
            sync("s_notify_b", await: false),
            sync("s_gate", can_divert: false),
            sync("s_after", await: false)
          ]
        })

      assert {:ok, _} = Tasks.transition_task(task, "planning")

      assert TestSteps.Sync.ran() == ["s_notify_a", "s_notify_b", "s_gate", "s_after"]

      assert Enum.map(Runs.for_edge(task.id, @edge), &{&1.step_name, &1.status}) == [
               {"s_notify_a", "completed"},
               {"s_notify_b", "completed"},
               {"s_gate", "completed"},
               {"s_after", "completed"}
             ]
    end
  end

  describe "the edge dispatch is uniform across statuses, not per-clause" do
    test "the statuses with DEDICATED finalizer heads each fire their own edge" do
      # `finalize_status_hooks/3` has dedicated heads for in_review, done,
      # cancelled and deploying, plus a catch-all. A dispatch hung off one
      # head would leave every other status with no hooks and nothing red.
      # These four edges cover three dedicated heads AND the catch-all.
      edges = ~w(backlog->planning planning->in_progress in_progress->in_review in_review->done)

      pipeline = Map.new(edges, fn edge -> {edge, [sync("s_notify_a", await: false)]} end)

      %{task: task} = fixture(pipeline)

      # `in_progress` is behind the approved-plan gate; seed one rather
      # than route around the gate, so this walks the real path.
      {:ok, _plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, task} = Tasks.transition_task(task, "in_review")
      {:ok, task} = Tasks.transition_task(task, "done")

      assert task.status == "done"

      for edge <- edges do
        assert Enum.map(Runs.for_edge(task.id, edge), & &1.status) == ["completed"],
               "edge #{edge} recorded no run — the dispatch is not uniform across statuses"
      end
    end

    test "the CANCELLED head fires too" do
      %{task: task} = fixture(%{"backlog->cancelled" => [sync("s_notify_a", await: false)]})

      {:ok, task} = Tasks.transition_task(task, "cancelled")

      assert Enum.map(Runs.for_edge(task.id, "backlog->cancelled"), & &1.status) == ["completed"]
    end
  end

  describe "transition_task_status/2 DOES NOT OBSERVE the pipeline" do
    test "it writes the status and fires nothing" do
      # The premise correction, asserted rather than written down. This is
      # the path the MCP `task_update` status tool takes.
      %{task: task} = fixture(%{@edge => [sync("s_notify_a", await: false)]})

      assert {:ok, %{status: "planning"}} = Tasks.transition_task_status(task, "planning")
      assert TestSteps.Sync.ran() == []
      assert Runs.for_edge(task.id, @edge) == []

      # POSITIVE CONTROL, same run, same configuration: the observing entry
      # point DOES fire it. Without this the assertions above are equally
      # satisfied by a broken registry, an unsaved pipeline or a typo'd
      # edge key.
      %{task: observed} = fixture(%{@edge => [sync("s_notify_a", await: false)]})
      {:ok, _} = Tasks.transition_task(observed, "planning")
      assert TestSteps.Sync.ran() == ["s_notify_a"]
      assert length(Runs.for_edge(observed.id, @edge)) == 1
    end
  end

  describe "a traversed edge with no configured pipeline" do
    test "records NO rows — not_applicable is an outcome, not a row" do
      # An edge that RAN with nothing configured is `:not_applicable` and
      # writes no step rows; an edge never traversed does not run at all.
      # Neither produces a row here, and the positive control is the
      # CONFIGURED edge in the same run.
      %{task: task} = fixture(%{@edge => [sync("s_notify_a", await: false)]})

      {:ok, task} = Tasks.transition_task(task, "planning")
      {:ok, _task} = Tasks.transition_task_status(task, "in_progress")

      # POSITIVE CONTROL: the machinery fired at all.
      assert length(Runs.for_edge(task.id, @edge)) == 1

      # Traversed, nothing configured.
      assert Runs.for_edge(task.id, "planning->in_progress") == []

      # Never traversed at all.
      assert Runs.for_edge(task.id, "in_progress->done") == []
    end
  end

  describe "only edges in the transition table fire" do
    test "a refused transition writes nothing" do
      %{task: task} = fixture(%{"backlog->done" => [sync("s_notify_a", await: false)]})

      # `backlog -> done` is not in the table, so it is not declarable and
      # cannot fire even when configured.
      refute EdgeInventory.declarable?("backlog->done")
      refute Tasks.transition_valid?(task, "done")

      # The plan gate refuses first here, which is fine: the point is that
      # NO write and NO firing happen on an edge outside the table.
      assert {:error, _reason} = Tasks.transition_task(task, "done")
      assert Runs.for_edge(task.id, "backlog->done") == []

      # POSITIVE CONTROL: a legal transition on the same task does fire.
      %{task: other} = fixture(%{@edge => [sync("s_notify_a", await: false)]})
      {:ok, _} = Tasks.transition_task(other, "planning")
      assert length(Runs.for_edge(other.id, @edge)) == 1
    end
  end
end

defmodule Platform.Lifecycle.ExecutorTest do
  # `async: false` is LOAD-BEARING. Each case starts its own `StepRegistry`
  # and points `:lifecycle_step_registry` at it with `Application.put_env/3`,
  # which is VM-GLOBAL — the project changeset resolves step names through
  # `StepRegistry.server()` and has nowhere to thread a server argument. A
  # concurrent case would resolve against this file's registry, or this file
  # against its. Same family as the budget knobs in `step_test.exs`.
  use Platform.DataCase, async: false

  alias Platform.Lifecycle.Executor
  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Lifecycle.TestSteps
  alias Platform.Tasks

  @edge "planning.entered"

  setup do
    registry_name = :"lifecycle_executor_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = StepRegistry.start_link(name: registry_name)

    :ok =
      StepRegistry.register(
        %{name: "t_sync", mfa: {TestSteps.Sync, :start, 1}, kind: :deterministic},
        registry_name
      )

    :ok =
      StepRegistry.register(
        %{name: "t_async", mfa: {TestSteps.Async, :start, 1}, kind: :deterministic},
        registry_name
      )

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

  defp async_step(opts) do
    %{
      "step" => "t_async",
      "await" => Keyword.get(opts, :await, true),
      "can_divert" => Keyword.get(opts, :can_divert, false)
    }
  end

  # The pipeline's steps all name `t_sync` / `t_async`; per-position outcomes
  # are seeded by ORDER via the support module's per-name key, so distinct
  # registry names are needed when two sync steps must behave differently.
  defp register_alias(registry, name) do
    :ok =
      StepRegistry.register(
        %{name: name, mfa: {TestSteps.Sync, :start, 1}, kind: :deterministic},
        registry
      )
  end

  defp named_sync(name, opts \\ []) do
    %{
      "step" => name,
      "await" => Keyword.get(opts, :await, false),
      "can_divert" => Keyword.get(opts, :can_divert, false)
    }
  end

  defp fixture(pipeline_steps) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Lifecycle Executor Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/lifecycle-executor",
        tech_stack: %{"language" => "elixir"},
        deploy_config: %{"target" => "production"},
        config: %{"lifecycle_pipeline" => %{@edge => pipeline_steps}}
      })

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Lifecycle Executor Task"})

    %{project: project, task: task}
  end

  describe "a configured pipeline runs in declared order" do
    test "sync-only pipeline completes and preserves order", %{registry: registry} do
      for name <- ~w(a_first b_second c_third), do: register_alias(registry, name)

      %{project: project, task: task} =
        fixture([named_sync("a_first"), named_sync("b_second"), named_sync("c_third")])

      assert {:complete, summary} =
               Executor.run_edge(task, @edge,
                 project: project,
                 registry: registry,
                 step_timeout_ms: 100,
                 edge_budget_ms: 5_000
               )

      # Explicit list, not set membership: order IS the semantics.
      assert TestSteps.Sync.ran() == ["a_first", "b_second", "c_third"]
      assert Enum.map(summary.steps, & &1.step) == ["a_first", "b_second", "c_third"]
      assert Enum.map(summary.steps, & &1.status) == ["completed", "completed", "completed"]
      assert summary.not_run == []

      assert Enum.map(Runs.for_edge(task.id, @edge), &{&1.position, &1.step_name, &1.status}) ==
               [
                 {0, "a_first", "completed"},
                 {1, "b_second", "completed"},
                 {2, "c_third", "completed"}
               ]
    end
  end

  describe "the first divert halts the remainder" do
    test "three steps, divert in the MIDDLE: first ran, third did not", %{registry: registry} do
      for name <- ~w(d_first d_gate d_after), do: register_alias(registry, name)

      Process.put({:lifecycle_test_step, :sync_outcome, "d_gate"}, {:diverted, :back_to_planning})

      %{project: project, task: task} =
        fixture([
          named_sync("d_first"),
          named_sync("d_gate", can_divert: true),
          named_sync("d_after")
        ])

      assert {:diverted, summary} =
               Executor.run_edge(task, @edge,
                 project: project,
                 registry: registry,
                 step_timeout_ms: 100,
                 edge_budget_ms: 5_000
               )

      # POSITIVE CONTROL — an executor that runs nothing would pass every
      # negative assertion below. Step 1 must actually have run and completed.
      assert TestSteps.Sync.ran() == ["d_first", "d_gate"]

      rows = Runs.for_edge(task.id, @edge)

      assert Enum.map(rows, &{&1.step_name, &1.status}) == [
               {"d_first", "completed"},
               {"d_gate", "diverted"}
             ]

      # Two steps could not distinguish "halted" from "was last anyway".
      refute Enum.any?(rows, &(&1.step_name == "d_after"))
      assert summary.not_run == ["d_after"]
    end

    test "can_divert: false means the divert is IGNORED and the pipeline continues", %{
      registry: registry
    } do
      for name <- ~w(e_first e_advisory e_last), do: register_alias(registry, name)

      Process.put({:lifecycle_test_step, :sync_outcome, "e_advisory"}, {:diverted, :please_stop})

      %{project: project, task: task} =
        fixture([
          named_sync("e_first"),
          named_sync("e_advisory", can_divert: false),
          named_sync("e_last")
        ])

      assert {:complete, summary} =
               Executor.run_edge(task, @edge,
                 project: project,
                 registry: registry,
                 step_timeout_ms: 100,
                 edge_budget_ms: 5_000
               )

      # Paired with the halt test above, this is what proves divert authority
      # is read from the DECLARATION and not from the step's index.
      assert TestSteps.Sync.ran() == ["e_first", "e_advisory", "e_last"]
      assert Enum.map(summary.steps, & &1.status) == ["completed", "completed", "completed"]
      assert Enum.at(summary.steps, 1).divert_ignored == true
      assert Enum.at(summary.steps, 0).divert_ignored == false
      assert summary.not_run == []

      assert Enum.map(Runs.for_edge(task.id, @edge), & &1.step_name) ==
               ["e_first", "e_advisory", "e_last"]
    end
  end

  describe "the two budgets are separate mechanisms with separate reasons" do
    test "step budget: tiny step timeout, generous edge budget, pipeline CONTINUES", %{
      registry: registry
    } do
      for name <- ~w(f_first f_last), do: register_alias(registry, name)

      %{project: project, task: task} =
        fixture([
          named_sync("f_first"),
          async_step(await: true),
          named_sync("f_last")
        ])

      assert {:failed, summary} =
               Executor.run_edge(task, @edge,
                 project: project,
                 registry: registry,
                 step_timeout_ms: 20,
                 edge_budget_ms: 10_000
               )

      rows = Runs.for_edge(task.id, @edge)

      # Positive control from the SAME run: step 1 ran and completed.
      assert Enum.map(rows, &{&1.step_name, &1.status, &1.reason}) == [
               {"f_first", "completed", nil},
               {"t_async", "timed_out", "step_budget"},
               {"f_last", "completed", nil}
             ]

      # The REASON, not merely that something timed out. A bare `:timeout`
      # would make this test and the edge-budget one indistinguishable.
      assert Enum.at(summary.steps, 1).reason == "step_budget"
      assert summary.not_run == []
    end

    test "edge budget: generous step timeout, tiny edge budget, remainder HALTED", %{
      registry: registry
    } do
      for name <- ~w(g_first g_after), do: register_alias(registry, name)

      %{project: project, task: task} =
        fixture([
          named_sync("g_first"),
          async_step(await: true),
          named_sync("g_after")
        ])

      assert {:failed, summary} =
               Executor.run_edge(task, @edge,
                 project: project,
                 registry: registry,
                 step_timeout_ms: 10_000,
                 edge_budget_ms: 30
               )

      rows = Runs.for_edge(task.id, @edge)

      # Positive control in the same run, then the distinguishing reason.
      assert Enum.map(rows, &{&1.step_name, &1.status, &1.reason}) == [
               {"g_first", "completed", nil},
               {"t_async", "timed_out", "edge_budget"}
             ]

      assert Enum.at(summary.steps, 1).reason == "edge_budget"
      assert summary.not_run == ["g_after"]
      refute Enum.any?(rows, &(&1.step_name == "g_after"))
    end
  end

  describe "await" do
    test "await: false records started and does not wait", %{registry: registry} do
      register_alias(registry, "h_last")

      %{project: project, task: task} =
        fixture([async_step(await: false), named_sync("h_last")])

      started = System.monotonic_time(:millisecond)

      assert {:complete, _summary} =
               Executor.run_edge(task, @edge,
                 project: project,
                 registry: registry,
                 step_timeout_ms: 5_000,
                 edge_budget_ms: 10_000
               )

      elapsed = System.monotonic_time(:millisecond) - started

      # The async step NEVER settles. If the executor waited on a non-awaited
      # step this would take the full step timeout.
      assert elapsed < 1_000

      assert Enum.map(Runs.for_edge(task.id, @edge), &{&1.step_name, &1.status, &1.awaited}) ==
               [{"t_async", "started", false}, {"h_last", "completed", false}]
    end

    test "await: true consumes a settlement rather than timing out", %{registry: registry} do
      register_alias(registry, "i_last")
      Process.put({:lifecycle_test_step, :async_autosettle}, {:completed, :agent_answered})

      %{project: project, task: task} =
        fixture([async_step(await: true), named_sync("i_last")])

      assert {:complete, summary} =
               Executor.run_edge(task, @edge,
                 project: project,
                 registry: registry,
                 step_timeout_ms: 5_000,
                 edge_budget_ms: 10_000
               )

      # `completed`, not `timed_out`: the executor matched the settlement
      # message on the ref it was handed.
      assert Enum.map(summary.steps, &{&1.step, &1.status, &1.awaited}) == [
               {"t_async", "completed", true},
               {"i_last", "completed", false}
             ]
    end
  end

  describe "an edge that ran with nothing configured" do
    test "returns :not_applicable and writes NO rows", %{registry: registry} do
      %{project: project, task: task} = fixture([])

      assert {:not_applicable, summary} =
               Executor.run_edge(task, @edge,
                 project: project,
                 registry: registry,
                 step_timeout_ms: 100,
                 edge_budget_ms: 5_000
               )

      assert summary.steps == []
      assert Runs.for_edge(task.id, @edge) == []

      # Distinct from the never-occurring case: an edge that never happens
      # does not call run_edge/3 at all, so it produces neither an outcome nor
      # a row. `run_count/2` is what tells the two apart later — it is 0 here
      # too, which is exactly why the OUTCOME must carry the difference.
      assert Runs.run_count(task.id, @edge) == 0
    end
  end
end

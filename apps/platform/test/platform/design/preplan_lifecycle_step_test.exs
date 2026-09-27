defmodule Platform.Design.PreplanLifecycleStepTest do
  @moduledoc """
  The designer's `Platform.Lifecycle.Step` adapter (task 019fe1b7 stage 2).

  The BEHAVIOURAL contract of the migration — that a held planner is still
  held, released, and expired exactly as before — is asserted through the
  router in `Platform.Orchestration.TaskRouterTest`, because that is where it
  is observable. What is asserted HERE is the seam the router cannot see: the
  shape `start/2` returns for each thing `PreplanStep.start/1` can answer, and
  that the watcher resolves on the real closing signals rather than on a timer.

  Nothing here calls the executor. A test that ran the pipeline to check the
  step would be asserting the executor's ordering a second time.
  """

  use Platform.DataCase, async: false

  alias Platform.Design.PreplanLifecycleStep
  alias Platform.Design.PreplanStep
  alias Platform.Lifecycle.Step

  @ui_title "Add an epic-create FAB above the board"
  @non_ui_title "Add Providers.Architecture shim"

  # Small enough that a watcher left running cannot outlive the test, large
  # enough that it is never the reason a settlement arrives.
  @budget_ms 3_000

  # Far past anything this file waits for, so the budget can never be the
  # reason a watch stops in the lifetime tests.
  @long_budget_ms 600_000

  setup do
    previous = Application.get_env(:platform, :design_settle_poll_ms)
    Application.put_env(:platform, :design_settle_poll_ms, 50)

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :design_settle_poll_ms, previous)
      else
        Application.delete_env(:platform, :design_settle_poll_ms)
      end
    end)

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Design Step Project #{unique()}"})

    %{project: project}
  end

  defp unique, do: System.unique_integer([:positive]) |> Integer.to_string()

  defp task!(project, title) do
    %Platform.Tasks.Task{}
    |> Ecto.Changeset.change(%{
      project_id: project.id,
      title: title,
      description: title,
      status: "planning"
    })
    |> Repo.insert!()
  end

  # The designer fire is chatty on purpose; the log is not the subject here.
  defp quietly(fun), do: ExUnit.CaptureLog.capture_log([level: :debug], fun)

  # Starts the step with an explicit budget and returns what `start/2`
  # returned, swallowing the fire's log. The budget is passed on the CONTEXT
  # because that is where the executor puts it — a watcher that read the
  # global default instead would outlive every run it serves.
  defp start_open(task, budget_ms) do
    {result, _log} =
      ExUnit.CaptureLog.with_log([level: :debug], fn ->
        PreplanLifecycleStep.start(%{}, Map.put(context(task), :step_timeout_ms, budget_ms))
      end)

    result
  end

  defp context(task), do: %{task: task, edge: "planning.design_requested", reply_to: self()}

  defp reload(task), do: Repo.get!(Platform.Tasks.Task, task.id)

  describe "the behaviour is implemented, not approximated" do
    test "it declares :async, and the declaration matches what start/2 can return" do
      assert PreplanLifecycleStep.kind() == :async

      # `kind/0` is a claim; the executor branches on the RETURN. This asserts
      # the claim is at least honest about the module: a step that could never
      # answer `{:running, _}` has no business declaring `:async`.
      assert function_exported?(PreplanLifecycleStep, :start, 2)
      assert Step.behaviour_info(:callbacks) |> Enum.sort() == [{:kind, 0}, {:start, 2}]
    end

    test "it also exports the registry's arity-1 contract, and both agree", %{project: project} do
      # `StepRegistry` entries are `{mod, fun, 1}` and its drift guard asserts
      # the export. The executor prefers `start/2`; this pins that the
      # compatibility clause is a forward, not a second implementation.
      task = task!(project, @non_ui_title)

      assert {:completed, :not_applicable} = PreplanLifecycleStep.start(context(task))
      assert PreplanStep.persisted_outcome(reload(task)) == :not_applicable
    end
  end

  describe "start/2 return shapes" do
    test "a task with no UI surface resolves inline and is NOT awaited", %{project: project} do
      task = task!(project, @non_ui_title)

      assert {:completed, :not_applicable} = PreplanLifecycleStep.start(%{}, context(task))

      # ADR-0046 decision 2, and this is the row worth arguing about: the hook
      # RAN and had nothing to do. It is `{:completed, _}` at the step level
      # and keeps its own meaning on the task, where `PreplanStep` wrote it.
      assert PreplanStep.persisted_outcome(reload(task)) == :not_applicable
      refute PreplanStep.open?(reload(task))
    end

    test "a step already settled resolves inline without re-firing", %{project: project} do
      task = task!(project, @non_ui_title)

      assert {:completed, :not_applicable} = PreplanLifecycleStep.start(%{}, context(task))
      before = reload(task).planning_step_outcomes

      assert {:completed, :already_settled} = PreplanLifecycleStep.start(%{}, context(task))
      assert reload(task).planning_step_outcomes == before
    end

    test "a vanished task fails rather than hanging", %{project: project} do
      task = task!(project, @non_ui_title)
      Repo.delete!(task)

      assert {:failed, :task_not_found} = PreplanLifecycleStep.start(%{}, context(task))
    end
  end

  describe "settlement" do
    setup %{project: project} do
      [spec] = Platform.Responsibilities.Handlers.DesignTaskDirection.register()
      {:ok, _row} = Platform.Responsibilities.upsert_by_key(spec)

      Repo.insert!(
        %Platform.Roles.Role{
          key: "historian",
          name: "Historian",
          description: "test",
          icon: "hero-star"
        },
        on_conflict: :nothing,
        conflict_target: :key
      )

      %Platform.Roles.RoleResponsibility{}
      |> Platform.Roles.RoleResponsibility.changeset(%{
        role_key: "historian",
        responsibility_key: "design.task_direction"
      })
      |> Repo.insert!()

      {:ok, agent} =
        %Platform.Agents.Agent{}
        |> Platform.Agents.Agent.changeset(%{
          slug: "design-step-#{unique()}",
          name: "Fixture Designer",
          status: "active",
          kind: "native",
          workspace_id: nil
        })
        |> Repo.insert()

      {:ok, _} = Platform.Roles.assign_role("historian", agent.id)

      previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {__MODULE__, :noop_dispatch}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
        else
          Application.delete_env(:platform, :responsibility_router_native_dispatcher)
        end
      end)

      %{project: project}
    end

    test "an open step returns {:running, ref} and settles when the canvas lands", %{
      project: project
    } do
      task = task!(project, @ui_title)

      assert {:running, ref} = start_open(task, @budget_ms)

      # PIN THE POSITIVE FIRST. Without it the settlement below would hold
      # just as well on a step that closed inside `start/2`, which is the
      # shape of vacuity this module exists to avoid.
      assert PreplanStep.open?(reload(task))
      refute_receive {:lifecycle_step_settled, ^ref, _}, 200

      {:ok, :complete} = PreplanStep.settle(task.id, nil)

      assert_receive {:lifecycle_step_settled, ^ref, {:completed, :complete}}, 5_000

      # EXACTLY ONCE. `settle/2` writes twice and each write broadcasts, so a
      # watcher keyed on the broadcast rather than on the cursor would settle
      # the same ref twice and the executor would take the second for a
      # different step's.
      refute_receive {:lifecycle_step_settled, ^ref, _}, 300
    end

    test "an expiry settles as failed, not as completed", %{project: project} do
      task = task!(project, @ui_title)

      assert {:running, ref} = start_open(task, @budget_ms)

      quietly(fn -> PreplanStep.expire(task, 1_800_000) end)

      # The distinction the whole outcome vocabulary exists for: a step that
      # ran and did not deliver is FAILED, and it must not arrive here as a
      # completion just because the cursor closed.
      assert_receive {:lifecycle_step_settled, ^ref, {:failed, :design_failed}}, 5_000
    end

    test "a decline settles as completed/not_applicable — a refusal is not a failure", %{
      project: project
    } do
      task = task!(project, @ui_title)

      assert {:running, ref} = start_open(task, @budget_ms)

      quietly(fn -> PreplanStep.decline(task.id, "The change is not visual at all.") end)

      assert_receive {:lifecycle_step_settled, ^ref, {:completed, :not_applicable}}, 5_000
    end

    test "the watcher gives up at the budget rather than settling a dead run", %{
      project: project
    } do
      task = task!(project, @ui_title)

      assert {:running, ref} = start_open(task, 300)

      # The step is STILL OPEN — nothing closed it — so the only question is
      # whether the watcher invents a settlement. The executor has already
      # recorded `timed_out` by now, and a late settlement would resolve a run
      # it stopped listening for.
      assert PreplanStep.open?(reload(task))
      refute_receive {:lifecycle_step_settled, ^ref, _}, 1_500
    end

    # Task 01a0d4d6 stage 2. The watch serves one run. Once the awaiting process
    # (`:reply_to`) or the run's `:owner` (the TaskRouter) is gone, nobody can
    # receive its settlement, so it stops instead of re-reading the task until
    # the budget runs out. Each case pairs a DOWN with a refute taken while the
    # lifeline was alive, so a watch that stopped on its own cannot pass.
    test "the watch stops when the context's owner exits", %{project: project} do
      task = task!(project, @ui_title)

      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:running, ref} =
               start_with(task, %{owner: owner, step_timeout_ms: @long_budget_ms})

      watch = watch_for(self())
      watch_ref = Process.monitor(watch)

      refute_receive {:DOWN, ^watch_ref, :process, ^watch, _}, 300

      send(owner, :stop)

      assert_receive {:DOWN, ^watch_ref, :process, ^watch, _}, 2_000
      refute_received {:lifecycle_step_settled, ^ref, _}
      assert PreplanStep.open?(reload(task)), "the watch must not close the step on its way out"
    end

    test "the watch stops when the awaiting process exits", %{project: project} do
      task = task!(project, @ui_title)
      test = self()

      awaiting =
        spawn(fn ->
          result = start_with(task, %{reply_to: self(), step_timeout_ms: @long_budget_ms})
          send(test, {:started, result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:started, {:running, _ref}}, 5_000

      watch = watch_for(awaiting)
      watch_ref = Process.monitor(watch)

      refute_receive {:DOWN, ^watch_ref, :process, ^watch, _}, 300

      send(awaiting, :stop)

      assert_receive {:DOWN, ^watch_ref, :process, ^watch, _}, 2_000
    end
  end

  defp start_with(task, overrides) do
    {result, _log} =
      ExUnit.CaptureLog.with_log([level: :debug], fn ->
        PreplanLifecycleStep.start(%{}, Map.merge(context(task), overrides))
      end)

    result
  end

  # The watch is the Platform.TaskSupervisor child started from `caller`
  # (`Task.Supervisor.start_child/2` seeds `$callers`) whose entry point is
  # this module's watcher closure.
  defp watch_for(caller) do
    Platform.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(fn child ->
      case Process.info(child, :dictionary) do
        {:dictionary, dictionary} ->
          caller in Keyword.get(dictionary, :"$callers", []) and
            match?({PreplanLifecycleStep, _, _}, Keyword.get(dictionary, :"$initial_call"))

        nil ->
          false
      end
    end)
    |> case do
      [watch] ->
        watch

      other ->
        flunk("expected exactly one settle watch for #{inspect(caller)}, got #{inspect(other)}")
    end
  end

  test "the backstop interval is config-readable and its shipped default is not a test value" do
    assert PreplanLifecycleStep.default_settle_poll_ms() == 1_000

    Application.put_env(:platform, :design_settle_poll_ms, 7)
    assert PreplanLifecycleStep.settle_poll_ms() == 7
    assert PreplanLifecycleStep.default_settle_poll_ms() == 1_000
  end

  @doc false
  def noop_dispatch(_signal), do: :ok
end

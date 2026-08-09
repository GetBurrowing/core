defmodule Platform.Lifecycle.ReentryAndSettlementTest do
  # `async: false` for the same VM-global reason as `executor_test.exs`: each
  # case points `:lifecycle_step_registry` at its own registry with
  # `Application.put_env/3`, because the project changeset resolves step names
  # through `StepRegistry.server()` and has nowhere to thread a server.
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Inbox.Item
  alias Platform.Lifecycle
  alias Platform.Lifecycle.Executor
  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Lifecycle.TestSteps
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @edge "planning.entered"
  @other_edge "in_progress.entered"

  setup do
    registry_name = :"lifecycle_reentry_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = StepRegistry.start_link(name: registry_name)

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

  defp register_alias(registry, name) do
    :ok =
      StepRegistry.register(
        %{name: name, mfa: {TestSteps.Sync, :start, 1}, kind: :deterministic},
        registry
      )
  end

  defp step(name, opts \\ []) do
    %{
      "step" => name,
      "await" => Keyword.get(opts, :await, false),
      "can_divert" => Keyword.get(opts, :can_divert, false)
    }
  end

  defp fixture(pipeline, opts \\ []) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Lifecycle Reentry Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/lifecycle-reentry",
        tech_stack: %{"language" => "elixir"},
        deploy_config: %{"target" => "production"},
        config: %{"lifecycle_pipeline" => pipeline}
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lifecycle Reentry Task"})

    task =
      case Keyword.get(opts, :sponsor_user_id) do
        nil -> task
        id -> task |> Ecto.Changeset.change(%{sponsor_user_id: id}) |> Repo.update!()
      end

    %{project: project, task: task}
  end

  defp run(task, project, registry, edge \\ @edge, opts \\ []) do
    Executor.run_edge(
      task,
      edge,
      Keyword.merge(
        [project: project, registry: registry, step_timeout_ms: 50, edge_budget_ms: 5_000],
        opts
      )
    )
  end

  # Same shape as `inbox_test.exs` — `oidc_sub` is NOT NULL.
  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Sponsor #{n}",
      email: "sponsor-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  # ── A. re-entry bound ─────────────────────────────────────────────────────

  describe "the re-entry bound, exercised by FIRING the edge" do
    test "the first `limit` firings run for real; beyond it, suppressed", %{registry: registry} do
      register_alias(registry, "r_step")
      limit = Lifecycle.edge_run_limit()

      %{project: project, task: task} = fixture(%{@edge => [step("r_step")]})

      outcomes =
        for _ <- 1..(limit + 2) do
          {outcome, summary} = run(task, project, registry)
          {outcome, summary.run_seq}
        end

      {allowed, refused} = Enum.split(outcomes, limit)

      # POSITIVE CONTROL. Without this an executor that suppresses from call
      # one passes every negative assertion below.
      assert Enum.map(allowed, &elem(&1, 0)) == List.duplicate(:complete, limit)
      assert Enum.map(refused, &elem(&1, 0)) == [:suppressed, :suppressed]

      # Explicit run_seq list, not a total count.
      assert Enum.map(outcomes, &elem(&1, 1)) == Enum.to_list(1..(limit + 2))

      rows = Runs.for_edge(task.id, @edge)

      # Each allowed firing produced a REAL step row; each refusal produced a
      # step-less suppressed row and no new step rows.
      assert Enum.count(rows, &(&1.step_name == "r_step")) == limit
      assert Enum.count(rows, &(&1.status == "suppressed")) == 2
      assert Enum.all?(rows, &(&1.status != "suppressed" or is_nil(&1.step_name)))
      assert Runs.run_count(task.id, @edge) == limit + 2
    end

    test "a suppressed firing is NOT :not_applicable, and an empty edge is", %{
      registry: registry
    } do
      register_alias(registry, "r_only")
      limit = Lifecycle.edge_run_limit()

      %{project: project, task: task} =
        fixture(%{@edge => [step("r_only")], @other_edge => []})

      for _ <- 1..limit, do: run(task, project, registry)

      assert {:suppressed, suppressed} = run(task, project, registry)
      assert {:not_applicable, empty} = run(task, project, registry, @other_edge)

      # The two must not be the same answer: one refused to run, the other ran
      # with nothing configured. Conflating them is what ADR-0046 forbids.
      assert suppressed.reason == "edge_run_limit"
      assert Map.get(empty, :reason) == nil
      assert Runs.for_edge(task.id, @other_edge) == []
    end

    test "the bound is per EDGE, not per task", %{registry: registry} do
      register_alias(registry, "p_step")
      limit = Lifecycle.edge_run_limit()

      %{project: project, task: task} =
        fixture(%{@edge => [step("p_step")], @other_edge => [step("p_step")]})

      for _ <- 1..limit, do: run(task, project, registry)
      assert {:suppressed, _} = run(task, project, registry)

      # Same task, different edge: unaffected while the first is suppressed.
      assert {:complete, other} = run(task, project, registry, @other_edge)
      assert other.run_seq == 1

      assert Enum.map(Runs.for_edge(task.id, @other_edge), &{&1.step_name, &1.status}) ==
               [{"p_step", "completed"}]
    end

    test "edge_run_limit/0 is injectable and the shipped default is unmoved" do
      before = Application.fetch_env(:platform, :lifecycle_edge_run_limit)
      Application.put_env(:platform, :lifecycle_edge_run_limit, 1)

      on_exit(fn ->
        case before do
          :error -> Application.delete_env(:platform, :lifecycle_edge_run_limit)
          {:ok, value} -> Application.put_env(:platform, :lifecycle_edge_run_limit, value)
        end
      end)

      assert Lifecycle.edge_run_limit() == 1
      assert Lifecycle.default_edge_run_limit() == 3
    end
  end

  # ── B. failure attribution differs by kind ────────────────────────────────

  describe "an AWAITED step's failure IS the edge's outcome" do
    test "it fails the edge, and diverts when it may", %{registry: registry} do
      register_alias(registry, "a_gate")
      register_alias(registry, "a_after")

      Process.put({:lifecycle_test_step, :sync_outcome, "a_gate"}, {:failed, :agent_error})

      %{project: project, task: task} =
        fixture(%{@edge => [step("a_gate", await: true), step("a_after")]})

      assert {:failed, summary} = run(task, project, registry)
      assert Enum.at(summary.steps, 0).status == "failed"

      # Reuses the shipped vocabulary rather than a parallel one.
      assert "failed" in TaskSchema.planning_step_outcomes()
      assert "complete" in TaskSchema.planning_step_outcomes()
      assert "not_applicable" in TaskSchema.planning_step_outcomes()
    end

    test "an awaited step with divert authority diverts the edge", %{registry: registry} do
      register_alias(registry, "b_gate")
      register_alias(registry, "b_after")

      Process.put({:lifecycle_test_step, :sync_outcome, "b_gate"}, {:diverted, :back})

      %{project: project, task: task} =
        fixture(%{@edge => [step("b_gate", await: true, can_divert: true), step("b_after")]})

      assert {:diverted, summary} = run(task, project, registry)
      assert summary.not_run == ["b_after"]
    end
  end

  describe "a NON-AWAITED step's failure has a named destination" do
    setup %{registry: registry} do
      register_alias(registry, "c_first")
      user = insert_user()

      %{user: user, registry: registry}
    end

    defp detached_fixture(registry, sponsor_id) do
      %{project: project, task: task} =
        fixture(
          %{@edge => [step("c_first"), step("t_async", await: false)]},
          sponsor_user_id: sponsor_id
        )

      {outcome, summary} =
        Executor.run_edge(task, @edge,
          project: project,
          registry: registry,
          step_timeout_ms: 50,
          edge_budget_ms: 5_000
        )

      detached = Enum.find(summary.steps, &(&1.step == "t_async"))
      {outcome, summary, detached, task}
    end

    test "the edge outcome stays put, the row settles, the sponsor is notified", %{
      registry: registry,
      user: user
    } do
      {outcome, _summary, detached, task} = detached_fixture(registry, user.id)

      # (i) The edge already answered, and settling later must not rewrite it.
      assert outcome == :complete
      assert detached.status == "started"

      assert {:ok, run, :notified} =
               Executor.settle_detached(detached.run_id, {:failed, :webhook_502})

      # The edge outcome is a return value, not state — so the durable proxy
      # for "unchanged" is that no row of the edge's own steps moved.
      assert Enum.find(Runs.for_edge(task.id, @edge), &(&1.step_name == "c_first")).status ==
               "completed"

      # (ii) the run row is now failed, with a reason and a finish time
      assert run.status == "failed"
      assert run.reason =~ "webhook_502"
      refute is_nil(run.finished_at)

      # (iii) a durable attention row of the new kind exists for the sponsor
      items = inbox_items(user.id)
      assert Enum.map(items, & &1.kind) == ["lifecycle_step_failed"]
      assert hd(items).source_type == "task"
      assert hd(items).source_id == task.id
    end

    test "a nil sponsor settles the row and emits NOTHING, without raising", %{
      registry: registry,
      user: user
    } do
      {_outcome, _summary, detached, task} = detached_fixture(registry, nil)

      assert {:ok, run, :no_sponsor} =
               Executor.settle_detached(detached.run_id, {:failed, :webhook_502})

      # BOTH sides. A refute-only test stays green when the writer still fires
      # — here, against some other user.
      assert run.status == "failed"
      assert run.reason =~ "webhook_502"
      assert Repo.aggregate(from(i in Item), :count) == 0
      assert inbox_items(user.id) == []
      assert Repo.get(TaskSchema, task.id).sponsor_user_id == nil
    end

    test "a divert arriving after the edge is REFUSED with its own reason", %{
      registry: registry,
      user: user
    } do
      {_outcome, _summary, detached, _task} = detached_fixture(registry, user.id)

      assert {:ok, run, :notified} =
               Executor.settle_detached(detached.run_id, {:diverted, :too_late})

      # Not silently dropped: an ignored gate must be distinguishable from a
      # gate that never fired.
      assert run.status == "failed"
      assert run.reason == "divert_after_edge"
    end

    test "a non-failing settlement notifies nobody", %{registry: registry, user: user} do
      {_outcome, _summary, detached, _task} = detached_fixture(registry, user.id)

      assert {:ok, run, :no_notification} =
               Executor.settle_detached(detached.run_id, {:completed, :ok})

      assert run.status == "completed"
      assert inbox_items(user.id) == []
    end

    test "settling an unknown run id is an error, not a silent :ok", %{registry: _registry} do
      assert {:error, :not_found} =
               Executor.settle_detached(Ecto.UUID.generate(), {:failed, :boom})
    end
  end

  defp inbox_items(user_id) do
    Repo.all(from(i in Item, where: i.user_id == ^user_id, order_by: i.inserted_at))
  end
end

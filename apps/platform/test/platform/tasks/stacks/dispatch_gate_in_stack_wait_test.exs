defmodule Platform.Tasks.Stacks.DispatchGateInStackWaitTest do
  @moduledoc """
  Task 01a136c1 stage 2: a stack member approved while the commencement
  gate is OPEN but its in-stack dependency has not landed on the rollup
  parks at `stack_pending`, not `blocked`.

  Pre-fix, `apply_dispatch_gate` sent it to `blocked` through the
  `done`-threshold `unmet_dependencies/1`. Every in-stack promotion path
  (`Stacks.try_promote/1`) matches `stack_pending` only, and the
  `done`-threshold sweep needs the dependency at `done`, which an in-stack
  dependency reaches only when the stack ships. The member deadlocked.

  `async: false` because the reachability FakeRunner is installed through
  `Application.put_env(:platform, :stack_deployer, ...)`.
  """
  use Platform.DataCase, async: false

  import Platform.SubmittablePlanFixtures

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stacks, Task}

  @stamp_sha "f00dbabe"

  # Only `ensure_rollup_branch/1` is a required GitRunner callback; this
  # file exercises `sha_reachable?/1` alone, and records every call so a
  # test can prove the reachability gate actually ran.
  defmodule FakeRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(reachable) do
      Agent.start_link(fn -> %{reachable: reachable, calls: []} end, name: __MODULE__)
    end

    def reachability_calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, %{status: :created, base_sha: "deadbee"}}

    @impl true
    def sha_reachable?(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {{:ok, state.reachable}, %{state | calls: [args | state.calls]}}
      end)
    end
  end

  setup context do
    previous = Application.get_env(:platform, :stack_deployer)
    Application.put_env(:platform, :stack_deployer, git_runner: FakeRunner, async: false)
    start_supervised!({FakeRunner, Map.get(context, :reachable, true)})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :stack_deployer, previous),
        else: Application.delete_env(:platform, :stack_deployer)
    end)

    :ok
  end

  describe "open gate, in-stack dependency NOT landed" do
    test "(1) approval parks the dependent at stack_pending, not blocked" do
      %{a: a, b: b} = seed_stack_with_dependent()

      approve_new_plan(b)

      b_now = Tasks.get_task_record(b.id)

      assert b_now.status == "stack_pending",
             "expected the in-stack wait to park at stack_pending; got #{b_now.status} " <>
               "(blocked deadlocks: no in-stack promotion path matches it)"

      refute Map.has_key?(b_now.metadata || %{}, "unmet_dependencies")
      assert Tasks.get_task_record(a.id).status == "in_progress"
    end

    test "(2a) stamping the dependency then sweep_stack_dependents/1 promotes it to in_progress" do
      %{a: a, b: b} = seed_stack_with_dependent()
      approve_new_plan(b)
      assert Tasks.get_task_record(b.id).status == "stack_pending"

      # Raw write so the update hook's own sweep does not fire: the call
      # below is the only thing that can promote.
      landed = stamp_landed!(a)
      assert Tasks.get_task_record(b.id).status == "stack_pending"

      b_id = b.id

      assert {:ok, [%Task{id: ^b_id, status: "in_progress"}]} =
               Stacks.sweep_stack_dependents(landed)

      assert Tasks.get_task_record(b.id).status == "in_progress"
      assert Enum.any?(FakeRunner.reachability_calls(), &(&1.sha == @stamp_sha))
    end

    test "(2b) stamping the dependency then sweep_stack_pending_members/0 promotes it to in_progress" do
      %{a: a, b: b} = seed_stack_with_dependent()
      approve_new_plan(b)
      assert Tasks.get_task_record(b.id).status == "stack_pending"

      _landed = stamp_landed!(a)
      assert Tasks.get_task_record(b.id).status == "stack_pending"

      assert Stacks.sweep_stack_pending_members() >= 1
      assert Tasks.get_task_record(b.id).status == "in_progress"
    end
  end

  describe "open gate, in-stack dependency already landed but not done" do
    test "(3) approval goes straight to in_progress" do
      %{a: a, b: b} = seed_stack_with_dependent()
      landed = stamp_landed!(a)
      assert landed.status == "in_review"

      approve_new_plan(b)

      b_now = Tasks.get_task_record(b.id)
      assert b_now.status == "in_progress"
      refute Map.has_key?(b_now.metadata || %{}, "unmet_dependencies")
      # The rollup-stamp threshold was really evaluated, sha included.
      assert Enum.any?(FakeRunner.reachability_calls(), &(&1.sha == @stamp_sha))
    end

    @tag reachable: false
    test "(3, control) an unreachable stamp sha keeps it parked at stack_pending" do
      %{a: a, b: b} = seed_stack_with_dependent()
      _landed = stamp_landed!(a)

      approve_new_plan(b)

      assert Tasks.get_task_record(b.id).status == "stack_pending"
    end
  end

  describe "non-stack task" do
    test "(4) an undone dependency still goes blocked with metadata unmet_dependencies" do
      {:ok, project} = Tasks.create_project(%{name: "Gate plain " <> short_id()})
      {:ok, dep} = Tasks.create_task(%{project_id: project.id, title: "Plain dep"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Plain dependent"})
      {:ok, task} = Tasks.add_dependency(task, dep.id)
      {:ok, task} = Tasks.update_task(task, %{status: "planning"})
      assert task.stack_id == nil

      approve_new_plan(task)

      blocked = Tasks.get_task_record(task.id)
      assert blocked.status == "blocked"
      assert blocked.metadata["unmet_dependencies"] == [dep.id]
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # An `in_progress` stack with an open commencement gate once B's plan
  # approves: A (approved plan, `in_progress`, not landed) and B (planning,
  # depends on A). The project carries a repo_url so `unblocked_in_stack?/1`
  # takes the sha-reachability path through FakeRunner.
  defp seed_stack_with_dependent do
    {:ok, project} =
      Tasks.create_project(%{
        name: "In-stack wait " <> short_id(),
        repo_url: "https://github.com/test/repo"
      })

    slug = "in-stack-wait-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "In-stack wait stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    [a, b] =
      Enum.map(["A", "B"], fn label ->
        {:ok, task} =
          Tasks.create_task(%{project_id: project.id, title: "Member #{label} " <> short_id()})

        {:ok, attached} = Stacks.add_task(stack, task)
        attached
      end)

    {:ok, _edge} = Stacks.add_dependency_edge(stack, b.id, a.id)
    {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})

    stack = stack |> Ecto.Changeset.change(status: "in_progress") |> Repo.update!()
    a = force_task_status(Repo.reload!(a), "in_progress")
    {:ok, b} = Tasks.update_task(Repo.reload!(b), %{status: "planning"})

    %{project: project, stack: stack, a: a, b: b}
  end

  # Land A on the rollup with a raw write (no update hooks, no sweeps).
  defp stamp_landed!(%Task{} = task) do
    task = Repo.reload!(task)
    metadata = Map.put(task.metadata || %{}, "merged_into_rollup_at", %{"sha" => @stamp_sha})

    task
    |> Ecto.Changeset.change(status: "in_review", metadata: metadata)
    |> Repo.update!()
  end

  defp approve_new_plan(%Task{} = task) do
    task = Repo.reload!(task)
    {:ok, draft} = create_submittable_plan(%{task_id: task.id})
    {:ok, pending} = Tasks.submit_plan_for_review(draft)
    {:ok, approved} = Tasks.approve_plan(pending, "system")
    approved
  end

  defp force_task_status(%Task{} = task, status) do
    task
    |> Task.changeset(%{status: status})
    |> Repo.update!()
  end

  defp short_id, do: Ecto.UUID.generate() |> String.slice(0, 8)
end

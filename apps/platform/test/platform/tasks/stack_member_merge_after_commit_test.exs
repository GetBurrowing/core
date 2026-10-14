defmodule Platform.Tasks.StackMemberMergeAfterCommitTest do
  @moduledoc """
  Task 01a136c1 stage 1: a stack member's rollup merge must fire AFTER the
  transaction that passed its last review validation commits.

  ## The bug

  `PlanEngine.evaluate_validation/2` used to call
  `StackDeployer.handle_member_transition/3` from INSIDE its
  `Repo.transaction`. In production (`async: true`) the merge runs in a
  `Task.Supervisor` child that reads through its own pool connection, so it
  saw the validation the parent had just passed as still `pending`, declined
  the merge as `{:not_ready, {:stages_pending, n - 1, n}}`, and nothing
  retried it.

  ## Why this test does not run under the SQL sandbox

  Setting `async: true` in the deployer config is NOT enough to reproduce
  it. Under the sandbox the merge child finds the test's connection through
  `$callers` and shares it, so it either sees the uncommitted rows or queues
  behind the parent's transaction and reads them after commit. Either way
  the test passes on unfixed code.

  So the two sides get DIFFERENT connections, the way production does:

    * The merge child's ancestor (`unboxed/1`) owns a real, non-sandbox
      connection via `Sandbox.unboxed_run/2`. The child finds it through
      `$callers` and reads only COMMITTED rows.
    * The evaluating process routes its own `Platform.Repo` calls through a
      second, non-sandbox repo instance (`Repo.put_dynamic_repo/1`), so its
      transaction is a real transaction on another connection. The dynamic
      repo is per-process; the merge child does not inherit it.

  Every row is committed for real, so `on_exit` deletes the project, which
  cascades to the stack, task, plan, stages, validations and runtime events.

  ## Making the race deterministic

  On unfixed code the child and the parent's commit race. A telemetry
  handler on `[:platform, :repo, :query]`, scoped to the evaluating process,
  waits for any live merge child before the parent's NEXT query, which on
  unfixed code is still inside the transaction. So the child's readiness read
  always happens before the commit there. With the fix no child exists until
  after commit, and the wait is a no-op until then.
  """

  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Project, Stacks}

  @sup __MODULE__.MergeSupervisor

  defmodule FakeRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{merge_calls: []} end, name: __MODULE__)
    end

    def merge_calls, do: Agent.get(__MODULE__, & &1.merge_calls) |> Enum.reverse()

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, %{status: :already_exists, base_sha: "deadbee"}}

    @impl true
    def merge_member_into_rollup(args) do
      Agent.update(__MODULE__, fn state -> %{state | merge_calls: [args | state.merge_calls]} end)
      {:ok, %{status: :merged, merge_sha: "f00dbabe"}}
    end

    @impl true
    def open_stack_pr(_args),
      do: {:ok, %{number: 99, url: "https://github.com/test/repo/pull/99"}}

    @impl true
    def diff_stat(_args), do: {:ok, " 3 files changed"}

    @impl true
    def revert_member_merge(_args), do: {:ok, %{status: :reverted, revert_sha: "rev0000"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def sha_reachable?(_args), do: {:ok, true}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])

    start_supervised!(FakeRunner)
    start_supervised!({Task.Supervisor, name: @sup})

    # Seeding runs synchronously; the test flips `async: true` just before
    # the evaluation under test.
    Application.put_env(:platform, :stack_deployer,
      git_runner: FakeRunner,
      async: false,
      task_supervisor: @sup
    )

    real_repo =
      start_supervised!(
        Supervisor.child_spec(
          {Repo, name: nil, pool: DBConnection.ConnectionPool, pool_size: 2},
          id: :real_pool_repo
        )
      )

    on_exit(fn -> Application.put_env(:platform, :stack_deployer, prev) end)

    %{real_repo: real_repo}
  end

  test "passing a member's last review validation stamps merged_into_rollup_at under async: true",
       %{real_repo: real_repo} do
    # `Platform.DataCase` puts an `async: false` module in SHARED sandbox
    # mode. In shared mode the ownership manager does not walk `$callers`: a
    # process with no checkout of its own (the merge child) is handed the
    # shared SANDBOX connection, so its stamp would land in the sandbox
    # transaction where nothing else can see it (measured: the first version
    # of this test merged once and read back no stamp, and the cleanup then
    # blocked on the sandbox's row lock). `:manual` restores the `$callers`
    # walk, so the child finds its unboxed ancestor's real connection. This
    # process stays allowed on the owner either way, and every case's setup
    # re-sets the mode.
    Sandbox.mode(Repo, :manual)

    seeded = unboxed(fn -> seed_member!() end)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(p in Project, where: p.id == ^seeded.project_id)) end)
    end)

    test_pid = self()
    not_ready_handler = "after-commit-not-ready-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        not_ready_handler,
        [:platform, :stack_deployer, :merge_not_ready],
        fn _event, _measurements, %{task_id: task_id, reason: reason}, _config ->
          send(test_pid, {:merge_not_ready, task_id, reason})
        end,
        nil
      )

    try do
      result =
        unboxed(fn ->
          Application.put_env(
            :platform,
            :stack_deployer,
            Keyword.put(Application.get_env(:platform, :stack_deployer), :async, true)
          )

          evaluate_on_real_repo(real_repo, seeded.pending_validation_id)
        end)

      assert {:ok, %{status: "passed"}} = result

      task = unboxed(fn -> Tasks.get_task_record(seeded.task_id) end)

      not_ready = collect_not_ready(seeded.task_id)

      assert match?(%{"sha" => "f00dbabe"}, task.metadata["merged_into_rollup_at"]),
             "expected the member to be stamped merged_into_rollup_at by the merge child " <>
               "with no stack_retry_member_merge; got metadata=#{inspect(task.metadata)}, " <>
               "merge_not_ready reasons=#{inspect(not_ready)}, " <>
               "runner merge calls=#{length(FakeRunner.merge_calls())}"

      refute Enum.any?(not_ready, &match?({:stages_pending, _, _}, &1)),
             "a merge child read the review validations before the commit: " <>
               inspect(not_ready)

      assert [%{member_task_id: member_id}] = FakeRunner.merge_calls()
      assert member_id == seeded.task_id
    after
      :telemetry.detach(not_ready_handler)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # Run `fun` on a REAL connection, outside the sandbox, in a fresh process.
  # It must be a fresh process: the test process is already allowed on the
  # sandbox owner, and `Sandbox.unboxed_run/2` from it would silently run
  # INSIDE the sandbox (see janitor_policy_test.exs `unboxed/1`).
  defp unboxed(fun) do
    Elixir.Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Elixir.Task.await(60_000)
  end

  # Called inside `unboxed/1`, so this process owns a real connection in the
  # ownership pool, and any merge child it spawns lands on it. This process's
  # OWN repo calls go to `real_repo` instead, a different connection.
  defp evaluate_on_real_repo(real_repo, validation_id) do
    evaluator = self()
    hold_handler = "after-commit-hold-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        hold_handler,
        [:platform, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == evaluator, do: await_merge_children()
        end,
        nil
      )

    previous = Repo.put_dynamic_repo(real_repo)

    try do
      result =
        PlanEngine.evaluate_validation(validation_id, %{
          status: "passed",
          evidence: %{"note" => "last review validation"},
          evaluated_by: "test"
        })

      Repo.put_dynamic_repo(previous)
      await_merge_children()
      result
    after
      Repo.put_dynamic_repo(previous)
      :telemetry.detach(hold_handler)
    end
  end

  # Wait until the merge supervisor has no live children, including any a
  # child spawns itself (the merge stamp fires its own follow-ups).
  defp await_merge_children(rounds \\ 20)

  defp await_merge_children(0), do: :ok

  defp await_merge_children(rounds) do
    case Task.Supervisor.children(@sup) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, fn pid ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            10_000 -> :ok
          end
        end)

        await_merge_children(rounds - 1)
    end
  end

  defp collect_not_ready(task_id, acc \\ []) do
    receive do
      {:merge_not_ready, ^task_id, reason} -> collect_not_ready(task_id, [reason | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A stack member at `in_review` whose current plan has ONE review stage
  # (running) with two `e2e_behavior` validations: one passed, one pending.
  defp seed_member! do
    uniq = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "Merge After Commit Project #{uniq}",
        repo_url: "https://github.com/test/merge-after-commit-#{uniq}"
      })

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: "merge-after-commit-#{uniq}",
        name: "Merge After Commit Stack",
        rollup_branch: "stack/merge-after-commit-#{uniq}"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Stack member awaiting its last review validation",
        status: "in_review",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{}}
      })

    {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, review} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Review"})

    payload = %{
      "setup" => "seed the member",
      "actions" => "exercise the member",
      "expected" => "the member behaves"
    }

    {:ok, _passed} =
      Tasks.create_validation(%{
        stage_id: review.id,
        kind: "e2e_behavior",
        status: "passed",
        evaluation_payload: payload
      })

    {:ok, pending} =
      Tasks.create_validation(%{
        stage_id: review.id,
        kind: "e2e_behavior",
        status: "pending",
        evaluation_payload: payload
      })

    {:ok, _} = PlanEngine.start_stage(review.id)

    %{project_id: project.id, task_id: task.id, pending_validation_id: pending.id}
  end
end

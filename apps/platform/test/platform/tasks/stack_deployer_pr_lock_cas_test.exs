defmodule Platform.Tasks.StackDeployerPrLockCasTest do
  @moduledoc """
  Task 01a05394 stage 4 — the rollup-PR open lock is a compare-and-swap.

  `StackDeployer.lock_stack_for_pr/1` used to be a read-then-update: two
  callers holding the same stale `%Stack{}` both passed
  `pr_already_opened?/1`, both wrote the placeholder, both shelled out to
  `gh pr create`, and the loser's `rollback_pr_lock/1` then dropped the
  stack to `in_review` underneath the winner's live PR — a state the
  stage-2 reconcile poll never scans.

  Concurrency shape: `async: false` puts the sandbox in SHARED mode, so
  two `Task.async` callers run as genuinely separate processes against
  one connection. Both are handed the SAME pre-lock struct, so both pass
  the in-memory gate regardless of timing and only the row-level CAS can
  separate them. The fake runner sleeps inside `open_stack_pr/1` so a
  loser mis-routed into rollback would find the winner's placeholder
  still standing — which is exactly the window the old code lost in.
  """

  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Tasks.{StackDeployer, Stacks}

  # Minimal runner: only the callbacks `maybe_open_stack_pr/1` reaches.
  # Its own call log is the source of the exact-count assertion — task
  # state is not (a second `gh pr create` that GitHub rejected would leave
  # no trace there).
  defmodule SlowPrRunner do
    @moduledoc false
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            pr_calls: [],
            pr_delay_ms: Keyword.get(opts, :pr_delay_ms, 150),
            next_number: Keyword.get(opts, :first_number, 4100)
          }
        end,
        name: __MODULE__
      )
    end

    def stop, do: Agent.stop(__MODULE__)

    def pr_calls, do: Agent.get(__MODULE__, & &1.pr_calls) |> Enum.reverse()

    def open_stack_pr(args) do
      {delay, number} =
        Agent.get_and_update(__MODULE__, fn state ->
          {{state.pr_delay_ms, state.next_number},
           %{state | pr_calls: [args | state.pr_calls], next_number: state.next_number + 1}}
        end)

      Process.sleep(delay)
      {:ok, %{number: number, url: "https://github.com/test/repo/pull/#{number}"}}
    end

    def diff_stat(_args), do: {:ok, " 1 file changed"}

    def sha_reachable?(_args), do: {:ok, true}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])

    Application.put_env(:platform, :stack_deployer,
      git_runner: SlowPrRunner,
      async: false
    )

    {:ok, _} = SlowPrRunner.start_link()

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        SlowPrRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  # A stack whose every member has landed on the rollup and whose
  # validation gate is a pass-through (`status: "deploying"` — the shape
  # `Stacks.dispatch_stack_deploy/1` leaves behind), but which has NOT yet
  # opened its rollup PR. This is the exact input both racing callers see.
  defp pr_ready_stack! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "PR lock CAS #{uniq()}",
        repo_url: "https://github.com/test/pr-lock-cas-#{uniq()}"
      })

    slug = "pr-lock-cas-#{uniq()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        base_branch: "main",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {:ok, task} = Tasks.create_task(%{title: "member #{uniq()}", project_id: project.id})

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack.id,
        stack_position: 1,
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => "abc1234",
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })

    {:ok, _task} = Tasks.update_task(task, %{status: "in_review"})
    {:ok, stack} = Stacks.update_stack(stack, %{status: "deploying"})

    refute Map.has_key?(stack.metadata || %{}, "rollup_pr")
    stack
  end

  # ── Control: the CAS must not fail closed on the happy path ──────────────

  describe "single caller on a fresh stack" do
    test "opens the rollup PR and lands deploying with a real rollup_pr.number" do
      stack = pr_ready_stack!()

      assert {:ok, %{status: :opened, number: 4100, url: url}} =
               StackDeployer.maybe_open_stack_pr(stack)

      assert [call] = SlowPrRunner.pr_calls()
      assert call.rollup_branch == stack.rollup_branch

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == "deploying"
      assert reloaded.metadata["rollup_pr"]["number"] == 4100
      assert reloaded.metadata["rollup_pr"]["url"] == url
      refute Map.has_key?(reloaded.metadata["rollup_pr"], "status")
    end

    test "a stack already carrying rollup_pr.number is :already_open with zero runner calls" do
      stack = pr_ready_stack!()

      {:ok, stamped} =
        Stacks.update_stack(stack, %{
          metadata: %{"rollup_pr" => %{"number" => 7, "url" => "https://x/pull/7"}}
        })

      assert {:ok, :already_open} = StackDeployer.maybe_open_stack_pr(stamped)
      assert SlowPrRunner.pr_calls() == []
    end
  end

  # ── The race ─────────────────────────────────────────────────────────────

  describe "two callers racing maybe_open_stack_pr/1 on the same stale struct" do
    test "exactly ONE open_stack_pr call; stack ends deploying with a number, never in_review" do
      stack = pr_ready_stack!()

      # Both callers hold the SAME pre-lock struct: both pass
      # `pr_already_opened?/1` by construction. Only the row-level CAS in
      # `lock_stack_for_pr/1` can stop the second shell-out.
      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> StackDeployer.maybe_open_stack_pr(stack) end) end)
        |> Task.await_many(5_000)

      # The decision: the fake runner's own log, not task state.
      assert length(SlowPrRunner.pr_calls()) == 1

      # The loser must NOT have been routed through `rollback_pr_lock/1`:
      # that path clears the winner's placeholder and drops the stack to
      # `in_review` while the winner is still inside `gh pr create`.
      reloaded = Stacks.get_stack(stack.id)
      refute reloaded.status == "in_review"
      assert reloaded.status == "deploying"
      assert reloaded.metadata["rollup_pr"]["number"] == 4100
      assert is_binary(reloaded.metadata["rollup_pr"]["url"])

      assert Enum.count(results, &match?({:ok, %{status: :opened, number: 4100}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, :already_open}, &1)) == 1
    end
  end

  # ── rollback_pr_lock/1 never moves a stack with a real PR ────────────────

  describe "rollback_pr_lock/1" do
    test "leaves a stack carrying a real rollup_pr.number completely unchanged" do
      stack = pr_ready_stack!()

      {:ok, live} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 512,
              "url" => "https://github.com/test/repo/pull/512",
              "opened_at" => "2026-08-30T00:00:00Z"
            },
            "other" => "kept"
          }
        })

      assert :ok = StackDeployer.rollback_pr_lock(live.id)

      after_rollback = Stacks.get_stack(live.id)
      assert after_rollback.status == "deploying"
      assert after_rollback.metadata == live.metadata
      assert after_rollback.updated_at == live.updated_at
    end

    test "clears its own opening placeholder and drops the stack to in_review" do
      stack = pr_ready_stack!()

      {:ok, locked} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{"status" => "opening", "at" => "2026-08-30T00:00:00Z"},
            "other" => "kept"
          }
        })

      assert :ok = StackDeployer.rollback_pr_lock(locked.id)

      after_rollback = Stacks.get_stack(locked.id)
      assert after_rollback.status == "in_review"
      refute Map.has_key?(after_rollback.metadata, "rollup_pr")
      assert after_rollback.metadata["other"] == "kept"
    end
  end
end
